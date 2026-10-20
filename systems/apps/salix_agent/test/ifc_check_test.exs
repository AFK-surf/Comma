defmodule SalixAgent.IFCCheckTest do
  @moduledoc """
  The information-flow step of the dispatch boundary, over the threat
  scenarios of `docs/verification.md` §1.

  The kernel's own algebra is covered by `salix_ifc`'s tests. What is checked
  here is the part that lives outside it: which calls are decided at all, how
  a destination and its writers are resolved from the call's parameters, what
  the model's declaration means, and what a person is told when the answer is
  no.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.IFC
  alias SalixAgent.IFC.{Check, Context, Declaration, Destination, Provenance, Render}

  @connect "cnx1"
  @space "space|cnx1"
  @general "space|cnx1"
  @legal "scope|cnx1|C_LEGAL"
  @dm_a "scope|cnx1|@U_A"
  @finance "scope|cnx1|C_FIN"
  @a "provider_user|cnx1|U_A"
  @b "provider_user|cnx1|U_B"
  @guest "provider_user|cnx1|U_G"

  # A resolver stand-in: the seam is a runtime module, so a test supplies one
  # answer per example instead of a provider workspace.
  defmodule Facts do
    @moduledoc false

    def resolve(request), do: Process.get(:ifc_test_resolver).(request)
    def mode(_tenant_id, _group_id), do: Process.get(:ifc_test_mode, "enforce")

    def start(fun), do: Process.put(:ifc_test_resolver, fun)

    # The store's delete: the first caller gets the receipt, everyone after it
    # finds it gone.
    def consume_receipt(request) do
      case Process.get(:ifc_test_receipt_error) do
        nil ->
          spent = Process.get(:ifc_test_spent, MapSet.new())
          id = request["receipt_id"]

          if MapSet.member?(spent, id) do
            {:ok, false}
          else
            Process.put(:ifc_test_spent, MapSet.put(spent, id))

            SystemsRuntime.Proc.send(
              SystemsRuntime.Proc.self(),
              {:receipt_spent, id, request["tenant_id"], request["group_id"]}
            )

            {:ok, true}
          end

        error ->
          {:error, error}
      end
    end
  end

  setup do
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod) end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp facts(overrides) do
    base = %{
      "mode" => "enforce",
      "scopes" => %{
        @legal => %{"kind" => "room", "within" => @space},
        @dm_a => %{"kind" => "direct", "within" => @space},
        @finance => %{"kind" => "room", "within" => @space}
      },
      "membership" => %{
        @legal => %{"members" => [@a], "revision" => 1},
        @dm_a => %{"members" => [@a], "revision" => 1},
        @finance => %{"members" => [@a, @b], "revision" => 1},
        "tag|finance" => %{"members" => [@a], "revision" => 1}
      },
      "placements" => %{
        @a => %{@connect => "internal"},
        @b => %{@connect => "internal"},
        @guest => %{@connect => "external"}
      },
      "receipts" => [],
      "policy" => %{},
      "display_names" => %{
        @legal => "#legal",
        @dm_a => "私聊",
        @finance => "#finance",
        "tag|finance" => "finance"
      },
      "now" => 1_000
    }

    Map.merge(base, overrides)
  end

  defp destination(atoms, writers \\ "any"),
    do: %{"destination" => %{"label" => atoms, "writers" => writers}}

  # A session where A wrote in their DM and B wrote in a public channel, and
  # a search result from #legal is in context.
  defp wire(opts \\ []) do
    requester = Keyword.get(opts, :requester, @a)
    scope = Keyword.get(opts, :source_scope, [@dm_a])
    request = Keyword.get(opts, :request, "src:q-1")

    %{
      "items" =>
        [
          %{
            "ref" => "src:q-1",
            "label" => [@dm_a],
            "integrity" => "command",
            "principal" => @a
          },
          %{
            "ref" => "src:q-2",
            "label" => [@general],
            "integrity" => "command",
            "principal" => @b
          },
          %{"ref" => "src:t-9", "label" => [@legal], "integrity" => "data", "principal" => nil},
          %{
            "ref" => "src:t-10",
            "label" => [@finance, "tag|finance"],
            "integrity" => "data",
            "principal" => nil
          },
          %{"ref" => "src:t-11", "label" => ["public"], "integrity" => "data", "principal" => nil}
        ] ++ Keyword.get(opts, :items, []),
      "requester" => requester,
      "source_scope" => scope,
      "consumed_refs" => Keyword.get(opts, :consumed, ["src:q-1", "src:q-2"]),
      "request" => request
    }
  end

  defp ctx(opts \\ []) do
    %{
      agent_id: "agent_1",
      session_id: "session_1",
      tenant_id: "tnt",
      group_id: "grp",
      ifc_mode: Keyword.get(opts, :mode, :enforce),
      ifc: Keyword.get(opts, :ifc, wire(opts)),
      trusted_origin: Keyword.get(opts, :trusted_origin)
    }
  end

  defp call(tool, params, ifc \\ nil) do
    base = %{id: "call-1", name: tool, args: params, call_index: 0}
    if ifc, do: Map.put(base, :ifc, ifc), else: base
  end

  defp authorize(call, ctx, reply) do
    Facts.start(fn _request -> {:ok, reply} end)
    [decision] = Check.authorize([{:execute, call}], ctx)
    decision
  end

  # ---------------------------------------------------------------------------

  test "identified Slack app requests dispatch under their own identity; legacy anonymous inputs do not retry" do
    source_id = "im_provider:slack:cnx1:C_GENERAL:123.456"
    bot = "provider_user|cnx1|U_BOT"

    origin = %{
      "provider" => "slack",
      "source_actor_type" => "provider_system",
      "source_message_id" => source_id,
      "principal_ref" => %{"connect_id" => "cnx1", "subject_id" => "U_BOT"},
      "provider_context" => %{
        "connect_id" => "cnx1",
        "user_id" => "U_BOT",
        "app_authored" => true
      },
      "ifc" => %{"integrity" => "command", "principal" => bot, "label" => [@space]}
    }

    session = %{
      messages: [%{id: 370, role: "user", source_message_id: source_id, trusted_origin: origin}]
    }

    wire =
      Context.build(session,
        source_message_id: source_id,
        source_message_ids: [source_id],
        trusted_origin: origin
      )

    context = ctx(ifc: wire, trusted_origin: origin)

    post =
      call("im_api.slack.post_message", %{"channel" => "C_GENERAL", "text" => "Received"}, %{
        "request" => "src:q-370",
        "sources" => ["src:q-370"]
      })

    reply = facts(destination([@space], [bot]))
    assert {:execute, executed} = authorize(post, context, reply)
    assert executed.ifc_evidence["requester"] == bot

    legacy =
      put_in(Map.delete(origin, "principal_ref"), ["ifc"], %{
        "integrity" => "data",
        "label" => [@space]
      })

    session =
      put_in(session, [:messages], [
        %{id: 370, role: "user", source_message_id: source_id, trusted_origin: legacy}
      ])

    wire =
      Context.build(session,
        source_message_id: source_id,
        source_message_ids: [source_id],
        trusted_origin: legacy
      )

    assert {:blocked, result} = authorize(post, ctx(ifc: wire, trusted_origin: legacy), reply)
    guidance = Jason.decode!(result.content)
    assert guidance["clause"] == "invalid_input"
    assert guidance["error"] =~ "no authenticated requester"

    # No manual pointer here either: the remedy is not a different declaration,
    # and naming help(tool="ifc") would invite the ref-editing retry this
    # clause rules out.
    refute Map.has_key?(guidance, "help_tool")
  end

  test "Lean IFC decisions reach the shared scrape without content labels" do
    reporter = Module.concat(__MODULE__, Reporter)

    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: reporter, metrics: Salix.Telemetry.metrics(), start_async: false}
    )

    tool =
      call("fs.write_file", %{"path" => "/notes/private.txt", "content" => "secret-canary"}, %{
        "request" => "src:q-1",
        "sources" => ["src:q-1"]
      })

    allowed = fn -> authorize(tool, ctx(), facts(destination(["agent_private"]))) end
    assert {:execute, _} = allowed.()
    assert {:blocked, _} = authorize(tool, ctx(), facts(destination(["public"])))
    scrape = TelemetryMetricsPrometheus.Core.scrape(reporter)
    assert scrape =~ ~s(component="salix_agent",operation="ifc_decide",outcome="ok")
    assert scrape =~ ~s(component="salix_agent",operation="ifc_decide",outcome="rejected")
    refute scrape =~ "secret-canary"
    refute scrape =~ "/notes/private.txt"
    stop_supervised!(reporter)
    assert {:execute, _} = allowed.()
    handler = {__MODULE__, SystemsRuntime.Proc.make_ref()}

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:salix, :operation, :stop],
        fn _, _, _, _ -> raise "broken reporter" end,
        nil
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)
    assert {:execute, _} = allowed.()
  end

  test "a joined-channel welcome has effect-local authority, not human or cross-channel authority" do
    source = "im_provider:slack:cnx1:channel_joined:C_GENERAL:EvJoin"

    origin = %{
      "provider" => "slack",
      "agent_group_id" => "grp",
      "source_message_id" => source,
      "source_actor_type" => "provider_user",
      "provider_context" => %{
        "connect_id" => "cnx1",
        "channel_id" => "C_GENERAL",
        "event_id" => "EvJoin",
        "event_type" => "member_joined_channel"
      }
    }

    scope = %{
      "kind" => "channel_onboarding",
      "source_message_id" => source,
      "context_source_message_ids" => [source],
      "connect_id" => "cnx1",
      "chat_id" => "C_GENERAL",
      "eligible" => true
    }

    ctx =
      Map.merge(
        ctx(
          ifc:
            wire(
              requester: nil,
              items: [
                %{
                  "ref" => "src:q-join",
                  "source_message_id" => source,
                  "label" => [@space],
                  "integrity" => "data",
                  "principal" => nil
                }
              ]
            )
        ),
        %{
          role: "router",
          source_message_id: source,
          source_message_ids: [source],
          trusted_origin: origin,
          terminal_reply_context: scope,
          llm_tool_envelope: true
        }
      )

    call =
      call(
        "im_api.slack.post_message",
        %{"connect_id" => "cnx1", "channel" => "C_GENERAL", "text" => "Hello"},
        %{"request" => "src:q-join", "sources" => ["src:q-join"]}
      )

    assert {:ok, bound} = SalixAgent.TerminalReply.authorize(call, ctx)
    reply = facts(%{"destination" => %{"label" => [@space], "writers" => "any"}})
    assert {:execute, _} = authorize(bound, ctx, reply)
    # The command is synthetic for this effect; the trusted notification stays data.
    assert List.last(ctx.ifc["items"])["integrity"] == "data"
    assert {:blocked, _} = authorize(call, ctx, reply)
    assert {:blocked, _} = authorize(put_in(bound, [:ifc, "sources"], ["src:q-1"]), ctx, reply)
    assert {:blocked, _} = authorize(put_in(bound, [:ifc, "request"], "src:q-1"), ctx, reply)
    assert {:blocked, _} = authorize(put_in(bound, [:args, "channel"], "C_OTHER"), ctx, reply)
    assert {:blocked, _} = authorize(bound, %{ctx | group_id: "other"}, reply)

    assert {:error, _} =
             SalixAgent.TerminalReply.authorize(call, %{ctx | llm_tool_envelope: false})

    assert {:error, _} =
             SalixAgent.TerminalReply.authorize(
               call,
               put_in(ctx, [:terminal_reply_context, "eligible"], false)
             )
  end

  describe "which calls are decided" do
    test "a read is never decided, whatever it reads" do
      assert {:read, _} =
               Destination.describe("im_api.slack.message_search", %{"query" => "x"}, %{})

      assert {:read, _} = Destination.describe("fs.read_file", %{}, %{})
      assert {:none, _} = Destination.describe("help", %{}, %{})
    end

    test "a write onto the Drive is a write the Group's humans will read" do
      # The path decides: the same tool writing into the workspace stays
      # private, writing under `/drive/` reaches every member's devices.
      ctx = %{group_id: "grp"}

      for write <- ~w(fs.write_file fs.edit_file fs.something_new) do
        assert {:persist, %{"kind" => "drive", "path" => "/drive/out.md", "group_id" => "grp"}} =
                 Destination.describe(write, %{"path" => "/drive/out.md"}, ctx),
               "#{write} onto the Drive must be a Drive write"
      end

      for move <- ~w(fs.copy_file fs.move_file) do
        assert {:persist, %{"kind" => "drive", "path" => "/drive/out.md"}} =
                 Destination.describe(
                   move,
                   %{"from" => "/notes/a.md", "to" => "/drive/out.md"},
                   ctx
                 )

        # Leaving the Drive for the workspace is a private write.
        assert {:persist, %{"kind" => "agent_private"}} =
                 Destination.describe(
                   move,
                   %{"from" => "/drive/a.md", "to" => "/notes/out.md"},
                   ctx
                 )
      end

      # A delete carries no content; reads of the Drive are reads.
      assert {:persist, %{"kind" => "agent_private"}} =
               Destination.describe("fs.delete_file", %{"path" => "/drive/out.md"}, ctx)

      assert {:read, _} = Destination.describe("fs.read_file", %{"path" => "/drive/out.md"}, ctx)
      assert {:read, _} = Destination.describe("fs.list_files", %{"prefix" => "/drive"}, ctx)
    end

    test "a post resolves the channel its parameters name" do
      assert {:egress, descriptor} =
               Destination.describe(
                 "im_api.slack.post_message",
                 %{"connect_id" => @connect, "channel" => "C_LEGAL", "text" => "hi"},
                 %{}
               )

      assert descriptor["kind"] == "provider_scope"
      assert descriptor["connect_id"] == @connect
      assert descriptor["scope_id"] == "C_LEGAL"
    end

    test "an unclassified tool is treated as public egress" do
      assert {:egress, %{"kind" => "public"}} = Destination.describe("env.exec", %{}, %{})
      assert {:egress, %{"kind" => "public"}} = Destination.describe("something.new", %{}, %{})
    end
  end

  describe "Worker configuration writes" do
    test "agent.update persists to the trusted Group, not public or model-selected scope" do
      assert {:persist, %{"kind" => "agent_configuration", "group_id" => "grp"}} =
               Destination.describe(
                 "agent.update",
                 %{"agent_id" => "worker", "group_id" => "other"},
                 ctx()
               )
    end

    test "private and unknown-membership sources are still refused" do
      for {input, reply} <- [
            {wire(), facts(destination(["group|grp"]))},
            {wire(requester: @b, request: "src:q-2", source_scope: [@space]),
             facts(destination(["group|grp"])) |> Map.put("placements", %{})}
          ] do
        update =
          call("agent.update", %{"agent_id" => "worker", "purpose" => "Private content"}, %{
            "request" => input["request"],
            "sources" => [input["request"]]
          })

        assert {:blocked, %{status: "guidance"}} = authorize(update, ctx(ifc: input), reply)
      end
    end
  end

  describe "the Drive mount" do
    # The resolver answers the Drive's audience as the Group
    # (`SalixIM.IFC.Facts`, `%{"kind" => "drive"}`); these tests hand that
    # answer in and exercise the decision the dispatcher makes with it. The
    # write itself is an eager effect on a store outside Salix, so this
    # refusal, before `Tools.execute/2`, is the only gate it has.
    test "content from a DM cannot be written onto the Drive" do
      decision =
        authorize(
          call("fs.write_file", %{"path" => "/drive/leaked.txt", "content" => "note"}, %{
            "request" => "src:q-1",
            "sources" => ["src:q-1"]
          }),
          ctx(),
          facts(destination(["group|grp"]))
        )

      assert {:blocked, result} = decision
      assert result.status == "guidance"
      assert result.guidance_reason == "information_flow"
    end

    test "content the Group may already read is written onto the Drive" do
      decision =
        authorize(
          call("fs.write_file", %{"path" => "/drive/report.md", "content" => "note"}, %{
            "request" => "src:q-1",
            "sources" => ["src:t-11"]
          }),
          ctx(),
          facts(destination(["group|grp"]))
        )

      assert {:execute, admitted} = decision

      assert %{"decision" => %{"sources" => [%{"ref" => "src:t-11", "clause" => "flow"}]}} =
               admitted.ifc_evidence
    end
  end

  describe "the per-audience memory home" do
    test "takes the audience of what the note was written from" do
      # A note drawn from #legal, written to `/memory/scoped/`. The resolver
      # cannot answer for this destination — only the dispatcher sees the
      # declaration — so it answers `agent_private` and the dispatcher replaces
      # it with the join of the declared sources.
      decision =
        authorize(
          call("memory.write", %{"path" => "/memory/scoped/legal.md", "content" => "note"}, %{
            "request" => "src:q-1",
            "sources" => ["src:t-9"]
          }),
          ctx(),
          facts(destination(["agent_private"]))
        )

      assert {:execute, admitted} = decision

      # Admitted by pure flow, not by a receipt or an in-place exception: the
      # note is not leaving the audience it came from.
      assert %{"decision" => %{"sources" => [%{"ref" => "src:t-9", "clause" => "flow"}]}} =
               admitted.ifc_evidence

      # And that audience is what the file records, so reading it later is no
      # weaker than reading #legal was.
      assert admitted.ifc_evidence["sources_label"] == [@legal]
    end

    test "while the same note in Group memory is refused" do
      decision =
        authorize(
          call("memory.write", %{"path" => "/memory/index.md", "content" => "note"}, %{
            "request" => "src:q-1",
            "sources" => ["src:t-9"]
          }),
          ctx(),
          facts(destination(["group|grp"]))
        )

      assert {:blocked, result} = decision
      assert result.status == "guidance"
    end
  end

  describe "T1 — a private channel quoted into a public one" do
    test "is refused for a non-member, without naming the channel" do
      decision =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN"}, %{
            "request" => "src:q-2",
            "sources" => ["src:t-9"]
          }),
          ctx(requester: @b, source_scope: [@general], request: "src:q-2"),
          facts(destination([@space]))
        )

      assert {:blocked, result} = decision
      assert result.status == "guidance"
      assert result.diagnostic_visibility == "user_reportable"
      assert result.public_summary == "有些相关信息我不能在这里复述。"
      refute result.public_summary =~ "legal"
    end

    test "is allowed in place for a member, and says where it came from" do
      decision =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN", "text" => "决定如下"}, %{
            "request" => "src:q-2a",
            "sources" => ["src:t-9"]
          }),
          ctx(
            requester: @a,
            source_scope: [@space],
            request: "src:q-2a",
            consumed: ["src:q-2a"],
            items: [
              %{
                "ref" => "src:q-2a",
                "label" => [@general],
                "integrity" => "command",
                "principal" => @a
              }
            ]
          ),
          facts(destination([@space]))
        )

      assert {:execute, executed} = decision
      assert executed[:args]["text"] =~ "包含来自 #legal 的信息"
      assert executed[:ifc_evidence]["decision"]["outcome"] == "allow"
    end
  end

  describe "T2 — a DM repeated in a channel" do
    test "is refused even though the model can see the DM" do
      decision =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN"}, %{
            "request" => "src:q-2",
            "sources" => ["src:q-1"]
          }),
          ctx(requester: @b, source_scope: [@general], request: "src:q-2"),
          facts(destination([@space]))
        )

      assert {:blocked, result} = decision
      guidance = Jason.decode!(result.content)
      assert guidance["clause"] == "flow_denied"

      # A refusal points at the manual: the prompt bullet naming help(tool="ifc")
      # may be far behind by the time the agent needs the declaration rules.
      assert guidance["help_tool"] == "help"
      assert guidance["help_params"] == %{"tool" => "ifc"}
    end

    test "and the same content flows back into that DM by pure flow" do
      decision =
        authorize(
          call("im_api.slack.send_dm", %{"user_id" => "U_A", "text" => "好的"}, %{
            "request" => "src:q-1",
            "sources" => ["src:q-1"]
          }),
          ctx(),
          facts(destination([@dm_a]))
        )

      assert {:execute, executed} = decision
      # Pure flow adds no footer: nothing was declassified.
      refute executed[:args]["text"] =~ "包含来自"
    end
  end

  describe "T3 — an external guest" do
    test "cannot write outside their own conversation" do
      decision =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN"}, %{"sources" => []}),
          ctx(
            requester: @guest,
            source_scope: ["scope|cnx1|C_SHARED"],
            request: "src:q-3",
            consumed: ["src:q-3"],
            items: [
              %{
                "ref" => "src:q-3",
                "label" => ["scope|cnx1|C_SHARED"],
                "integrity" => "command",
                "principal" => @guest
              }
            ]
          ),
          facts(destination([@space]))
        )

      assert {:blocked, result} = decision
      assert result.public_summary == "作为访客，我只能在这条对话里回复你。"
    end
  end

  describe "T4 — an instruction hidden in fetched content" do
    test "cannot be the request an effect acts on" do
      decision =
        authorize(
          call("im_api.slack.send_dm", %{"user_id" => "U_B"}, %{
            "request" => "src:t-9",
            "sources" => []
          }),
          ctx(),
          facts(destination([@dm_a]))
        )

      assert {:blocked, result} = decision
      assert Jason.decode!(result.content)["clause"] == "request_not_command"
      # The person never sees this: it is the model's mistake, not a boundary
      # they hit.
      assert result.diagnostic_visibility == "model_only"
      refute Map.has_key?(result, :public_summary)
    end
  end

  describe "control flow is not a source" do
    # A, in their DM, asks for a public page to be posted in #general as three
    # bullets. The bullets are derived from the page; the DM only said what to
    # do and how. Declaring the page alone is honest, the post flows, nothing
    # was declassified, and the record the model produced is citable wherever
    # the page is (§4).
    test "an instruction that only shapes the answer leaves no trace in what it produced" do
      post =
        call("im_api.slack.post_message", %{"channel" => "C_GEN", "text" => "- a\n- b\n- c"}, %{
          "request" => "src:q-1",
          "sources" => ["src:t-11"]
        })

      assert {:execute, admitted} = authorize(post, ctx(), facts(destination([@space])))
      assert admitted.ifc_evidence["sources_label"] == ["public"]
      refute admitted[:args]["text"] =~ "包含来自"

      assert Check.round_label([post], ctx()) == ["public"]

      [result] = Check.stamp_results([%{id: "r"}], [post], ctx())
      assert result.ifc == %{"label" => ["public"]}
    end
  end

  describe "the model's declaration" do
    test "an undeclared effect counts the entire context" do
      decision =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN"}),
          ctx(requester: @b, source_scope: [@general], request: "src:q-2"),
          facts(destination([@space]))
        )

      assert {:blocked, _result} = decision
    end

    test "an unreadable declaration falls back to the whole context" do
      assert Declaration.parse(%{"sources" => ["ok", 42]}).sources == :context
      assert Declaration.parse(%{"sources" => "context"}).sources == :context
      assert Declaration.parse(%{"sources" => []}).sources == []
      assert Declaration.parse(nil).sources == :context

      for encoded <- [
            ~s(["src:q-1",42]),
            ~s({"sources":["src:q-1"]}),
            Jason.encode!(Jason.encode!(["src:q-1"])),
            "src:q-1,src:q-2"
          ] do
        assert Declaration.parse(%{"sources" => encoded}).sources == :context
      end
    end
  end

  describe "audit mode" do
    test "records the same verdict and changes no outcome" do
      decision =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN"}, %{
            "request" => "src:q-2",
            "sources" => ["src:q-1"]
          }),
          ctx(mode: :audit, requester: @b, source_scope: [@general], request: "src:q-2"),
          facts(destination([@space])) |> Map.put("mode", "audit")
        )

      assert {:execute, _call} = decision
    end
  end

  describe "a Group with the check off" do
    test "never asks the resolver anything" do
      Facts.start(fn _request -> raise "the resolver must not be called" end)

      assert [{:execute, _call}] =
               Check.authorize(
                 [{:execute, call("im_api.slack.post_message", %{"channel" => "C_GEN"})}],
                 ctx(mode: :off)
               )
    end
  end

  describe "when the resolver cannot answer" do
    test "an enforced Group is still enforced" do
      Facts.start(fn _request -> {:error, :unavailable} end)

      assert [{:blocked, result}] =
               Check.authorize(
                 [{:execute, call("im_api.slack.post_message", %{"channel" => "C_GEN"})}],
                 ctx()
               )

      assert result.status == "guidance"
    end
  end

  describe "product-authored Triage delegation" do
    defp triage_dispatch do
      ref = "triage-delegation:triage-product-test:0"

      origin = %{
        "provider" => "slack",
        "source_actor_type" => "provider_system",
        "source_message_id" => ref,
        "agent_group_id" => "grp",
        "ifc" => %{"integrity" => "data", "label" => [@space]},
        "triage_delegation" => %{
          "schema" => "comma.triage-delegation-origin.v1",
          "namespace_key" => "namespace",
          "obligation_id" => "triage-product-test",
          "index" => 0,
          "request_id" => ref,
          "router_agent_id" => "agent_1",
          "group_id" => "grp"
        }
      }

      wire =
        Context.build(
          %{messages: [%{id: 1, role: "user", source_message_id: ref, trusted_origin: origin}]},
          source_message_id: ref,
          source_message_ids: [ref],
          trusted_origin: origin
        )

      context =
        ctx(ifc: wire, trusted_origin: origin)
        |> Map.merge(%{role: "router", source_message_ids: [ref], trusted_origins: [origin]})

      task =
        call(
          "im_api.internal.task.create",
          %{"triage_delegation_ref" => ref, "agent_id" => "worker"},
          %{"request" => "src:q-1", "sources" => ["src:q-1"]}
        )

      reply =
        facts(%{
          "destination" => %{"label" => ["task|pending:test"], "writers" => "any"},
          "membership" => %{"task|pending:test" => %{"members" => [], "revision" => 0}}
        })

      {task, context, reply}
    end

    test "the exact admitted handoff supplies a private Task command, not human authority" do
      {task, context, reply} = triage_dispatch()
      assert Context.activation(context.ifc) == :error
      assert hd(context.ifc["items"])["integrity"] == "data"
      assert {:execute, allowed} = authorize(task, context, reply)
      assert allowed.ifc_evidence["requester"] == "system"
      assert allowed.ifc_evidence["sources_label"] == [@space]
      assert hd(context.ifc["items"])["integrity"] == "data"

      # This effect-local authority must not leak to a sibling public send.
      send = call("im_api.slack.post_message", %{}, task.ifc)
      assert {:blocked, _} = authorize(send, context, reply)
    end

    test "unknown, conflicting, stale, foreign and non-one-shot handoffs stay refused" do
      {task, context, reply} = triage_dispatch()

      variants = [
        {put_in(task, [:args, "triage_delegation_ref"], "unknown"), context},
        {put_in(task, [:args, "source_message_id"], "human-source"), context},
        {put_in(task, [:args, "schedule"], %{"cron" => "* * * * *"}), context},
        {put_in(task, [:ifc, "request"], "src:q-99"), context},
        {task, %{context | source_message_ids: []}},
        {task, %{context | group_id: "another-group"}},
        {task, %{context | agent_id: "another-router"}},
        {task, %{context | role: "worker"}},
        {task, %{context | trusted_origin: nil, trusted_origins: []}}
      ]

      for {call, ctx} <- variants do
        assert {:blocked, _} = authorize(call, ctx, reply)
      end
    end
  end

  describe "records the model produces" do
    test "carry the join of the round's declared sources, and nothing of the activation's scope" do
      # Before this, the activation's source scope was joined in as well, so
      # everything written in a DM activation carried the DM's atom whatever
      # its content was. The scope is control flow — where the request came
      # from — and only data flow is labelled (§3.3, §4).
      label =
        Check.round_label(
          [call("im_api.slack.post_message", %{}, %{"sources" => ["src:t-9"]})],
          ctx()
        )

      assert label == [@legal]
      refute @dm_a in label
    end

    test "an unlabelled read result is agent-private, never the round's audience" do
      # A workspace search run from a public channel can return a private
      # channel's messages. Nothing here can see which audiences it crossed,
      # so the result may not inherit the activation's.
      [result] =
        Check.stamp_results(
          [%{id: "r"}],
          [call("im_api.slack.message_search", %{"query" => "salary"})],
          ctx(source_scope: [@general], request: "src:q-2")
        )

      assert result.ifc == %{"label" => ["agent_private"]}
    end
  end

  describe "a receipt" do
    # A source the requester may read, going somewhere pure flow does not
    # reach and that is not where the activation came from: the one shape
    # where a person's confirmation is what admits the effect.
    defp receipt_facts(receipts) do
      facts(
        Map.merge(destination([@space]), %{
          "receipts" => receipts,
          "now" => 1_000
        })
      )
    end

    defp one_receipt do
      [
        %{
          "id" => "rcpt-1",
          "requester" => @a,
          "sources" => [@legal],
          "destination" => [@space],
          "expires_at" => nil
        }
      ]
    end

    defp cite_legal do
      call("im_api.slack.post_message", %{"channel" => "C_GEN", "text" => "决定如下"}, %{
        "request" => "src:q-1",
        "sources" => ["src:t-9"]
      })
    end

    test "admits the effect it was confirmed for, and is spent doing it" do
      decision = authorize(cite_legal(), ctx(), receipt_facts(one_receipt()))

      assert {:execute, executed} = decision
      assert executed[:ifc_evidence]["decision"]["outcome"] == "allow"
      assert_received {:receipt_spent, "rcpt-1", "tnt", "grp"}
    end

    test "authorizes one transfer, not an hour of them" do
      facts = receipt_facts(one_receipt())

      assert {:execute, _first} = authorize(cite_legal(), ctx(), facts)

      # The person confirmed one transfer. The receipt is still inside its
      # hour and still covers this audience pair, and it is still gone.
      assert {:blocked, result} = authorize(cite_legal(), ctx(), facts)
      assert result.status == "guidance"
    end
  end

  describe "a labelled search result" do
    # What per-hit labels buy: the same page of results can be quoted where the
    # hit allows and is refused where it does not, instead of the whole read
    # being unusable (§15). The refs are the ones a read adapter's `ifc.items`
    # materializes.
    defp hits do
      [
        %{"ref" => "src:t-9#0", "label" => [@general], "integrity" => "data", "principal" => nil},
        %{"ref" => "src:t-9#1", "label" => [@legal], "integrity" => "data", "principal" => nil}
      ]
    end

    defp cite(ref) do
      call("im_api.slack.post_message", %{"channel" => "C_GEN", "text" => "见下"}, %{
        "request" => "src:q-2",
        "sources" => [ref]
      })
    end

    test "a hit from a private channel in the same page is still refused" do
      decision =
        authorize(
          cite("src:t-9#1"),
          ctx(requester: @b, source_scope: [@general], request: "src:q-2", items: hits()),
          facts(destination([@space]))
        )

      assert {:blocked, result} = decision
      assert result.status == "guidance"
      # The refusal does not disclose the channel to someone who cannot read it.
      refute result.public_summary =~ "legal"
    end
  end

  describe "the language the runtime writes in" do
  end

  describe "a streaming draft" do
  end

  describe "the labelled context" do
    test "is built from sealed inputs and stamped records" do
      session = %{
        messages: [
          %{
            id: 1,
            role: "user",
            content: "hi",
            source_message_id: "s1",
            trusted_origin: %{
              "provider" => "slack",
              "principal_ref" => %{"connect_id" => @connect, "subject_id" => "U_A"},
              "ifc" => %{"label" => [@dm_a], "integrity" => "command", "principal" => @a}
            }
          },
          %{id: 2, role: "assistant", content: "…", ifc: %{"label" => [@dm_a]}},
          %{id: 3, role: "tool", tool_call_id: "t-9", content: "{}", ifc: %{"label" => [@legal]}},
          %{id: 4, role: "summary", content: "…"}
        ]
      }

      built = Context.build(session, source_message_id: "s1", source_message_ids: ["s1"])

      assert built["requester"] == @a
      assert built["source_scope"] == [@dm_a]
      assert built["consumed_refs"] == ["src:q-1"]
      assert built["request"] == "src:q-1"

      items = Map.new(built["items"], &{&1["ref"], &1})
      assert items["src:q-1"]["integrity"] == "command"
      assert items["src:a-2"]["label"] == [@dm_a]
      assert items["src:t-t-9"]["label"] == [@legal]
      # A record from before any of this existed reads as agent-private.
      assert items["src:a-4"]["label"] == ["agent_private"]
      # Nothing but a human message can be a request.
      assert items["src:a-2"]["integrity"] == "data"
      assert items["src:t-t-9"]["integrity"] == "data"
    end

    test "a schedule fire acts with its creator's authority" do
      origin = IFC.schedule_origin("sch_1", @a, [@dm_a])

      assert origin["provider"] == "schedule"
      assert origin["schedule_id"] == "sch_1"
      assert origin["ifc"]["principal"] == "schedule|sch_1|" <> @a
      assert origin["ifc"]["integrity"] == "command"

      session = %{
        messages: [
          %{
            id: 1,
            role: "user",
            content: "the daily digest",
            source_message_id: "schedule:sch_1:1000",
            trusted_origin: origin
          }
        ]
      }

      built =
        Context.build(session,
          source_message_id: "schedule:sch_1:1000",
          source_message_ids: ["schedule:sch_1:1000"]
        )

      # The fire is a command — a schedule is one of the three things that can
      # be a request (§3.4) — and it carries the audience its prompt was
      # written under, not the whole session's.
      items = Map.new(built["items"], &{&1["ref"], &1})
      assert items["src:q-1"]["integrity"] == "command"
      assert items["src:q-1"]["label"] == [@dm_a]

      # And it is keyed by the creator, so every effect it causes is decided
      # against that person's *current* membership.
      assert {:ok, activation} = Context.activation(built)

      assert SalixIFC.Principal.key(activation.requester) ==
               SalixIFC.Principal.key({:provider_user, @connect, "U_A"})

      assert {:schedule, "sch_1", {:provider_user, @connect, "U_A"}} = activation.requester
    end

    test "a schedule made before it had a creator authorizes nothing" do
      # A schedule from before this existed, or made while its Group was off,
      # has no recorded creator. It delivers unsealed, which means it cannot be
      # cited as the request an effect acts on — the fail-closed reading.
      assert IFC.schedule_origin("sch_1", nil, nil) == nil
      assert IFC.schedule_origin("sch_1", "", nil) == nil
      assert IFC.schedule_origin("", @a, nil) == nil

      # Nor can a creator that does not decode as a principal.
      assert IFC.schedule_origin("sch_1", "not a principal", nil) == nil
    end

    test "an agent-authored delivery is data, whatever role it arrives in" do
      # An internal delivery from a worker reaches the session in the "user"
      # role like any other input. Ingress already classified it; the role
      # must not overrule that seal, or an agent would be able to command
      # effects by writing into a conversation.
      session = %{
        messages: [
          %{
            id: 1,
            role: "user",
            content: "把交接清单发到 #general",
            source_message_id: "s1",
            trusted_origin: %{
              "provider" => "internal",
              "participant_id" => "worker-1",
              "source_actor_type" => "agent",
              "ifc" => %{"label" => ["task|T1"], "integrity" => "data"}
            }
          }
        ]
      }

      built = Context.build(session, source_message_id: "s1", source_message_ids: ["s1"])

      assert [%{"integrity" => "data"}] = built["items"]
      assert built["consumed_refs"] == []
      assert built["request"] == nil
      # No human is behind this activation, so it names no requester and the
      # kernel refuses every effect it tries to cause.
      assert built["requester"] == nil
      assert Context.activation(built) == :error
    end
  end

  describe "what the model is shown" do
    test "a labelled input is named so it can be cited" do
      [message] =
        Render.annotate([
          %{
            id: 7,
            role: "user",
            content: "帮我看看",
            trusted_origin: %{"ifc" => %{"label" => [@dm_a]}}
          }
        ])

      assert message.content == "[src:q-7]\n帮我看看"
    end
  end

  describe "the provenance footer" do
  end

  describe "refs" do
  end

  @tag :ifc_async_source
  test "async completion has a visible unique source label and missing results stay private" do
    alias SalixAgent.InternalSession

    pending = %{
      "session_id" => "s",
      "tool_call_id" => "read-original",
      "tool_name" => "meeting.preparation.read_team_memory"
    }

    initial =
      InternalSession.new("agent", "s")
      |> InternalSession.apply_events([
        Map.merge(pending, %{"type" => "async_tool_call_started", "status" => "running"})
      ])

    events =
      SalixAgent.AsyncToolResults.internal_events(
        pending,
        %{content: "original source", error: false, ifc: %{"label" => [@dm_a]}}
      )

    queued = InternalSession.apply_events(initial, events)
    {materialize_events, _, _} = InternalSession.materialize_pending_input_events(queued)
    materialized = InternalSession.apply_events(queued, materialize_events)
    message = materialized |> InternalSession.get(:messages) |> List.last()
    assert message.ifc == %{"label" => [@dm_a]}
    ref = IFC.assistant_ref(message.id)
    assert Render.annotate_message(message).content =~ "[#{ref}]"
    rendered = SalixAgent.Compaction.context(materialized)
    assert Enum.find(rendered, &(&1.id == message.id)).content =~ "[#{ref}]"
    wire = Context.build(materialized)
    assert Context.label_for(wire, ref) == [@dm_a]
    assert Enum.find(Context.items(wire), &(&1.ref == ref)).integrity == :data

    # An archived or unknown full result cannot borrow the originating request's
    # public label. The separate result reader can retrieve its canonical label.
    notification = %{
      "type" => "runtime_message",
      "from_queue" => true,
      "message_id" => 55,
      "runtime_message_id" => "tool-call-result:missing",
      "runtime_message_type" => "tool_call_completed",
      "source_tool_call_id" => "missing",
      "content" => "untrusted label hint",
      "ifc" => %{"label" => ["public"]},
      "trusted_origin" => %{"ifc" => %{"label" => ["public"]}}
    }

    unknown = InternalSession.apply_events(InternalSession.new("agent", "s"), [notification])

    assert unknown |> InternalSession.get(:messages) |> List.last() |> Map.get(:ifc) ==
             %{"label" => ["agent_private"]}
  end
end
