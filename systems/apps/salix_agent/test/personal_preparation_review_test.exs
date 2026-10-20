defmodule SalixAgent.PersonalPreparationReviewTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{InternalSessionFleet, InternalSessionStore, PersonalPreparationReview}
  alias SalixAgent.InternalSession
  alias SalixAgent.Tools.MeetingPreparation

  defmodule Resolver do
    def resolve(_agent_id), do: {:ok, %{"model" => "review-test"}}
  end

  defmodule Model do
    def complete(messages, tools), do: complete(messages, tools, %{})

    def complete(messages, tools, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :pid}),
        {:review, messages, tools, opts}
      )

      case SystemsRuntime.PersistentTerm.get({__MODULE__, :response}) do
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({Model, :pid}),
        {:saved, connect, user, report, evidence}
      )

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
        old = SystemsRuntime.get_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, old}
      end)

    start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.PersistentTerm.put({Model, :pid}, SystemsRuntime.Proc.self())

    SystemsRuntime.PersistentTerm.put(
      {Model, :response},
      {:final, Jason.encode!(%{"outcome" => "ready", "report" => "Reviewed reminder"})}
    )

    on_exit(fn ->
      Enum.each(previous, fn {app, key, old} ->
        if is_nil(old),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, old)
      end)

      SystemsRuntime.PersistentTerm.erase({Model, :pid})
      SystemsRuntime.PersistentTerm.erase({Model, :response})
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

    :sys.replace_state(
      pid,
      fn actor ->
        :ok = InternalSessionStore.seed(agent, state)
        actor
      end,
      :infinity
    )

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
    started_at = SystemsClock.utc_now()

    report = """
    快开会啦，相关资料帮你放一起了：

    - [昨天的站会](https://example.slack.com/docs/TWORKSPACE/FCANVAS)：回顾会前准备和回复质量的讨论。
    - [回复问题](https://example.slack.com/archives/CPUBLIC/p123456)：这里整理了没有收到回复时的复现步骤，方便对照自己的体验。
    """

    SystemsRuntime.PersistentTerm.put(
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
    assert DateTime.compare(reviewed_at, SystemsClock.utc_now()) != :gt
    assert input["draft"] == "Wrong draft"
    assert Enum.any?(input["original_evidence"], &(&1["content"] == original))
    refute Jason.encode!(messages) =~ "UNDECLARED PRIVATE INDEX"
    assert_received {:saved, "connect", "UPENG", ^report, evidence}
    assert evidence == ctx.ifc_evidence
  end

  test "source text cannot redirect review to an undeclared private stored result", %{
    ctx: ctx,
    actor_pid: pid
  } do
    SystemsRuntime.PersistentTerm.put({Model, :response}, :echo_source)
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

  test "IFC-enforced canonical tool execution saves exactly one reviewed report", %{ctx: ctx} do
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
      id = 1_000 + SystemsRuntime.Proc.unique_integer([:positive, :monotonic])
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

  defp seed_more(pid, ctx, events) do
    :sys.replace_state(
      pid,
      fn actor ->
        {:ok, _state} = InternalSessionStore.commit(ctx.agent_id, ctx.session_id, events)
        actor
      end,
      :infinity
    )
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
