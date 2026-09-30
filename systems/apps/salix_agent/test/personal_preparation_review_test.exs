defmodule SalixAgent.PersonalPreparationReviewTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{InternalSessionFleet, InternalSessionStore, PersonalPreparationReview}
  alias SalixAgent.InternalSession
  alias SalixAgent.Tools.MeetingPreparation

  defmodule Resolver do
    def resolve(_agent_id), do: {:ok, %{"model" => "review-test"}}
  end

  defmodule Model do
    def complete(messages, tools), do: complete(messages, tools, %{})

    def complete(messages, tools, opts) do
      send(:persistent_term.get({__MODULE__, :pid}), {:review, messages, tools, opts})

      case :persistent_term.get({__MODULE__, :response}) do
        :slow_review ->
          Process.sleep(31_000)
          {:final, ~s({"outcome":"ready","report":"Reviewed reminder"})}

        :echo_source ->
          report =
            if Jason.encode!(messages) =~ "UNDECLARED PRIVATE BODY",
              do: "UNDECLARED PRIVATE BODY",
              else: "Reviewed reminder"

          {:final, Jason.encode!(%{"outcome" => "ready", "report" => report})}

        response ->
          response
      end
    end
  end

  defmodule Domain do
    def read_recipient(_group, _plan, _revision, user, _agent, _session) do
      {:ok, %{"connect_id" => "connect", "recipient" => %{"user_id" => user, "name" => "Peng"}}}
    end

    def publish_personal_report(
          _group,
          _plan,
          _revision,
          connect,
          user,
          report,
          evidence,
          _agent,
          _session
        ) do
      send(:persistent_term.get({Model, :pid}), {:saved, connect, user, report, evidence})
      {:ok, %{"status" => "saved"}}
    end
  end

  setup do
    replacements = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, Model},
      {:salix_agent, :llm_resolver, Resolver},
      {:salix_agent, :meeting_preparation_mod, Domain},
      {:salix_agent, :oauth_store_mod, SalixAgent.LiveLlmTestSupport.OAuthStubStore}
    ]

    previous =
      Enum.map(replacements, fn {app, key, value} ->
        old = Application.get_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end)

    start_supervised!(SalixStore.S3.Fake)
    :persistent_term.put({Model, :pid}, self())

    :persistent_term.put(
      {Model, :response},
      {:final, Jason.encode!(%{"outcome" => "ready", "report" => "Reviewed reminder"})}
    )

    on_exit(fn ->
      Enum.each(previous, fn {app, key, old} ->
        if is_nil(old),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, old)
      end)

      :persistent_term.erase({Model, :pid})
      :persistent_term.erase({Model, :response})
      SalixAgent.TestSupport.stop_all_agents()
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)
    agent = SalixStore.Ids.new_agent_id(group)
    session = "ses1_0000000000000000973"

    SalixAgent.TestSupport.create_control_agent!(agent, %{
      "tenant_id" => tenant,
      "group_id" => group,
      "role" => "worker",
      "runtime_config" => %{"kind" => "internal"}
    })

    {:ok, pid} = InternalSessionFleet.ensure_started(agent, session, process_on_init: false)

    identity =
      Jason.encode!(%{
        "connect_id" => "connect",
        "recipient" => %{"user_id" => "UPENG", "name" => "Peng"}
      })

    original =
      Jason.encode!(%{
        "messages" => [
          %{
            "user" => "UPENG",
            "text" =>
              String.duplicate("Original context. ", 1500) <>
                "The first two items belong to Peng."
          }
        ]
      })

    events =
      source_events(1, "identity", "meeting.preparation.read_recipient", identity, %{
        "label" => ["scope|connect|@UPENG"]
      }) ++
        source_events(2, "original", "meeting.preparation.read_shared_source", original, %{
          "label" => ["scope|connect|CPUBLIC"]
        }) ++
        [
          %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => 3,
            "role" => "user",
            "content" => "UNDECLARED PRIVATE INDEX",
            "created_at" => 3
          }
        ]

    state =
      agent
      |> InternalSession.new(session, %{"created_at" => 1})
      |> InternalSession.apply_events(events)

    :sys.replace_state(pid, fn actor ->
      :ok = InternalSessionStore.seed(agent, state)
      actor
    end)

    evidence = %{
      "decision" => %{"sources" => [%{"ref" => "src:a-1"}, %{"ref" => "src:a-2"}]},
      "sources_label" => ["scope|connect|@UPENG", "scope|connect|CPUBLIC"],
      "source_files" => [],
      "declassified" => []
    }

    {:ok,
     ctx: %{agent_id: agent, session_id: session, ifc_mode: :off, ifc_evidence: evidence},
     original: original,
     actor_pid: pid}
  end

  test "publication refuses private memory even when explicitly cited", %{
    ctx: ctx,
    actor_pid: pid
  } do
    seed_more(
      pid,
      ctx,
      source_events(
        4,
        "private-memory",
        "meeting.preparation.read_team_memory",
        "PRIVATE ORIGINAL",
        %{
          "label" => ["scope|connect|CPUBLIC"]
        }
      )
    )

    assert_raise RuntimeError, fn ->
      publish(
        Map.put(args(), "source_refs", ["src:a-1", "src:a-4"]),
        ctx
      )
    end

    refute_received {:review, _, _, _}
    refute_received {:saved, _, _, _, _}
  end

  test "first publication saves the independent review from full originals, never the draft or private index",
       %{ctx: ctx, original: original} do
    started_at = DateTime.utc_now()

    report = """
    快开会啦，相关资料帮你放一起了：

    - [昨天的站会](https://example.slack.com/docs/TWORKSPACE/FCANVAS)：回顾会前准备和回复质量的讨论。
    - [回复问题](https://example.slack.com/archives/CPUBLIC/p123456)：这里整理了没有收到回复时的复现步骤，方便对照自己的体验。
    """

    :persistent_term.put(
      {Model, :response},
      {:final, Jason.encode!(%{"outcome" => "ready", "report" => report})}
    )

    assert Jason.decode!(publish(args(), ctx))["status"] ==
             "saved"

    assert_received {:review, messages, [], _opts}
    input = Jason.decode!(List.last(messages).content)
    assert is_binary(input["reviewed_at"])
    assert {:ok, reviewed_at, 0} = DateTime.from_iso8601(input["reviewed_at"])
    assert DateTime.compare(reviewed_at, started_at) != :lt
    assert DateTime.compare(reviewed_at, DateTime.utc_now()) != :gt
    assert input["draft"] == "Wrong draft"
    assert Enum.any?(input["original_evidence"], &(&1["content"] == original))
    refute Jason.encode!(messages) =~ "UNDECLARED PRIVATE INDEX"
    assert_received {:saved, "connect", "UPENG", ^report, evidence}
    assert evidence == ctx.ifc_evidence
  end

  test "IFC-off publication uses the envelope's declared originals without a second reference list",
       %{ctx: ctx, original: original} do
    ctx = dispatch_context(ctx)
    refs = ["src:a-1", "src:a-2"]

    for sources <- [refs, Jason.encode!(refs)] do
      result = dispatch_report(args(), sources, ctx)
      refute result.error, inspect(result)
      assert_received {:review, messages, [], _}

      assert Enum.any?(
               Jason.decode!(List.last(messages).content)["original_evidence"],
               &(&1["content"] == original)
             )

      refute Jason.encode!(messages) =~ "UNDECLARED PRIVATE INDEX"
      assert_received {:saved, "connect", "UPENG", "Reviewed reminder", _}
    end
  end

  test "review failure, malformed response and tool calls never save a draft",
       %{ctx: ctx} do
    for response <- [
          {:error, :unavailable},
          {:final, "not JSON"},
          {:assistant, "", [%{}]}
        ] do
      :persistent_term.put({Model, :response}, response)
      assert_raise RuntimeError, fn -> publish(args(), ctx) end
      refute_received {:saved, _, _, _, _}
    end
  end

  test "a reviewed no-action outcome saves an empty advice result", %{ctx: ctx} do
    :persistent_term.put(
      {Model, :response},
      {:final, ~s({"outcome":"no_supported_action","report":""})}
    )

    result =
      dispatch_report(Map.put(args(), "report", ""), args()["source_refs"], dispatch_context(ctx))

    refute result.error, inspect(result)
    assert Jason.decode!(result.content)["status"] == "saved"
    assert_received {:review, _, [], _}
    assert_received {:saved, "connect", "UPENG", nil, evidence}
    assert evidence == ctx.ifc_evidence
  end

  test "an empty draft does not permit missing reports or blank recipient fields", %{ctx: ctx} do
    ctx = dispatch_context(ctx)

    for {params, missing} <- [
          {Map.delete(args(), "report"), "report"},
          {Map.put(args(), "report", nil), "report"},
          {Map.put(args(), "connect_id", " "), "connect_id (empty string)"}
        ] do
      result = dispatch_report(params, args()["source_refs"], ctx)
      assert Jason.decode!(result.content)["error"] == "missing required params: #{missing}"
      refute_received {:review, _, _, _}
      refute_received {:saved, _, _, _, _}
    end
  end

  test "bot summaries alone cannot become personal preparation even when the model would accept them",
       %{ctx: ctx, actor_pid: pid} do
    summary = %{
      "user" => "UBOT",
      "bot_id" => "BMEETING",
      "text" => "Peng owns billing and must present the acceptance results today."
    }

    seed_more(
      pid,
      ctx,
      source_events(
        4,
        "bot-summary",
        "meeting.preparation.read_shared_source",
        Jason.encode!(%{"messages" => [summary]}),
        %{
          "label" => ["scope|connect|CPUBLIC"],
          "items" => [%{"index" => 0, "label" => ["scope|connect|CPUBLIC"]}]
        }
      )
    )

    for ref <- ["src:a-4", "src:a-4#0"] do
      assert_raise RuntimeError, ~r/personal_review_no_supported_action/, fn ->
        publish(
          Map.put(args(), "source_refs", ["src:a-1", ref]),
          ctx
        )
      end

      refute_received {:review, _, _, _}
      refute_received {:saved, _, _, _, _}
    end
  end

  test "unresolvable original or undeclared recipient refuses before invoking the model", %{
    ctx: ctx
  } do
    for refs <- [["src:a-404"], ["src:a-2"]] do
      assert_raise RuntimeError, fn ->
        publish(Map.put(args(), "source_refs", refs), ctx)
      end

      refute_received {:review, _, _, _}
      refute_received {:saved, _, _, _, _}
    end
  end

  test "source text cannot redirect review to an undeclared private stored result", %{
    ctx: ctx,
    actor_pid: pid
  } do
    :persistent_term.put({Model, :response}, :echo_source)
    pointer = Jason.encode!(%{"stored_result" => true, "result_ref" => "private-result"})

    seed_more(
      pid,
      ctx,
      source_events(
        4,
        "private-result",
        "meeting.preparation.read_team_memory",
        "UNDECLARED PRIVATE BODY"
      ) ++
        source_events(5, "public-pointer", "meeting.preparation.read_shared_source", pointer, %{
          "label" => ["scope|connect|CPUBLIC"]
        })
    )

    request = Map.put(args(), "source_refs", ["src:a-1", "src:a-2", "src:a-5"])
    publish(request, ctx)
    assert_received {:review, messages, [], _}
    refute Jason.encode!(messages) =~ "UNDECLARED PRIVATE BODY"
    assert Jason.encode!(messages) =~ "private-result"
    assert_received {:saved, "connect", "UPENG", "Reviewed reminder", _}
    refute_received {:saved, _, _, "UNDECLARED PRIVATE BODY", _}
  end

  test "indexed source supplies only the admitted message, without private siblings", %{
    ctx: ctx,
    actor_pid: pid
  } do
    content =
      Jason.encode!(%{
        "messages" => [
          %{"user" => "UPENG", "text" => "PUBLIC HIT"},
          %{"user" => "UOTHER", "text" => "PRIVATE SIBLING"}
        ]
      })

    seed_more(
      pid,
      ctx,
      source_events(4, "search", "meeting.preparation.read_shared_source", content, %{
        "label" => ["scope|connect|CPUBLIC", "scope|connect|CPRIVATE"],
        "items" => [%{"index" => 0, "label" => ["scope|connect|CPUBLIC"]}]
      })
    )

    request = Map.put(args(), "source_refs", ["src:a-1", "src:a-4#0"])
    publish(request, ctx)
    assert_received {:review, messages, [], _}
    assert Jason.encode!(messages) =~ "PUBLIC HIT"
    refute Jason.encode!(messages) =~ "PRIVATE SIBLING"
  end

  @tag timeout: 90_000
  test "canonical tool execution preserves a review beyond the former 30 second budget", %{
    ctx: ctx
  } do
    group = SalixStore.Ids.group_id_from_agent!(ctx.agent_id)
    SalixAgent.TestSupport.create_control_group!(group, %{"ifc" => %{"mode" => "enforce"}})

    ctx =
      ctx
      |> Map.merge(%{
        group_id: group,
        ifc_mode: :enforce,
        role: "worker",
        runtime_kind: :internal,
        llm_tool_envelope: true
      })
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("worker", :internal, ctx)
      )

    :persistent_term.put({Model, :response}, :slow_review)

    # Cross the actual dispatcher deadline that killed real source reviews.
    [result] =
      SalixAgent.Tools.execute(
        [
          %{
            id: "slow-review",
            name: "call",
            args: %{
              "tool" => "meeting.preparation.publish_personal_report",
              "params" => Map.delete(args(), "source_refs"),
              "ifc" => %{"sources" => args()["source_refs"]}
            },
            ifc_evidence: ctx.ifc_evidence
          }
        ],
        ctx
      )

    refute result.error, inspect(result)
    assert Jason.decode!(result.content)["status"] == "saved"
    assert_received {:review, _, [], _}
    refute_received {:review, _, _, _}
    assert_received {:saved, "connect", "UPENG", "Reviewed reminder", _}
    refute_received {:saved, _, _, _, _}
  end

  test "public review works with IFC off and derives evidence only from stored original labels",
       %{
         ctx: ctx,
         actor_pid: pid
       } do
    {ctx, recipient, refs} = public_review_sources(pid, ctx)

    assert {:ok, "Reviewed reminder", evidence} =
             PersonalPreparationReview.review_public("Wrong draft", recipient, refs, ctx)

    assert evidence == %{
             "sources_label" => ["scope|connect|@UPENG", "scope|connect|CPUBLIC"],
             "source_files" => [],
             "declassified" => [],
             "decision" => %{"sources" => Enum.map(refs, &%{"ref" => &1})}
           }

    assert_received {:review, messages, [], _}
    input = Jason.decode!(List.last(messages).content)

    assert Enum.any?(input["original_evidence"], fn source ->
             Jason.decode!(source["content"])["messages"] == [
               %{"user" => "UPENG", "text" => "PUBLIC ORIGINAL"}
             ]
           end)

    refute Jason.encode!(messages) =~ "TRUNCATED PREVIEW"
    refute Jason.encode!(messages) =~ "UNDECLARED PRIVATE INDEX"
  end

  test "public review refuses missing or forged refs and model authored summaries", %{
    ctx: ctx,
    actor_pid: pid
  } do
    {ctx, recipient, refs} = public_review_sources(pid, ctx)

    seed_more(pid, ctx, [
      %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => 6,
        "role" => "assistant",
        "content" => "My summary of the source",
        "created_at" => 6
      }
    ])

    for supplied <- [
          [],
          nil,
          List.duplicate(hd(refs), 33),
          [%{"ref" => "src:a-5", "label" => []}],
          refs ++ ["src:a-404"],
          refs ++ ["src:a-6"],
          refs ++ [42]
        ] do
      assert {:error, _} =
               PersonalPreparationReview.review_public("Wrong draft", recipient, supplied, ctx)

      refute_received {:review, _, _, _}
    end
  end

  test "public review requires original labels and rejects declassified or private-memory sources",
       %{
         ctx: ctx,
         actor_pid: pid
       } do
    {ctx, recipient, refs} = public_review_sources(pid, ctx)

    for {ifc, tool} <- [
          {nil, "meeting.preparation.read_shared_source"},
          {%{"label" => nil}, "meeting.preparation.read_shared_source"},
          {%{"label" => [], "declassified" => ["private"]},
           "meeting.preparation.read_shared_source"},
          {%{"label" => []}, "meeting.preparation.read_team_memory"},
          {%{"label" => []}, "im_api.slack.get_channel_history"}
        ] do
      id = 1_000 + System.unique_integer([:positive, :monotonic])
      seed_more(pid, ctx, source_events(id, "refused-#{id}", tool, "UNSUPPORTED", ifc))

      assert {:error, :personal_review_source_unavailable} =
               PersonalPreparationReview.review_public(
                 "Wrong draft",
                 recipient,
                 [hd(refs), "src:a-#{id}"],
                 ctx
               )

      refute_received {:review, _, _, _}
    end
  end

  test "public indexed review uses the selected original label and excludes sibling content", %{
    ctx: ctx,
    actor_pid: pid
  } do
    {ctx, recipient, refs} = public_review_sources(pid, ctx)

    content =
      Jason.encode!(%{
        "messages" => [
          %{"user" => "UPENG", "text" => "PUBLIC HIT"},
          %{"user" => "UOTHER", "text" => "PRIVATE SIBLING"}
        ]
      })

    seed_more(
      pid,
      ctx,
      source_events(6, "indexed-public", "meeting.preparation.read_shared_source", content, %{
        "label" => ["scope|connect|CPUBLIC", "scope|connect|CPRIVATE"],
        "items" => [%{"index" => 0, "label" => ["scope|connect|CPUBLIC"]}]
      })
    )

    assert {:ok, _, evidence} =
             PersonalPreparationReview.review_public(
               "Wrong draft",
               recipient,
               [hd(refs), "src:a-6#0"],
               ctx
             )

    refute "scope|connect|CPRIVATE" in evidence["sources_label"]
    assert_received {:review, messages, [], _}
    assert Jason.encode!(messages) =~ "PUBLIC HIT"
    refute Jason.encode!(messages) =~ "PRIVATE SIBLING"

    assert {:error, :personal_review_source_unavailable} =
             PersonalPreparationReview.review_public(
               "Wrong draft",
               recipient,
               [hd(refs), "src:a-6#1"],
               ctx
             )

    refute_received {:review, _, _, _}
  end

  test "public review requires a declared recipient identity and preserves reviewer refusal", %{
    ctx: ctx,
    actor_pid: pid
  } do
    {ctx, recipient, refs} = public_review_sources(pid, ctx)

    assert {:error, :personal_review_requires_declared_recipient} =
             PersonalPreparationReview.review_public(
               "Wrong draft",
               recipient,
               [List.last(refs)],
               ctx
             )

    refute_received {:review, _, _, _}
    :persistent_term.put({Model, :response}, {:final, ~s({"outcome":"no_supported_action"})})

    assert {:ok, nil, _evidence} =
             PersonalPreparationReview.review_public("Wrong draft", recipient, refs, ctx)
  end

  test "file provenance comes only from the stored original and is retained for reauthorization",
       %{ctx: ctx, actor_pid: pid} do
    {ctx, recipient, refs} = public_review_sources(pid, ctx)
    descriptor = %{"connect_id" => "connect", "channel" => "CPUBLIC", "file_id" => "FTRANSCRIPT"}

    original = %{
      "file_id" => "FTRANSCRIPT",
      "channel" => "CPUBLIC",
      "source_file" => descriptor,
      "text" => "ORIGINAL FILE TEXT"
    }

    seed_more(
      pid,
      ctx,
      source_events(
        6,
        "original-file",
        "meeting.preparation.read_shared_source",
        Jason.encode!(original),
        %{"label" => ["scope|connect|CPUBLIC"]}
      )
    )

    ctx = Map.put(ctx, :ifc_evidence, %{"source_files" => [%{"file_id" => "FORGED"}]})

    assert {:ok, _, evidence} =
             PersonalPreparationReview.review_public(
               "Wrong draft",
               recipient,
               [hd(refs), "src:a-6"],
               ctx
             )

    assert evidence["source_files"] == [descriptor]
    assert_received {:review, messages, [], _}
    assert Jason.encode!(messages) =~ "ORIGINAL FILE TEXT"
    refute Jason.encode!(messages) =~ "FORGED"
  end

  test "file source missing or contradicting its stored identity and audience refuses review", %{
    ctx: ctx,
    actor_pid: pid
  } do
    {ctx, recipient, refs} = public_review_sources(pid, ctx)
    descriptor = %{"connect_id" => "connect", "channel" => "CPUBLIC", "file_id" => "FTRANSCRIPT"}

    original = %{
      "file_id" => "FTRANSCRIPT",
      "channel" => "CPUBLIC",
      "source_file" => descriptor,
      "text" => "FILE"
    }

    for source <- [
          Map.delete(original, "source_file"),
          put_in(original, ["source_file", "file_id"], "FOTHER"),
          put_in(original, ["source_file", "connect_id"], "other-connect")
        ] do
      id = 2_000 + System.unique_integer([:positive, :monotonic])

      seed_more(
        pid,
        ctx,
        source_events(
          id,
          "invalid-file-#{id}",
          "meeting.preparation.read_shared_source",
          Jason.encode!(source),
          %{"label" => ["scope|connect|CPUBLIC"]}
        )
      )

      assert {:error, :personal_review_source_unavailable} =
               PersonalPreparationReview.review_public(
                 "Wrong draft",
                 recipient,
                 refs ++ ["src:a-#{id}"],
                 ctx
               )

      refute_received {:review, _, _, _}
    end
  end

  defp public_review_sources(pid, ctx) do
    recipient = %{
      "connect_id" => "connect",
      "recipient" => %{"user_id" => "UPENG", "name" => "Peng"}
    }

    seed_more(
      pid,
      ctx,
      source_events(
        4,
        "public-identity",
        "meeting.preparation.read_recipient",
        Jason.encode!(recipient),
        %{
          "label" => ["scope|connect|@UPENG"]
        }
      ) ++
        source_events(
          5,
          "public-original",
          "meeting.preparation.read_shared_source",
          Jason.encode!(%{"messages" => [%{"user" => "UPENG", "text" => "PUBLIC ORIGINAL"}]}),
          %{
            "label" => ["scope|connect|CPUBLIC"]
          }
        )
    )

    # Caller-provided IFC evidence is deliberately untrusted in the public path.
    ctx = %{
      ctx
      | ifc_mode: :off,
        ifc_evidence: %{"sources_label" => [], "declassified" => ["forged"]}
    }

    {ctx, recipient, ["src:a-4", "src:a-5"]}
  end

  defp dispatch_context(ctx) do
    group = SalixStore.Ids.group_id_from_agent!(ctx.agent_id)
    SalixAgent.TestSupport.create_control_group!(group, %{"ifc" => %{"mode" => "off"}})

    ctx =
      ctx
      |> Map.delete(:ifc_evidence)
      |> Map.merge(%{
        group_id: group,
        role: "worker",
        runtime_kind: :internal,
        llm_tool_envelope: true
      })
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(
      ctx,
      :tool_disclosure,
      SalixAgent.ToolDisclosure.materialize("worker", :internal, ctx)
    )
  end

  defp dispatch_report(params, sources, ctx) do
    [result] =
      SalixAgent.Tools.execute(
        [
          %{
            id: "publish-from-originals",
            name: "call",
            args: %{
              "tool" => "meeting.preparation.publish_personal_report",
              "params" => Map.delete(params, "source_refs"),
              "ifc" => %{"sources" => sources}
            }
          }
        ],
        ctx
      )

    result
  end

  defp seed_more(pid, ctx, events) do
    :sys.replace_state(pid, fn actor ->
      {:ok, _state} = InternalSessionStore.commit(ctx.agent_id, ctx.session_id, events)
      actor
    end)
  end

  defp publish(args, ctx) do
    {refs, args} = Map.pop(args, "source_refs")

    MeetingPreparation.publish_personal_report(
      args,
      Map.put(ctx, :ifc_declaration, %{sources: refs})
    )
  end

  defp args,
    do: %{
      "meeting_plan_id" => "plan",
      "dispatch_revision" => "revision",
      "connect_id" => "connect",
      "user_id" => "UPENG",
      "report" => "Wrong draft",
      "source_refs" => ["src:a-1", "src:a-2"]
    }

  defp source_events(message_id, id, name, content, ifc \\ nil) do
    [
      %{
        "type" => "async_tool_call_started",
        "tool_call_id" => id,
        "tool_name" => name,
        "status" => "running"
      },
      %{
        "type" => "async_tool_call_completed",
        "tool_call_id" => id,
        "result" =>
          %{"name" => name, "content" => content, "error" => false}
          |> then(fn result -> if is_nil(ifc), do: result, else: Map.put(result, "ifc", ifc) end)
      },
      %{
        "type" => "delivery",
        "from_queue" => true,
        "message_id" => message_id,
        "role" => "runtime",
        "created_at" => message_id,
        "content" =>
          Jason.encode!(%{
            "type" => "tool_call_completed",
            "tool_call_id" => id,
            "result_page" => %{"content" => "TRUNCATED PREVIEW"}
          })
      }
    ]
  end
end
