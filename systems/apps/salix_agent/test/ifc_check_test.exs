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

  use ExUnit.Case, async: false

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
            send(self(), {:receipt_spent, id, request["tenant_id"], request["group_id"]})
            {:ok, true}
          end

        error ->
          {:error, error}
      end
    end
  end

  setup do
    Application.put_env(:salix_agent, :ifc_facts_mod, Facts)
    on_exit(fn -> Application.delete_env(:salix_agent, :ifc_facts_mod) end)
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
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:salix, :operation, :stop],
        fn _, _, _, _ -> raise "broken reporter" end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
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

  test "session history reads need no command but their output is not public" do
    for tool <- ~w(history.list history.search history.get) do
      call = call(tool, %{})
      ctx = ctx(ifc: wire(requester: nil))
      assert {:read, _} = Destination.describe(tool, %{}, ctx)
      assert {:execute, _} = authorize(call, ctx, facts(%{}))

      [result] =
        Check.stamp_results([%{id: call.id, name: tool, content: "private history"}], [call], ctx)

      refute result[:ifc]["label"] == ["public"]
    end
  end

  describe "which calls are decided" do
    test "a read is never decided, whatever it reads" do
      assert {:read, _} =
               Destination.describe("im_api.slack.message_search", %{"query" => "x"}, %{})

      assert {:read, _} = Destination.describe("fs.read_file", %{}, %{})
      assert {:none, _} = Destination.describe("help", %{}, %{})
    end

    test "a voice operation speaks into the call of its voice source" do
      ctx = %{
        trusted_origin: %{
          "provider" => "voice",
          "provider_context" => %{"connect_id" => "cnx_voice", "chat_id" => "vc_1"}
        }
      }

      for api <- ~w(im_api.voice.say im_api.voice.note im_api.voice.hang_up) do
        assert {:egress,
                %{"kind" => "provider_scope", "connect_id" => "cnx_voice", "scope_id" => "vc_1"}} =
                 Destination.describe(api, %{"text" => "hi"}, ctx)
      end

      assert {:egress, %{"scope_id" => "vc_2"}} =
               Destination.describe("im_api.voice.say", %{"call_id" => "vc_2"}, ctx)

      # Another provider's chat id never names a call.
      slack_ctx = %{
        trusted_origin: %{"provider" => "slack", "provider_context" => %{"chat_id" => "C1"}}
      }

      assert {:egress, %{"scope_id" => ""}} =
               Destination.describe("im_api.voice.say", %{"text" => "hi"}, slack_ctx)
    end

    test "every visible-filesystem operation is a read of it or a write into it" do
      # Neither may fall through to the unclassified default, which is egress
      # to `{public}`: searching a file is not publishing it, and editing one
      # is not posting it.
      for read <- ~w(fs.read_file fs.list_files fs.grep fs.glob fs.stat_file) do
        assert {:read, _} = Destination.describe(read, %{}, %{}), "#{read} must be a read"
      end

      for write <- ~w(fs.write_file fs.edit_file fs.copy_file fs.move_file fs.delete_file) do
        args = %{"path" => "/notes/a.md", "to" => "/notes/b.md", "from" => "/notes/a.md"}

        assert {:persist, %{"kind" => "agent_private"}} =
                 Destination.describe(write, args, %{}),
               "#{write} must be a private write"
      end

      # And anything new under the prefix lands on the restrictive side rather
      # than being published.
      assert {:persist, %{"kind" => "agent_private"}} =
               Destination.describe("fs.something_new", %{}, %{})
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

    test "every background Loop tool is a read, a private write, or contentless" do
      # None may fall through to public egress: reading the SDK or listing
      # one's own Loops is not publishing, and a Loop's program, config and
      # events stay with the Agent that owns it.
      for read <- ~w(loop.sdk loop.list loop.get) do
        assert {:read, _} = Destination.describe(read, %{"loop_id" => "lop1_1"}, %{}),
               "#{read} must be a read"
      end

      assert {:persist, %{"kind" => "agent_private"}} =
               Destination.describe(
                 "loop.build",
                 %{"files" => %{"main.c" => "int main(void){}"}, "path" => "/loops/main.elf"},
                 %{}
               )

      # The default artifact path is private too.
      assert {:persist, %{"kind" => "agent_private"}} =
               Destination.describe("loop.build", %{"files" => %{}}, %{})

      # Writing the object onto the Drive reaches every member's devices, the
      # way any filesystem write there does.
      assert {:persist, %{"kind" => "drive", "path" => "/drive/main.elf", "group_id" => "grp"}} =
               Destination.describe("loop.build", %{"path" => "/drive/main.elf"}, %{
                 group_id: "grp"
               })

      assert {:persist, %{"kind" => "agent_private"}} =
               Destination.describe(
                 "loop.create",
                 %{"path" => "/loops/main.elf", "config" => %{"secret" => "x"}},
                 %{}
               )

      assert {:persist, %{"kind" => "agent_private"}} =
               Destination.describe("loop.send", %{"loop_id" => "lop1_1", "payload" => %{}}, %{})

      for lifecycle <- ~w(loop.pause loop.resume loop.delete) do
        assert {:none, _} = Destination.describe(lifecycle, %{"loop_id" => "lop1_1"}, %{}),
               "#{lifecycle} carries no content"
      end
    end

    test "local Loop use under enforce needs no public-egress exception" do
      # A session carrying private content (A's DM, #legal) manages its Loops
      # with public egress denied: the reads and lifecycle calls are never
      # decided, and the private writes are admitted against the private
      # audience while the same round refuses an actual public send.
      ctx = ctx()

      for {tool, params} <- [
            {"loop.sdk", %{}},
            {"loop.list", %{}},
            {"loop.get", %{"loop_id" => "lop1_1"}},
            {"loop.pause", %{"loop_id" => "lop1_1"}},
            {"loop.resume", %{"loop_id" => "lop1_1"}},
            {"loop.delete", %{"loop_id" => "lop1_1"}},
            {"loop.webhook", %{"loop_id" => "lop1_1", "action" => "enable"}}
          ] do
        Facts.start(fn _request -> flunk("#{tool} must not be decided") end)
        assert [{:execute, _}] = Check.authorize([{:execute, call(tool, params)}], ctx)
      end

      for {tool, params} <- [
            {"loop.build", %{"files" => %{"main.c" => "int main(void){}"}}},
            {"loop.create", %{"path" => "/loops/main.elf", "config" => %{"from" => "legal"}}},
            {"loop.send", %{"loop_id" => "lop1_1", "payload" => %{"from" => "legal"}}}
          ] do
        assert {:execute, admitted} =
                 authorize(
                   call(tool, params, %{"sources" => ["src:t-9"]}),
                   ctx,
                   facts(destination(["agent_private"]))
                 )

        assert admitted.ifc_evidence["sources_label"] == [@legal]
      end

      assert {:blocked, _} =
               authorize(
                 call("web.fetch", %{"url" => "https://example.com"}, %{"sources" => ["src:t-9"]}),
                 ctx,
                 facts(destination(["public"]))
               )
    end

    test "decide cannot send a private source to its provider" do
      ctx = ctx()

      assert {:blocked, _} =
               authorize(
                 call("decide", SalixAgent.DecideFixture.args(), %{"sources" => ["src:t-9"]}),
                 ctx,
                 facts(destination(["public"]))
               )
    end

    test "a reaction moves no information and needs no decision" do
      assert {:none, _} =
               Destination.describe("im_api.slack.add_reaction", %{"channel" => "C1"}, %{})
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

    test "a Feishu send resolves the id the adapter actually addresses" do
      # `feishu.send_text` takes `receive_id` with `receive_id_type`, not
      # `chat_id`. Reading the wrong parameter left the scope empty, which the
      # resolver turns into a public destination with unknown writers — so a
      # correctly addressed send was refused under enforce however well the
      # chat was known, and no receipt could repair missing writer authority.
      assert {:egress, descriptor} =
               Destination.describe(
                 "im_api.feishu.send_text",
                 %{
                   "connect_id" => "f",
                   "receive_id_type" => "chat_id",
                   "receive_id" => "oc_room",
                   "text" => "hello"
                 },
                 %{}
               )

      assert descriptor["kind"] == "provider_scope"
      assert descriptor["scope_id"] == "oc_room"

      # `chat_id` is the adapter's default, so an omitted type is a chat.
      assert {:egress, %{"kind" => "provider_scope", "scope_id" => "oc_room"}} =
               Destination.describe(
                 "im_api.feishu.send_text",
                 %{"connect_id" => "f", "receive_id" => "oc_room", "text" => "hi"},
                 %{}
               )

      # And an id type that names a person is a person, not a room.
      for id_type <- ~w(open_id user_id union_id email) do
        assert {:egress, %{"kind" => "provider_direct", "user_id" => "ou_a"}} =
                 Destination.describe(
                   "im_api.feishu.send_text",
                   %{"connect_id" => "f", "receive_id_type" => id_type, "receive_id" => "ou_a"},
                   %{}
                 ),
               "#{id_type} addresses one person"
      end
    end

    test "a Feishu reply or edit resolves the chat the message is in" do
      # These address a message, but the audience is the place: replying to a
      # message in a private chat publishes into that chat.
      assert {:egress, descriptor} =
               Destination.describe(
                 "im_api.feishu.reply_text",
                 %{"connect_id" => "f", "message_id" => "om_1", "text" => "hi"},
                 %{}
               )

      assert descriptor["kind"] == "provider_message"
      assert descriptor["message_id"] == "om_1"
      # No hint given, so the resolver has to ask which chat it belongs to.
      assert descriptor["scope_id"] == ""

      # `reply_text` carries the source chat for its own reasons; when it does,
      # that spares the round trip.
      assert {:egress, %{"kind" => "provider_message", "scope_id" => "oc_room"}} =
               Destination.describe(
                 "im_api.feishu.reply_text",
                 %{"connect_id" => "f", "message_id" => "om_1", "chat_id" => "oc_room"},
                 %{}
               )

      assert {:egress, %{"kind" => "provider_message", "message_id" => "om_2"}} =
               Destination.describe(
                 "im_api.feishu.update_message",
                 %{"connect_id" => "f", "message_id" => "om_2", "text" => "fixed"},
                 %{}
               )
    end

    test "a memory write targets the Group's audience" do
      assert {:persist, %{"kind" => "memory"}} =
               Destination.describe("memory.write", %{"path" => "/memory/index.md"}, %{
                 group_id: "grp"
               })
    end

    test "unless it goes to the per-audience home, which has its own kind" do
      assert {:persist, %{"kind" => "memory_scoped"}} =
               Destination.describe("memory.write", %{"path" => "/memory/scoped/legal.md"}, %{
                 group_id: "grp"
               })

      # One flat segment, `.md`, like the environments family. Anything else is
      # ordinary Group memory and is refused by the write path's own gate.
      for not_scoped <- [
            "/memory/scoped/nested/legal.md",
            "/memory/scoped/legal.txt",
            "/memory/scoped/",
            "/memory/scopedish.md"
          ] do
        assert {:persist, %{"kind" => "memory"}} =
                 Destination.describe("memory.write", %{"path" => not_scoped}, %{group_id: "grp"}),
               "#{not_scoped} is not a scoped home"
      end
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

    test "Group-visible content can update a purpose without public declassification" do
      group_label = "group|grp"
      input = wire() |> put_in(["items", Access.at(0), "label"], [group_label])
      input = Map.put(input, "source_scope", [group_label])

      Facts.start(fn request ->
        assert request["destination"] == %{"kind" => "agent_configuration", "group_id" => "grp"}
        {:ok, facts(destination([group_label]))}
      end)

      update =
        call("agent.update", %{"agent_id" => "worker", "purpose" => "Difficult general tasks"}, %{
          "request" => "src:q-1",
          "sources" => ["src:q-1"]
        })

      assert [{:execute, _}] = Check.authorize([{:execute, update}], ctx(ifc: input))
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

    test "nor copied or moved onto it from the workspace" do
      for move <- ~w(fs.copy_file fs.move_file) do
        decision =
          authorize(
            call(move, %{"from" => "/notes/private.md", "to" => "/drive/private.md"}, %{
              "request" => "src:q-1",
              "sources" => ["src:t-9"]
            }),
            ctx(),
            facts(destination(["group|grp"]))
          )

        assert {:blocked, %{status: "guidance"}} = decision, "#{move} must be refused"
      end
    end

    test "while the same content stays private in the workspace" do
      decision =
        authorize(
          call("fs.write_file", %{"path" => "/notes/leaked.txt", "content" => "note"}, %{
            "request" => "src:q-1",
            "sources" => ["src:q-1"]
          }),
          ctx(),
          facts(destination(["agent_private"]))
        )

      assert {:execute, _admitted} = decision
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

    test "a note that drew on two places carries both" do
      decision =
        authorize(
          call("memory.write", %{"path" => "/memory/scoped/mixed.md", "content" => "note"}, %{
            "request" => "src:q-1",
            "sources" => ["src:t-9", "src:t-11"]
          }),
          ctx(),
          facts(destination(["agent_private"]))
        )

      assert {:execute, admitted} = decision
      # `public` is the identity of the intersection, so the join with #legal
      # is #legal alone.
      assert admitted.ifc_evidence["sources_label"] == [@legal]
    end

    test "declaring nothing means the whole context, and is not a way to widen" do
      # `sources: :context` is the honest fail-closed reading: the note
      # inherits everything the session is carrying, which is exactly what a
      # model that declared nothing may have drawn on.
      decision =
        authorize(
          call("memory.write", %{"path" => "/memory/scoped/all.md", "content" => "note"}),
          ctx(),
          facts(destination(["agent_private"]))
        )

      assert {:execute, admitted} = decision
      label = admitted.ifc_evidence["sources_label"]

      assert @legal in label
      assert @dm_a in label
      assert @finance in label
    end
  end

  test "shared meeting preparation cannot persist private content for later publication" do
    for {tool, params} <- [
          {"meeting.preparation.publish_report", %{"report" => "private notes"}},
          {"meeting.preparation.record_decision",
           %{"decision" => "required", "baseline" => %{"known_facts" => ["private notes"]}}}
        ] do
      assert {:egress, %{"kind" => "public"}} = Destination.describe(tool, params, %{})

      assert {:blocked, result} =
               authorize(
                 call(tool, params, %{"request" => "src:q-2", "sources" => ["src:t-9"]}),
                 ctx(requester: @b, source_scope: [@general], request: "src:q-2"),
                 facts(destination(["public"]))
               )

      assert result.status == "guidance"
    end
  end

  test "personal meeting publication uses its exact direct audience and rejects a different reader" do
    params = %{"connect_id" => @connect, "user_id" => "U_A", "report" => "Private preparation"}

    assert {:egress, %{"kind" => "provider_direct", "connect_id" => @connect, "user_id" => "U_A"}} =
             Destination.describe("meeting.preparation.publish_personal_report", params, ctx())

    effect =
      call("meeting.preparation.publish_personal_report", params, %{"sources" => ["src:t-9"]})

    assert {:execute, admitted} = authorize(effect, ctx(), facts(destination([@dm_a])))
    assert admitted.ifc_evidence["sources_label"] == [@legal]

    dm_b = "scope|cnx1|@U_B"

    reply =
      facts(destination([dm_b]))
      |> put_in(["membership", dm_b], %{"members" => [@b], "revision" => 1})
      |> put_in(["scopes", dm_b], %{"kind" => "direct", "within" => @space})

    assert {:blocked, result} = authorize(put_in(effect, [:args, "user_id"], "U_B"), ctx(), reply)
    assert result.status == "guidance"
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
    test "reports all restricted sources and guides a retry with revised content" do
      context = ctx(requester: @b, source_scope: [@general], request: "src:q-2")
      reply = facts(destination([@space]))
      declaration = %{"request" => "src:q-2", "sources" => ["src:q-1", "src:t-9", "src:t-11"]}

      assert {:blocked, result} =
               authorize(
                 call(
                   "im_api.slack.post_message",
                   %{"channel" => "C_GEN", "text" => "restricted content"},
                   declaration
                 ),
                 context,
                 reply
               )

      guidance = Jason.decode!(result.content)
      assert Enum.map(guidance["source_failures"], & &1["ref"]) == ["src:q-1", "src:t-9"]
      assert Enum.all?(guidance["source_failures"], &(&1["clause"] == "flow_denied"))

      refute result.public_summary =~ "legal"

      assert {:execute, _} =
               authorize(
                 call(
                   "im_api.slack.post_message",
                   %{"channel" => "C_GEN", "text" => "public information only"},
                   %{declaration | "sources" => ["src:t-11"]}
                 ),
                 context,
                 reply
               )
    end

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

    test "the request is a source only when its own content is in the effect" do
      # A dictates the text instead: the DM's words are the content, and the
      # DM's audience decides. B's channel is not among its readers.
      dictated =
        call("im_api.slack.post_message", %{"channel" => "C_GEN", "text" => "如下"}, %{
          "request" => "src:q-1",
          "sources" => ["src:q-1"]
        })

      assert {:blocked, result} = authorize(dictated, ctx(), facts(destination([@space])))
      assert Jason.decode!(result.content)["clause"] == "flow_denied"
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

    test "an empty declaration is honest and passes" do
      decision =
        authorize(
          call("env.exec", %{"command" => "ls"}, %{"sources" => []}),
          ctx(),
          facts(destination(["public"]))
        )

      assert {:execute, _call} = decision
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

    test "encoded source arrays retain the same source authorization" do
      for sources <- [["src:q-1"], Jason.encode!(["src:q-1"])] do
        assert {:blocked, result} =
                 authorize(
                   call("im_api.slack.post_message", %{"channel" => "C_GEN"}, %{
                     "request" => "src:q-2",
                     "sources" => sources
                   }),
                   ctx(requester: @b, source_scope: [@general], request: "src:q-2"),
                   facts(destination([@space]))
                 )

        assert Jason.decode!(result.content)["clause"] == "flow_denied"
      end
    end

    test "is lifted off the arguments so no tool ever sees it" do
      assert {%{"a" => 1}, %{"sources" => []}} =
               Declaration.lift(%{"a" => 1, "ifc" => %{"sources" => []}})

      assert {%{"a" => 1}, nil} = Declaration.lift(%{"a" => 1})
    end

    test "is read from a raw call envelope too, for the round's own label" do
      raw = %{
        "name" => "call",
        "args" => %{"tool" => "x", "params" => %{}, "ifc" => %{"sources" => ["src:q-1"]}}
      }

      assert Declaration.from_call(raw).sources == ["src:q-1"]
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

    test "and stamps no label on its transcript" do
      assert Check.round_label([], %{}) == nil
      assert Check.stamp_results([%{id: "r"}], [], %{}) == [%{id: "r"}]
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

    test "an auditing Group is not blocked by an observability fault" do
      Facts.start(fn _request -> {:error, :unavailable} end)

      assert [{:execute, _call}] =
               Check.authorize(
                 [{:execute, call("im_api.slack.post_message", %{"channel" => "C_GEN"})}],
                 ctx(mode: :audit)
               )
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

    test "a valid product command still checks every declared source" do
      {task, context, reply} = triage_dispatch()

      assert {:blocked, _} =
               authorize(put_in(task, [:ifc, "sources"], ["src:t-99"]), context, reply)

      context =
        update_in(context, [:ifc, "items"], fn items ->
          items ++ [%{"ref" => "src:t-99", "integrity" => "data", "label" => ["agent_private"]}]
        end)

      assert {:blocked, _} =
               authorize(put_in(task, [:ifc, "sources"], ["src:t-99"]), context, reply)
    end
  end

  describe "records the model produces" do
    test "dependency results use the captured whole-batch label, preserving read restrictions" do
      write = call("im_api.slack.post_message", %{}, %{"sources" => []})
      read = call("im_api.slack.message_search", %{}, %{"sources" => ["src:t-9"]})
      round = Check.round_label([write, read], ctx())
      result = %{id: "deferred", content: "completed"}

      assert Check.stamp_result(result, write, ctx(), round).ifc["label"] == [@legal]

      assert Check.stamp_result(result, read, ctx(), round).ifc ==
               %{"label" => ["agent_private"]}

      provided = Map.put(result, :ifc, %{"label" => [@finance]})
      assert Check.stamp_result(provided, read, ctx(), round) == provided
      assert Check.stamp_result(result, write, %{}, nil) == result
    end

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

    test "carry the request's audience exactly when the request was declared a source" do
      label =
        Check.round_label(
          [call("im_api.slack.post_message", %{}, %{"sources" => ["src:q-1", "src:t-11"]})],
          ctx()
        )

      assert label == [@dm_a]
    end

    test "carry the whole context when the round declares nothing" do
      label = Check.round_label([call("im_api.slack.post_message", %{})], ctx())
      assert @legal in label
      assert @finance in label
      assert @dm_a in label
    end

    test "carry the whole context when the round made no effect at all" do
      # Assistant text with no tool call declared nothing about what it drew
      # on; without the scope as a floor, the honest reading is everything.
      label = Check.round_label([], ctx())
      assert @legal in label
      assert @finance in label
      assert @dm_a in label
    end

    test "a read tool's own label wins over the round's" do
      [result] =
        Check.stamp_results(
          [%{id: "r", ifc: %{"label" => [@legal]}}],
          [call("im_api.slack.message_search", %{})],
          ctx()
        )

      assert result.ifc == %{"label" => [@legal]}
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

    test "a write's own result still carries the round's label" do
      [result] =
        Check.stamp_results(
          [%{id: "r"}],
          [call("im_api.slack.post_message", %{}, %{"sources" => ["src:t-9"]})],
          ctx()
        )

      assert result.ifc["label"] == [@legal]
    end

    test "an honest citation of an unlabelled search result cannot leave the session" do
      search = call("im_api.slack.message_search", %{"query" => "salary"})
      activation = ctx(requester: @b, source_scope: [@general], request: "src:q-2")

      [%{ifc: %{"label" => label}}] =
        Check.stamp_results([%{id: "r"}], [search], activation)

      # The model cites the hit exactly as it should — no omission, no false
      # provenance — and the flow is still refused, because the runtime never
      # established that the hit was public.
      decision =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN"}, %{
            "request" => "src:q-2",
            "sources" => ["src:t-99"]
          }),
          ctx(
            requester: @b,
            source_scope: [@general],
            request: "src:q-2",
            items: [
              %{"ref" => "src:t-99", "label" => label, "integrity" => "data", "principal" => nil}
            ]
          ),
          facts(destination([@space]))
        )

      assert {:blocked, result} = decision
      assert result.status == "guidance"
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

    test "is not spent under audit, which may not change an outcome" do
      facts = Map.put(receipt_facts(one_receipt()), "mode", "audit")
      decision = authorize(cite_legal(), ctx(mode: :audit), facts)

      assert {:execute, _executed} = decision
      refute_received {:receipt_spent, _id, _tenant, _group}
    end

    test "a later failed claim blocks dispatch without restoring an earlier receipt" do
      finance = %{
        "id" => "rcpt-2",
        "requester" => @a,
        "sources" => [@finance, "tag|finance"],
        "destination" => [@space],
        "expires_at" => nil
      }

      Process.put(:ifc_test_spent, MapSet.new(["rcpt-2"]))
      on_exit(fn -> Process.delete(:ifc_test_spent) end)

      both = put_in(cite_legal(), [:ifc, "sources"], ["src:t-9", "src:t-10"])
      reply = receipt_facts(one_receipt() ++ [finance])

      assert {:blocked, _} = authorize(both, ctx(), reply)
      assert_received {:receipt_spent, "rcpt-1", "tnt", "grp"}
      refute_received {:receipt_spent, "rcpt-2", _, _}
      assert {:blocked, _} = authorize(cite_legal(), ctx(), reply)
    end

    test "a store that cannot answer refuses the effect rather than guessing" do
      Process.put(:ifc_test_receipt_error, :unavailable)
      on_exit(fn -> Process.delete(:ifc_test_receipt_error) end)

      assert {:blocked, result} =
               authorize(cite_legal(), ctx(), receipt_facts(one_receipt()))

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

    test "a hit from a public channel can be quoted into that space" do
      decision =
        authorize(
          cite("src:t-9#0"),
          ctx(requester: @b, source_scope: [@general], request: "src:q-2", items: hits()),
          facts(destination([@space]))
        )

      assert {:execute, executed} = decision
      assert executed[:ifc_evidence]["decision"]["outcome"] == "allow"
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
    test "a refusal and a footer follow the Group, not the model" do
      # Both sentences are composed by the runtime, so they cannot follow the
      # model's instruction to answer in the asker's language. A workspace that
      # works in English would otherwise get a Chinese sentence at exactly the
      # moment it needs to be understood (§6.4).
      refusal =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN"}, %{
            "request" => "src:q-1",
            "sources" => ["src:t-9"]
          }),
          ctx(),
          facts(Map.merge(destination([@space]), %{"language" => "en"}))
        )

      assert {:blocked, result} = refusal
      assert result.public_summary =~ "cannot be repeated here"
      # And it still names the source only because this requester can read it.
      assert result.public_summary =~ "#legal"

      assert Provenance.footer(["#legal"], :en) == "Includes information from #legal"
      assert Provenance.footer(["#legal"], :zh) == "包含来自 #legal 的信息"
      assert Provenance.footer([], :en) == nil
    end

    test "is Chinese unless the Group says otherwise" do
      # The default has to stay what every existing workspace already reads: a
      # default that changes what people see is a regression dressed as a
      # feature.
      assert IFC.language(%{}) == :zh
      assert IFC.language(%{"language" => "zh"}) == :zh
      assert IFC.language(%{"language" => "en"}) == :en

      # An unknown tag is the default, not a crash and not an empty sentence.
      assert IFC.language(%{"language" => "de"}) == :zh
      assert IFC.language(nil) == :zh

      decision =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN"}, %{
            "request" => "src:q-1",
            "sources" => ["src:t-9"]
          }),
          ctx(),
          facts(destination([@space]))
        )

      assert {:blocked, result} = decision
      assert result.public_summary =~ "不能在这里复述"
    end

    test "a source with no display name is still said, in that language" do
      # Dropping the origin would turn "this came from somewhere else" into
      # silence, which is the one thing rule B exists to prevent. A member
      # answering in place declassifies #legal; the resolver happens to have no
      # name for it, so the footer says what it can.
      decision =
        authorize(
          call("im_api.slack.post_message", %{"channel" => "C_GEN", "text" => "hi"}, %{
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
          facts(Map.merge(destination([@space]), %{"language" => "en", "display_names" => %{}}))
        )

      assert {:execute, admitted} = decision
      assert admitted[:ifc_evidence]["declassified"] == ["another conversation"]
      assert admitted[:args]["text"] =~ "Includes information from another conversation"
    end
  end

  describe "a streaming draft" do
    test "waits for the decision under enforce, and streams otherwise" do
      # The draft reaches the conversation before the round has declared what
      # it drew on, so an enforced Group cannot show it and then refuse: the
      # audience has already read it.
      refute IFC.draft_before_decision?(:enforce)
      refute IFC.draft_before_decision?("enforce")

      # Audit may never change what happens, and an off Group is untouched.
      assert IFC.draft_before_decision?(:audit)
      assert IFC.draft_before_decision?("audit")
      assert IFC.draft_before_decision?(:off)
      assert IFC.draft_before_decision?(nil)
      assert IFC.draft_before_decision?("nonsense")
    end
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

    test "a list result's elements are citable one by one" do
      session = %{
        messages: [
          %{
            id: 3,
            role: "tool",
            tool_call_id: "t-9",
            content: "{}",
            ifc: %{
              "label" => [@legal, @finance],
              "items" => [
                %{"index" => 0, "label" => [@legal]},
                %{"index" => 1, "label" => [@finance]}
              ]
            }
          }
        ]
      }

      items =
        session
        |> Context.build()
        |> Map.get("items")
        |> Map.new(&{&1["ref"], &1})

      assert items["src:t-t-9#0"]["label"] == [@legal]
      assert items["src:t-t-9#1"]["label"] == [@finance]
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

    test "an activation with no requester can command nothing" do
      assert Context.activation(%{"requester" => nil}) == :error
      assert {:ok, _activation} = Context.activation(wire())
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

    test "a person's delivery in the same shape still commands" do
      session = %{
        messages: [
          %{
            id: 1,
            role: "user",
            content: "把交接清单发到 #general",
            source_message_id: "s1",
            trusted_origin: %{
              "provider" => "internal",
              "participant_id" => "U_A",
              "source_actor_type" => "user",
              "ifc" => %{"label" => ["conversation|K1"], "integrity" => "command"}
            }
          }
        ]
      }

      built = Context.build(session, source_message_id: "s1", source_message_ids: ["s1"])

      assert [%{"integrity" => "command"}] = built["items"]
      assert built["consumed_refs"] == ["src:q-1"]
      assert built["request"] == "src:q-1"
      assert built["requester"] == "comma_user|U_A"
      assert {:ok, _activation} = Context.activation(built)
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

    test "annotating twice does not stack" do
      once =
        Render.annotate_message(%{
          id: 7,
          role: "user",
          content: "x",
          trusted_origin: %{"ifc" => %{}}
        })

      assert Render.annotate_message(once) == once
    end

    test "an unlabelled message renders exactly as before" do
      message = %{id: 7, role: "user", content: "x", trusted_origin: %{}}
      assert Render.annotate_message(message) == message

      assert Render.annotate_message(%{id: 8, role: "assistant", content: "y"}) == %{
               id: 8,
               role: "assistant",
               content: "y"
             }
    end
  end

  describe "the provenance footer" do
    test "names only what was declassified" do
      assert Provenance.footer([]) == nil
      assert Provenance.footer(["#legal", "私聊"]) == "包含来自 #legal、私聊 的信息"
    end

    test "appends to a text body and to conversation content blocks" do
      assert Provenance.apply("im_api.slack.post_message", %{"text" => "a"}, "F") == %{
               "text" => "a\n\nF"
             }

      assert Provenance.apply(
               "im_api.internal.send_message",
               %{"content" => [%{"type" => "text", "text" => "a"}]},
               "F"
             ) == %{
               "content" => [
                 %{"type" => "text", "text" => "a"},
                 %{"type" => "text", "text" => "F"}
               ]
             }
    end

    test "leaves an operation with no text body alone" do
      assert Provenance.apply("im_api.slack.upload_file", %{"file" => "x"}, "F") == %{
               "file" => "x"
             }

      assert Provenance.apply("im_api.slack.post_message", %{"text" => "a"}, nil) == %{
               "text" => "a"
             }
    end
  end

  describe "refs" do
    test "name inputs, results, result elements and assistant records" do
      assert IFC.input_ref("q1") == "src:q-q1"
      assert IFC.result_ref("t1") == "src:t-t1"
      assert IFC.result_item_ref("t1", 2) == "src:t-t1#2"
      assert IFC.assistant_ref(4) == "src:a-4"
      assert IFC.input_ref("") == nil
      assert IFC.result_ref(nil) == nil
    end

    test "a principal comes only from a sealed origin" do
      assert IFC.principal(%{"principal_ref" => %{"connect_id" => "c", "subject_id" => "u"}}) ==
               {:provider_user, "c", "u"}

      assert IFC.principal(%{"provider" => "slack"}) == nil
      assert IFC.principal(nil) == nil
    end

    test "an internal participant id is a principal only when a person authored it" do
      internal = %{"provider" => "internal", "participant_id" => "p1"}

      assert IFC.principal(Map.put(internal, "source_actor_type", "user")) == {:comma_user, "p1"}

      assert IFC.principal(Map.put(internal, "ifc", %{"integrity" => "command"})) ==
               {:comma_user, "p1"}

      # A worker's own delivery names the worker here. Reading that as a
      # person would let an agent-authored message command effects.
      assert IFC.principal(Map.put(internal, "source_actor_type", "agent")) == nil
      assert IFC.principal(Map.put(internal, "ifc", %{"integrity" => "data"})) == nil

      # The seal outranks the actor type, and a delivery that claims neither
      # says nothing about authorship.
      assert IFC.principal(
               internal
               |> Map.put("source_actor_type", "user")
               |> Map.put("ifc", %{"integrity" => "data"})
             ) == nil

      assert IFC.principal(internal) == nil
    end
  end

  @tag :ifc_result_reader
  test "stored result retrieval reads private session data without declaring public egress" do
    Facts.start(fn _ -> {:ok, Map.merge(facts(%{}), destination(["public"]))} end)

    call = %{
      id: "retrieve",
      name: "tool_call.get_result",
      args: %{"result_ref" => "trf1_0000000000000000001"}
    }

    ctx = %{ifc_mode: :enforce, ifc: wire(), agent_id: "researcher", session_id: "own-session"}
    assert [{:execute, ^call}] = Check.authorize([{:execute, call}], ctx)
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
