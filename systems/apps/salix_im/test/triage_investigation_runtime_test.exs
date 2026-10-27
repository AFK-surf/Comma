defmodule SalixIM.TriageInvestigationRuntimeTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:conversation_log_recovery]
  use SalixAgent.TestSupport.Settle
  alias SalixIM.{ConversationServer, Conversations, TaskConversationInput}
  alias SalixIM.Triage.InvestigationAuthority
  alias SalixStore.{CasRecord, Crypto, Ids, Keys, Repo, RuntimeIds, TriageKeys, ULID}
  alias SalixAgent.InternalSessionStore
  alias SalixAgent.TestSupport.SessionData

  defmodule Ports do
    def authorize_target(_, _, _), do: :ok
    def prepare(_, _, _), do: raise("Stale investigation must not reach Task creation")
    def complete(_, _, _), do: raise("No model belongs in the runtime boundary regression")

    def complete_stream(_, _, _, _),
      do: raise("No model belongs in the runtime boundary regression")

    def read_thread(_, _, _) do
      state = Agent.get(__MODULE__, & &1)
      if state[:source_unavailable], do: {:error, :source_unavailable}, else: {:ok, state.page}
    end

    def notify_conversation(agent, source),
      do: SalixAgent.AgentActor.notify_conversation(agent, source)

    def deliver(agent_id, payload, opts) do
      Agent.update(
        __MODULE__,
        &Map.update!(&1, :inputs, fn xs -> xs ++ [{agent_id, payload, opts}] end)
      )

      if payload[:trusted_origin]["task_conversation_id"] do
        {pause?, failure?, pid} =
          Agent.get_and_update(__MODULE__, fn state ->
            failures = Map.get(state, :context_failures, 0)

            {{Map.get(state, :pause_context, false), failures > 0, state.pid},
             Map.put(state, :context_failures, max(failures - 1, 0))}
          end)

        if pause? do
          SystemsRuntime.Proc.send(pid, {:context_paused, SystemsRuntime.Proc.self()})

          SystemsRuntime.Proc.receive do
            :release -> :ok
          end
        end

        if failure?,
          do: {:error, :temporary_context_failure},
          else: stage(agent_id, payload, opts)
      else
        stage(agent_id, payload, opts)
      end
    end

    defp stage(agent_id, payload, opts) do
      if Agent.get(__MODULE__, &(&1[:unavailable_agent] == agent_id)) do
        if Agent.get(__MODULE__, & &1[:pause_unavailable]) do
          SystemsRuntime.Proc.send(
            Agent.get(__MODULE__, & &1.pid),
            {:agent_unavailable, SystemsRuntime.Proc.self()}
          )

          SystemsRuntime.Proc.receive do
            :release -> :ok
          end
        end

        {:error, :unavailable}
      else
        stage_available(agent_id, payload, opts)
      end
    end

    defp stage_available(agent_id, payload, opts) do
      run_worker = Agent.get(__MODULE__, &Map.get(&1, :run_worker, false))

      if run_worker do
        Agent.update(
          __MODULE__,
          &Map.put(&1, :replay_fixture, %{
            group: SalixStore.Ids.group_id_from_agent!(agent_id),
            task: payload.trusted_origin["conversation_id"]
          })
        )
      end

      result = SalixAgent.deliver(agent_id, payload, Keyword.put(opts, :no_wake, not run_worker))

      {pause?, pid} =
        Agent.get(__MODULE__, &{Map.get(&1, :pause_accepted_agent) == agent_id, &1.pid})

      if pause? do
        SystemsRuntime.Proc.send(
          pid,
          {:agent_accepted, SystemsRuntime.Proc.self(), opts[:source_message_id], result}
        )

        SystemsRuntime.Proc.receive do
          :release -> :ok
        end
      end

      result
    end

    def get_session(agent_id, session_id, opts),
      do: SalixAgent.Runtime.get_session(agent_id, session_id, opts)

    def get_session_messages(agent_id, session_id),
      do: SalixAgent.Runtime.get_session_messages(agent_id, session_id)

    def find_message(_, _, _, _, operation) do
      state = Agent.get(__MODULE__, & &1)

      if Map.get(state, :pause_reply_lookup, false) do
        SystemsRuntime.Proc.send(state.pid, {:reply_lookup_paused, SystemsRuntime.Proc.self()})

        SystemsRuntime.Proc.receive do
          :release -> :ok
        end
      end

      {:ok, Agent.get(__MODULE__, &Map.get(&1.posts, operation))}
    end

    def post_message(tenant, connect, params) do
      case Agent.get(__MODULE__, &Map.get(&1, :reject_post)) do
        nil ->
          accept_post(tenant, connect, params)

        reason ->
          SystemsRuntime.Proc.send(Agent.get(__MODULE__, & &1.pid), {:slack_rejected, reason})
          {:error, reason}
      end
    end

    defp accept_post(_, _, params) do
      operation = get_in(params, ["metadata", "event_payload", "operation_ref"])

      result = %{
        "channel" => params["channel"],
        "ts" => "1789113602.000001",
        "text" => params["text"]
      }

      Agent.update(__MODULE__, fn state ->
        SystemsRuntime.Proc.send(state.pid, {:slack_post, params})
        %{state | posts: Map.put(state.posts, operation, result)}
      end)

      case Agent.get(__MODULE__, &Map.get(&1, :post_error)) do
        nil -> {:ok, result}
        reason -> {:error, reason}
      end
    end
  end

  defmodule CanonicalTasks do
    def prepare(_claim, _delegation, request_id), do: {:ok, request_id}

    def commit(request_id) do
      fixture = Agent.get(Ports, & &1.intake_fixture)
      fixture = SalixIM.TriageInvestigationRuntimeTest.create_fixture_task!(fixture, [])
      Agent.update(Ports, &Map.put(&1, :intake_fixture, fixture))

      {:ok,
       %{
         "disposition" => "created",
         "request_id" => request_id,
         "conversation_id" => fixture.task,
         "worker_agent_id" => fixture.worker
       }}
    end
  end

  defmodule CapturedWorker do
    # Replace only model output. The real Session, tools, IFC, Task and result
    # Participant execute the captured decision. No second tool loop belongs here.
    def complete(messages, _tools, _opts) do
      {round, fixture} =
        Agent.get_and_update(Ports, fn state ->
          round = Map.get(state, :worker_rounds, 0) + 1
          {{round, state.replay_fixture}, Map.put(state, :worker_rounds, round)}
        end)

      case round do
        1 ->
          call("read-source", "im_api.internal.triage.read_source", %{"connect_id" => "internal"})

        2 ->
          {:ok, stored} =
            Conversations.list_group_conversation_messages(fixture.group, fixture.task, limit: 20)

          source = Enum.find(stored, &get_in(&1, ["metadata", "triage_investigation_source"]))

          if is_nil(source) or not String.contains?(Jason.encode!(messages), source["message_id"]),
            do: raise("the real source tool result did not reach the Worker")

          call("complete", "im_api.internal.triage.complete", %{
            "connect_id" => "internal",
            "source_snapshot" => source["message_id"],
            "decision" => %{
              "kind" => "silence",
              "reason_code" => "insufficient_evidence",
              "reason" => "The referenced investigation thread is not indexed yet.",
              "source_refs" => []
            }
          })

        3 ->
          {:assistant, "", [%{id: "done", name: "end_turn", args: %{"outcome" => "done"}}]}

        _ ->
          raise "captured Worker exceeded its three-request budget"
      end
    end

    def complete_stream(messages, tools, _on_delta, opts), do: complete(messages, tools, opts)

    defp call(id, tool, params) do
      args = %{"tool" => tool, "params" => params}
      # The captured private reason is fixture text, not a claim derived from
      # the source body. The snapshot ID is a control locator, not disclosure.
      args = if id == "complete", do: Map.put(args, "ifc", %{"sources" => []}), else: args
      {:assistant, "", [%{id: id, name: "call", args: args}]}
    end
  end

  defmodule SlackHTTP do
    use Plug.Builder
    plug(:dispatch)

    defp dispatch(conn, _) do
      conn = Plug.Conn.fetch_query_params(conn)

      body =
        case conn.request_path do
          "/api/conversations.info" ->
            %{
              "ok" => true,
              "channel" => %{"id" => "C_TEST", "is_private" => false, "is_member" => true}
            }

          "/api/conversations.members" ->
            %{
              "ok" => true,
              "members" => ["U_HUMAN", "U_BOT"],
              "response_metadata" => %{"next_cursor" => ""}
            }

          "/api/reactions.get" ->
            state = Agent.get(Ports, & &1)
            SystemsRuntime.Proc.send(state.pid, {:reaction_read, conn.query_params})

            reactions =
              for {timestamp, emoji} <- Map.get(state, :reactions, []),
                  timestamp == conn.params["timestamp"],
                  do: %{"name" => emoji, "users" => ["U_BOT"]}

            %{
              "ok" => true,
              "type" => "message",
              "channel" => conn.params["channel"],
              "message" => %{"ts" => conn.params["timestamp"], "reactions" => reactions}
            }

          "/api/reactions.add" ->
            {:ok, raw, _} = Plug.Conn.read_body(conn)
            params = URI.decode_query(raw)

            {pause?, pid} =
              Agent.get_and_update(Ports, fn state ->
                next =
                  Map.update(
                    state,
                    :reactions,
                    [{params["timestamp"], params["name"]}],
                    &Enum.uniq([{params["timestamp"], params["name"]} | &1])
                  )

                {{Map.get(state, :pause_reaction, false), state.pid}, next}
              end)

            SystemsRuntime.Proc.send(pid, {:reaction_added, SystemsRuntime.Proc.self(), params})

            if pause?,
              do:
                (SystemsRuntime.Proc.receive do
                   :release -> :ok
                 end)

            %{"ok" => true}

          _ ->
            %{"ok" => false, "error" => "unexpected_test_request"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  defmodule Source do
    alias SalixIM.ConversationSource
    defdelegate prefetch(agent), to: ConversationSource
    defdelegate notify(agent, source), to: ConversationSource
    defdelegate binding(agent, source), to: ConversationSource
    defdelegate batch(binding, progress), to: ConversationSource
    defdelegate reject(binding, message, reason), to: ConversationSource
    defdelegate retire(binding), to: ConversationSource

    def entry(binding, message) do
      with {:ok, entry} <- ConversationSource.entry(binding, message) do
        if entry[:conversation_scan_only] do
          {:ok, entry}
        else
          # Inject acknowledgment loss at the real Session boundary. The consumer
          # then commits the same deduped input with its source frontier.
          with {:ok, _} <-
                 SalixIM.TriageInvestigationRuntimeTest.Ports.deliver(
                   binding.agent["agent_id"],
                   entry.payload,
                   source_message_id: entry.source_message_id,
                   no_wake: entry.payload[:no_wake] == true
                 ) do
            run_worker =
              Agent.get(
                SalixIM.TriageInvestigationRuntimeTest.Ports,
                &Map.get(&1, :run_worker, false)
              )

            {:ok, put_in(entry.payload[:no_wake], not run_worker)}
          end
        end
      end
    end
  end

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixAgent.TestSupport.stop_all_agents()

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port ->
        {Bandit, plug: SlackHTTP, port: port}
      end)

    overrides = [
      {:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api"},
      {:salix_im, :conversation_delivery_lease_ms, 200},
      {:salix_im, :conversation_delivery_retry_backoff_ms, 100},
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, Ports},
      {:salix_agent, :ifc_facts_mod, SalixIM.IFC.Facts},
      {:salix_im, :agent_delivery_mod, Ports},
      {:salix_agent, :conversation_source_mod, Source},
      {:salix_im, :triage_delegation_mod, Ports},
      {:salix_im, :slack_triage_clickhouse_reader_mod, Ports},
      {:salix_im, :slack_triage_reply_delivery_mod, Ports},
      {:salix_im, :conversation_placement, SalixIM.ConversationPlacement.LocalFleet}
    ]

    previous =
      for {app, key, value} <- overrides do
        old = SystemsRuntime.fetch_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, old}
      end

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> SystemsRuntime.put_env(app, key, value)
          :error -> SystemsRuntime.delete_env(app, key)
        end
      end
    end)

    start_supervised!(SalixStore.S3.Fake)
    test_pid = SystemsRuntime.Proc.self()

    start_supervised!(%{
      id: :ports,
      start:
        {Agent, :start_link,
         [fn -> %{pid: test_pid, posts: %{}, inputs: [], page: nil} end, [name: Ports]]}
    })

    :ok
  end

  defmodule RetiredDuringAdmission do
    defdelegate prefetch(agent), to: SalixIM.ConversationSource
    defdelegate binding(agent, source), to: SalixIM.ConversationSource
    defdelegate batch(binding, progress), to: SalixIM.ConversationSource
    defdelegate reject(binding, message, reason), to: SalixIM.ConversationSource
    defdelegate retire(binding), to: SalixIM.ConversationSource

    def entry(binding, message) do
      SalixAgent.TestSupport.RetiredSessionFixture.put!(binding.agent, binding.session_id)
      SalixIM.ConversationSource.entry(binding, message)
    end
  end

  for path <- [:consumer, :recovery, :admission] do
    @retired_path path
    @tag :retired_triage
    test "a retired Triage command escalates through #{@retired_path}" do
      SystemsRuntime.put_env(:salix_agent, :conversation_source_mod, nil)
      f = create_fixture_task!(fixture!(skip_task_creation: true), pause_task_context: true)
      settle()

      {:ok, %{"participants" => participants}} =
        Conversations.list_group_conversation_participants(f.group, f.task)

      participant = Enum.find(participants, &(&1["agent_id"] == f.worker))
      session = participant["payload"]["session_id"]
      {:ok, worker} = SalixAgent.AgentControl.get_record(f.worker)

      if @retired_path != :admission,
        do: SalixAgent.TestSupport.RetiredSessionFixture.put!(worker, session)

      source = %{
        group_id: f.group,
        conversation_id: f.task,
        participant_id: participant["participant_id"]
      }

      SystemsRuntime.put_env(:salix_agent, :conversation_source_mod, SalixIM.ConversationSource)
      SystemsRuntime.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

      case @retired_path do
        :admission ->
          SystemsRuntime.put_env(:salix_agent, :conversation_source_mod, RetiredDuringAdmission)
          assert :ok = SalixAgent.AgentActor.notify_conversation(f.worker, source)
          settle()

        :consumer ->
          assert :ok = SalixAgent.AgentActor.notify_conversation(f.worker, source)
          settle()

        :recovery ->
          assert {:ok, candidates} = SalixStore.ConversationLogRecovery.claim(8)
          candidate = Enum.find(candidates, &(&1.conversation_id == f.task))
          assert candidate

          key = Keys.ctl_group_conversation_meta(f.group, f.task)
          SalixStore.S3.Fake.blackhole({:fail, 503, :put, key})
          on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)
          assert {:ok, :pending} = SalixIM.ConversationSource.recover(candidate)

          assert {:ok, %{"status" => "active"}} =
                   Conversations.get_group_conversation_record(f.group, f.task)

          SalixStore.S3.Fake.clear_blackhole()
          assert SalixIM.ConversationSource.recover(candidate) in [:ok, {:ok, :pending}]
      end

      assert {:ok, %{"status" => "escalated"} = task} =
               Conversations.get_group_conversation_record(f.group, f.task)

      assert task["source_refs"]["triage_investigation"] == f.grant
      assert {:error, :not_found} = InternalSessionStore.read(f.worker, session)

      assert {:ok, %{"read_only" => true}} =
               SalixAgent.RetiredSessions.get_summary(worker, session)
    end
  end

  test "a provider-confirmed reply joins the exact Task once and enables ordinary Worker follow-up" do
    f = fixture!()
    source = read_source!(f)

    decision = %{
      "kind" => "reply",
      "text" => "The original source resolves the question.",
      "source_refs" => []
    }

    assert {:ok, result} = complete(f, source, decision)
    settle_receive({:slack_post, params})
    assert params["text"] == decision["text"]

    eventually(fn ->
      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      task["status"] == "ready_for_review"
    end)

    assert {:ok, %{"participants" => members}} =
             Conversations.list_group_conversation_participants(f.group, f.task)

    delegator = Enum.find(members, &(&1["role_label"] == "delegator"))
    assert delegator["notification_filter"]["messages"] == "all"

    context = fn ->
      Enum.filter(inputs(), fn {id, _, opts} ->
        id == f.router["agent_id"] and
          String.starts_with?(opts[:source_message_id] || "", "triage-participation:")
      end)
    end

    # The Router's context arrives with the Worker's delivery, which can
    # follow the Task's ready_for_review: wait for it, then let the system
    # go idle so a second delivery would show.
    eventually(fn -> context.() != [] end)
    settle()
    assert [{_, payload, opts}] = context.()
    assert opts[:no_wake] == true
    assert payload[:trusted_origin]["task_conversation_id"] == f.task
    assert payload[:trusted_origin]["ifc"]["integrity"] == "data"
    assert String.contains?(payload[:content], "Original question")
    assert String.contains?(payload[:content], decision["text"])

    SalixIM.TestSupport.Fleet.stop_all!()
    assert {:ok, replay} = complete(f, source, decision)
    assert replay["message_id"] == result["message_id"]
    assert map_size(Agent.get(Ports, & &1.posts)) == 1

    assert {:ok, followup} =
             ConversationServer.append_group_conversation_agent_message(
               f.group,
               f.task,
               f.worker,
               %{"content" => "Investigation of the follow-up is complete."}
             )

    eventually(fn ->
      Enum.any?(inputs(), fn {id, _, opts} ->
        id == f.router["agent_id"] and
          String.contains?(opts[:source_message_id] || "", followup["message_id"])
      end)
    end)

    settle_refute_receive({:slack_post, _}, 100)
  end

  test "a Triage Worker reads its Router memory on demand without acquiring writes or owner selection" do
    f = fixture!()
    path = "/memory/semantic/environments/staging.md"
    label = ["scope|T_TEST|C_TEST"]
    seed_memory!(f.router["agent_id"], path, "Known incident\nCheck the original log", label)
    seed_memory!(f.worker, path, "Worker's unrelated file", ["public"])

    assert {:ok, result} = api(f, "internal.triage.read_memory", %{"path" => path})
    assert result["exists"]
    assert result["content"] == "     1→Known incident\n     2→Check the original log\n"
    assert result["total_lines"] == 2
    assert result["__ifc__"] == %{"label" => label}

    assert {:ok, slice} =
             api(f, "internal.triage.read_memory", %{
               "path" => path,
               "start_line" => 2,
               "num_lines" => 1
             })

    assert slice["content"] == "     2→Check the original log\n"

    for params <- [
          %{"path" => "/memory/../../secret"},
          %{"path" => path, "agent_id" => f.worker},
          %{"path" => path, "content" => "Overwrite"}
        ] do
      assert {:error, _} = api(f, "internal.triage.read_memory", params)
    end

    assert {:error, _} =
             api(f, "internal.triage.write_memory", %{"path" => path, "content" => "Overwrite"})

    assert {:ok, "Known incident\nCheck the original log"} =
             SalixAgent.AgentWorkspace.read(f.router["agent_id"], path)

    assert {:error, _} =
             api(%{f | session: "another-session"}, "internal.triage.read_memory", %{
               "path" => path
             })

    assert {:error, _} =
             api(%{f | origin: %{}}, "internal.triage.read_memory", %{"path" => path})

    seed_memory!(f.router["agent_id"], path, "Unlabelled older note", nil)
    assert {:ok, private} = api(f, "internal.triage.read_memory", %{"path" => path})
    assert private["__ifc__"] == %{"label" => ["agent_private"]}

    assert {:ok, %{"exists" => false}} =
             api(f, "internal.triage.read_memory", %{"path" => "/memory/not-present.md"})

    {:ok, entry} = SalixAgent.AgentWorkspace.entry(f.router["agent_id"], path)
    :ok = SalixStore.S3.delete(Keys.blob(entry["ref"]["uuid"]))
    assert {:error, :not_found} = api(f, "internal.triage.read_memory", %{"path" => path})

    assert :ok =
             SalixIM.ProviderConnects.set_slack_triage_channel_enabled(
               f.router["tenant_id"],
               f.group,
               f.connect["connect_id"],
               "C_TEST",
               false
             )

    assert {:error, :triage_investigation_scope_denied} =
             api(f, "internal.triage.read_memory", %{"path" => "/memory/not-present.md"})
  end

  test "an ordinary Worker Task does not grant Router memory access" do
    f = fixture!(ordinary: true)
    path = "/memory/semantic/user.md"
    seed_memory!(f.router["agent_id"], path, "Router note", ["public"])
    assert {:error, _} = api(f, "internal.triage.read_memory", %{"path" => path})
  end

  test "the canonical command grants only this Worker and IFC separates public reply from private silence" do
    f = fixture!()
    {_, command, opts} = Enum.find(inputs(), fn {id, _, _} -> id == f.worker end)
    origin = command.trusted_origin
    assert origin["ifc"]["integrity"] == "command"
    assert origin["ifc"]["principal"] == "agent|" <> f.worker
    assert origin["ifc"]["label"] == ["task|" <> f.task]
    ctx = tool_ctx(f, command, opts)
    read = %{id: "read", name: "im_api.internal.triage.read_source", args: %{}}
    assert :ok = InvestigationAuthority.authorize_call(read, ctx)

    memory_read = %{
      read
      | name: "im_api.internal.triage.read_memory",
        args: %{"path" => "/memory/index.md"}
    }

    assert {:read, %{}} =
             SalixAgent.IFC.Destination.describe(memory_read.name, memory_read.args, ctx)

    assert :ok = InvestigationAuthority.authorize_call(memory_read, ctx)

    discovery = %{read | name: "mcp.list", args: %{"kind" => "tools"}}
    assert :ok = InvestigationAuthority.authorize_call(discovery, ctx)
    assert [{:execute, _}] = SalixAgent.IFC.Check.authorize([{:execute, discovery}], ctx)

    assert {:error, :triage_investigation_scope_denied} =
             InvestigationAuthority.authorize_call(%{read | name: "mcp.diagnostics.lookup"}, ctx)

    assert {:error, :triage_investigation_scope_denied} =
             InvestigationAuthority.authorize_call(read, %{ctx | session_id: "another-session"})

    assert {:error, :triage_investigation_scope_denied} =
             InvestigationAuthority.authorize_call(
               %{read | name: "im_api.slack.send_message"},
               ctx
             )

    assert {:error, :triage_investigation_scope_denied} =
             InvestigationAuthority.authorize_call(
               %{
                 read
                 | name: "im_api.internal.send_message",
                   args: %{"conversation_id" => Ids.new_conversation_id()}
               },
               ctx
             )

    source = read_source!(f)

    memory_path = "/memory/scoped/private-incident.md"

    seed_memory!(f.router["agent_id"], memory_path, "Private working evidence", [
      "task|" <> f.task
    ])

    assert {:ok, memory} = api(f, "internal.triage.read_memory", %{"path" => memory_path})

    private = %{
      role: "tool",
      id: "private-read",
      content: memory["content"],
      ifc: memory["__ifc__"]
    }

    public = %{
      role: "tool",
      id: "public-read",
      content: "Public channel evidence",
      ifc: source["__ifc__"]
    }

    wire =
      SalixAgent.IFC.Context.build(
        %{
          messages: [
            command
            |> Map.put(:id, "initial-command")
            |> Map.put(:source_message_id, opts[:source_message_id]),
            private,
            public,
            %{
              role: "tool",
              id: "web-public",
              content: "Public documentation",
              ifc: %{"label" => ["public"]}
            }
          ]
        },
        source_message_id: opts[:source_message_id],
        source_message_ids: [opts[:source_message_id]],
        trusted_origin: origin
      )

    ctx = Map.put(ctx, :ifc, wire)

    call = %{
      id: "result",
      name: "im_api.internal.triage.complete",
      args: %{
        "source_snapshot" => source["source_snapshot"],
        "decision" => %{"kind" => "reply", "text" => "Answer", "source_refs" => []}
      },
      ifc: %{"sources" => [SalixAgent.IFC.result_ref("public-read")]}
    }

    assert [{:execute, _}] = SalixAgent.IFC.Check.authorize([{:execute, call}], ctx)

    for {name, args} <- [
          {"web.search", %{"query" => "public product documentation"}},
          {"web.read_pages", %{"urls" => ["https://example.com/docs"]}}
        ] do
      research = %{call | name: name, args: args, ifc: %{"sources" => []}}
      assert :ok = InvestigationAuthority.authorize_call(research, ctx)
      assert [{:execute, _}] = SalixAgent.IFC.Check.authorize([{:execute, research}], ctx)

      private_research =
        put_in(research, [:ifc, "sources"], [SalixAgent.IFC.result_ref("private-read")])

      assert [{:blocked, _}] =
               SalixAgent.IFC.Check.authorize([{:execute, private_research}], ctx)
    end

    private_reply = put_in(call, [:ifc, "sources"], [SalixAgent.IFC.result_ref("private-read")])
    assert [{:blocked, _}] = SalixAgent.IFC.Check.authorize([{:execute, private_reply}], ctx)

    silence =
      put_in(private_reply, [:args, "decision"], %{
        "kind" => "silence",
        "reason" => "Private evidence makes an answer inappropriate",
        "source_refs" => []
      })

    assert [{:execute, _}] = SalixAgent.IFC.Check.authorize([{:execute, silence}], ctx)

    for kind <- ~w(silence reaction reply) do
      shared_write =
        silence
        |> put_in([:args, "decision", "kind"], kind)
        |> put_in([:args, "decision", "context_candidates"], [%{"value" => "Private evidence"}])

      assert [{:blocked, _}] = SalixAgent.IFC.Check.authorize([{:execute, shared_write}], ctx)

      public_write =
        put_in(shared_write, [:ifc, "sources"], [SalixAgent.IFC.result_ref("web-public")])

      assert [{:execute, _}] = SalixAgent.IFC.Check.authorize([{:execute, public_write}], ctx)
    end

    assert Agent.get(Ports, & &1.posts) == %{}
  end

  test "a help reply commits one agent-owned Schedule and keeps its Triage route" do
    f = fixture!()
    source = read_source!(f)

    decision = %{
      "kind" => "reply",
      "text" =>
        "The dispatch failed and recovery remains unverified. Please check the runtime log.",
      "source_refs" => [],
      "context_candidates" => [
        %{
          "kind" => "follow_up",
          "subject" => "Dispatch recovery",
          "value" =>
            "Check the thread for confirmed recovery or explicit cancellation before closing.",
          "confidence" => "explicit",
          "source_refs" => [hd(source["messages"])["source_ref"]],
          "follow_up_basis" => "agent_owned",
          "recheck_after_hours" => 1
        }
      ]
    }

    assert {:ok, result} = complete(f, source, decision)
    settle_receive({:slack_post, _})
    assert_completed(f)
    assert {:ok, replay} = complete(f, source, decision)
    assert replay["message_id"] == result["message_id"]

    assert [["active", payload, next_check_at]] =
             Repo.query!(
               "SELECT state, payload, next_check_at FROM triage_context_entries WHERE project_id = $1 AND kind = 'follow_up'",
               [f.project_id]
             ).rows

    assert payload["follow_up_basis"] == "agent_owned"
    assert {:ok, schedule} = SalixCluster.Schedules.get(payload["schedule_id"])
    assert schedule["receiver"] == "triage_follow_up"

    assert SalixCluster.Schedules.next_fire_ms(schedule) ==
             DateTime.to_unix(next_check_at, :millisecond)

    {:ok, original} = SalixIM.Triage.Investigation.original(f.grant)

    {:ok, scope} =
      SalixStore.SlackTriageThreadSubscriptions.product_scope(
        original.payload["target"],
        original.payload["product_identity"]
      )

    assert {:ok, :active} = SalixStore.SlackTriageThreadSubscriptions.status(scope)

    assert {:ok, :triage, _} =
             SalixIM.Provider.Slack.ThreadRouteOwner.lookup_claim(Map.delete(scope, "agent_id"))

    settle_refute_receive({:slack_post, _}, 100)
  end

  test "Worker silence records attributed facts and resolves an existing follow-up once" do
    f = fixture!(skip_task_creation: true)
    {:ok, original} = SalixIM.Triage.Investigation.original(f.grant)
    target = original.payload["target"]

    source_ref =
      "slack://#{target["workspace_id"]}/#{target["channel_id"]}/#{target["thread_ts"]}/#{target["thread_ts"]}"

    follow_up = %{
      "kind" => "follow_up",
      "subject" => "Account access",
      "value" => "Confirm access works",
      "confidence" => "explicit",
      "source_refs" => [source_ref],
      "recheck_after_hours" => 1,
      "follow_up_basis" => "agent_owned"
    }

    seeded = Map.put(original.payload, "context_candidates", [follow_up])

    assert :ok =
             SalixStore.TriageProductRuntime.settle_investigation_context(
               seeded,
               "seed-" <> f.obligation,
               %{outcome: :applied}
             )

    [[entry_id]] =
      Repo.query!("SELECT entry_id FROM triage_context_entries WHERE project_id = $1", [
        f.project_id
      ]).rows

    context_ref = "triage-context://" <> entry_id

    sources = [
      %{
        "kind" => "retained_follow_up",
        "text" => "Account access: Confirm access works",
        "source_ref" => context_ref
      }
    ]

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = jsonb_set(payload, '{context_sources}', $2::jsonb) WHERE obligation_id = $1",
      [f.obligation, sources]
    )

    f = create_fixture_task!(f, [])
    assert {:ok, context} = api(f, "internal.triage.read_context", %{})
    assert context["entries"] == sources
    assert context["__ifc__"] == %{"label" => ["group|" <> f.group]}
    source = read_source!(f)

    candidates = [
      %{
        "kind" => "project_fact",
        "subject" => "Preferred notifications",
        "value" => "Use concise messages",
        "knowledge_scope" => "person",
        "confidence" => "explicit",
        "source_refs" => [source_ref]
      },
      %{
        "kind" => "follow_up_resolution",
        "subject" => "Account access",
        "value" => "Access confirmed",
        "confidence" => "explicit",
        "resolution_basis" => "source_confirmation",
        "source_refs" => [context_ref, source_ref]
      }
    ]

    decision = %{
      "kind" => "silence",
      "reason" => "People handled it",
      "source_refs" => [],
      "context_candidates" => candidates
    }

    invalid =
      put_in(decision, ["context_candidates", Access.at(0), "source_refs"], [
        "slack://foreign/channel/thread/message"
      ])

    assert {:error, :invalid_triage_context_candidates} = complete(f, source, invalid)

    forged_owner =
      put_in(decision, ["context_candidates", Access.at(0), "scope_owner"], %{
        "kind" => "person",
        "id" => "someone-else"
      })

    assert {:error, :invalid_triage_context_candidates} = complete(f, source, forged_owner)
    assert {:ok, _} = complete(f, source, decision)
    assert_completed(f)

    assert [["resolved"]] =
             Repo.query!("SELECT state FROM triage_context_entries WHERE entry_id = $1", [
               entry_id
             ]).rows

    [[fact]] =
      Repo.query!(
        "SELECT payload FROM triage_context_entries WHERE project_id = $1 AND kind = 'project_fact'",
        [f.project_id]
      ).rows

    assert fact["scope_owner"] == %{"kind" => "person", "id" => "slack-user://T_TEST/U_HUMAN"}

    assert [%{"actor_id" => "U_HUMAN", "source_ref" => ^source_ref}] =
             Enum.map(fact["source_attribution"], &Map.take(&1, ~w(actor_id source_ref)))

    {:ok, messages} = Conversations.list_group_conversation_messages(f.group, f.task, limit: 30)
    result = Enum.find_value(messages, &get_in(&1, ["metadata", "triage_investigation_result"]))

    [[operation]] =
      Repo.query!(
        "SELECT payload ->> 'operation_ref' FROM triage_product_effect_attempts WHERE payload ->> 'kind' = 'investigation_context' AND run_id = $1 AND payload ->> 'operation_ref' != $2",
        [original.payload["run_id"], "seed-" <> f.obligation]
      ).rows

    before =
      Repo.query!(
        "SELECT entry_id, state, updated_at FROM triage_context_entries WHERE project_id = $1 ORDER BY entry_id",
        [f.project_id]
      ).rows

    assert :ok =
             SalixStore.TriageProductRuntime.settle_investigation_context(
               result["payload"],
               operation,
               %{outcome: :applied}
             )

    assert Repo.query!(
             "SELECT entry_id, state, updated_at FROM triage_context_entries WHERE project_id = $1 ORDER BY entry_id",
             [f.project_id]
           ).rows == before

    settle_refute_receive({:slack_post, _}, 50)
  end

  test "owner recovery replays an accepted decision even when no completion Message was appended" do
    f = fixture!()
    source = read_source!(f)
    segment = Keys.ctl_group_conversation_message_segment(f.group, f.task, "000000000000000001")
    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, segment})

    assert {:error, _} =
             complete(f, source, %{
               "kind" => "silence",
               "reason" => "No useful addition",
               "source_refs" => []
             })

    {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
    assert task["metadata"]["triage_investigation_state"]["state"] == "pending"
    {:ok, before} = Conversations.list_group_conversation_messages(f.group, f.task, limit: 30)
    refute Enum.any?(before, &get_in(&1, ["metadata", "triage_investigation_result"]))
    SalixIM.TestSupport.Fleet.stop_all!()
    :ok = SalixStore.S3.Fake.clear_blackhole()
    {:ok, _} = SalixIM.ConversationPlacement.ensure_started(f.group, f.task)
    assert_completed(f)

    {:ok, after_recovery} =
      Conversations.list_group_conversation_messages(f.group, f.task, limit: 30)

    assert 1 ==
             Enum.count(after_recovery, &get_in(&1, ["metadata", "triage_investigation_result"]))

    assert Agent.get(Ports, & &1.posts) == %{}
  end

  test "confirmed reply recovery retries local continuation without publishing a second reply or skipping later messages" do
    f = fixture!()
    source = read_source!(f)
    Agent.update(Ports, &Map.put(&1, :pause_context, true))

    assert {:ok, _} =
             complete(f, source, %{
               "kind" => "reply",
               "text" => "Source-backed answer",
               "source_refs" => []
             })

    settle_receive({:slack_post, _})
    settle_receive({:context_paused, io})
    stop_result_owner(f)
    Agent.update(Ports, &(&1 |> Map.put(:pause_context, false) |> Map.put(:context_failures, 1)))
    SystemsRuntime.Proc.send(io, :release)
    # This newer Task result must remain after the fixed completion cursor.
    {:ok, followup} =
      ConversationServer.append_group_conversation_agent_message(f.group, f.task, f.worker, %{
        "content" => "A subsequent result"
      })

    restart_result_owner(f)
    assert_completed(f)

    eventually(fn ->
      Enum.any?(inputs(), fn {id, _, opts} ->
        id == f.router["agent_id"] and
          String.contains?(opts[:source_message_id] || "", followup["message_id"])
      end)
    end)

    assert map_size(Agent.get(Ports, & &1.posts)) == 1
    settle_refute_receive({:slack_post, _}, 100)
  end

  test "ordinary intake creates a Worker on current sources but rejects a later stale reply" do
    f = fixture!(skip_task_creation: true, ordinary_assignment: true)
    add_source_message()
    Agent.update(Ports, &Map.put(&1, :intake_fixture, f))
    {:ok, original} = SalixIM.Triage.Investigation.original(f.grant)
    claim = Map.put(original, :claim_token, ULID.generate())

    assert {:ok, [%{"status" => "created", "conversation_id" => task}]} =
             SalixIM.Triage.DelegationEffect.apply(claim, delegation_port: CanonicalTasks)

    f = Agent.get(Ports, & &1.intake_fixture)
    assert task == f.task
    source = read_source!(f)
    assert Enum.any?(source["messages"], &(&1["text"] == "A human follow-up"))

    Agent.update(Ports, &Map.put(&1, :pause_reply_lookup, true))

    assert {:ok, _} =
             complete(f, source, %{
               "kind" => "reply",
               "text" => "Answer before the next message",
               "source_refs" => []
             })

    settle_receive({:reply_lookup_paused, io})
    add_source_message()
    Agent.update(Ports, &Map.put(&1, :pause_reply_lookup, false))
    SystemsRuntime.Proc.send(io, :release)

    eventually(fn ->
      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      get_in(task, ["metadata", "triage_investigation_state", "state"]) == "retry"
    end)

    settle_refute_receive({:slack_post, _}, 100)
    assert Agent.get(Ports, & &1.posts) == %{}
  end

  test "accepted Worker command survives consumer restart without duplicate work" do
    f = fixture!(pause_accepted: true)
    settle_receive({:agent_accepted, io, source, {:ok, :created}})
    SystemsRuntime.Proc.exit(io, :kill)
    Agent.update(Ports, &Map.delete(&1, :pause_accepted_agent))
    notify_worker(f)
    eventually(fn -> source_admitted?(f) end)
    {:ok, session} = SessionData.read(f.worker, f.session)

    assert Enum.count(
             session.input_queue,
             &(get_in(&1, ["payload", "source_message_id"]) == source)
           ) == 1

    assert MapSet.member?(session.input_dedupe, source)
    source = read_source!(f)

    assert {:ok, _} =
             complete(f, source, %{
               "kind" => "silence",
               "reason" => "Already covered",
               "source_refs" => []
             })

    assert_completed(f)
  end

  defp notify_worker(f) do
    {:ok, %{"participants" => members}} =
      Conversations.list_group_conversation_participants(f.group, f.task)

    member = Enum.find(members, &(&1["agent_id"] == f.worker))

    SalixAgent.AgentActor.notify_conversation(f.worker, %{
      group_id: f.group,
      conversation_id: f.task,
      participant_id: member["participant_id"]
    })
  end

  defp source_admitted?(f) do
    case InternalSessionStore.read(f.worker, f.session) do
      {:ok, session} -> map_size(SalixAgent.InternalSession.conversation_sources(session)) > 0
      _ -> false
    end
  end

  defp assert_completed(f) do
    eventually(fn ->
      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      task["status"] == "ready_for_review"
    end)
  end

  defp result_participant(f) do
    {:ok, %{"participants" => members}} =
      Conversations.list_group_conversation_participants(f.group, f.task)

    Enum.find(members, &(&1["role_label"] == "triage_result"))
  end

  defp stop_result_owner(f) do
    {:ok, owner} =
      SalixIM.ConversationFleet.ensure_participant_started(
        f.group,
        f.task,
        result_participant(f)["participant_id"]
      )

    monitor = SystemsRuntime.Proc.monitor(owner)
    SystemsRuntime.Proc.exit(owner, :kill)
    settle_receive({:DOWN, ^monitor, :process, ^owner, _})
  end

  defp restart_result_owner(f) do
    id = result_participant(f)["participant_id"]
    {:ok, _} = SalixIM.ConversationFleet.ensure_participant_started(f.group, f.task, id)
    SalixIM.ConversationParticipantActor.wake(f.group, f.task, id)
  end

  defp add_source_message do
    Agent.update(Ports, fn state ->
      seconds = 1_789_113_602 + length(state.page.messages)
      micros = seconds * 1_000_000 + 1

      row =
        hd(state.page.messages)
        |> Map.merge(%{
          "message_ts" => "#{seconds}.000001",
          "message_ts_us" => micros,
          "version" => micros * 2,
          "text" => "A human follow-up"
        })

      put_in(state, [:page, :messages], state.page.messages ++ [row])
    end)
  end

  defp fixture!(opts \\ []) do
    router =
      SalixAgent.TestSupport.create_control_agent!(SalixAgent.TestSupport.new_agent_id(), %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    group = router["group_id"]

    SalixAgent.TestSupport.create_control_group!(group, %{
      "router_agent_id" => router["agent_id"],
      "ifc" => %{"mode" => "enforce"}
    })

    {:ok, session} = RuntimeIds.persisted_router_session_id(router)
    {:ok, _} = InternalSessionStore.prepare_create(router["agent_id"], session)

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(router["tenant_id"], group, %{
        "role" => "worker"
      })

    connect = %{
      "tenant_id" => router["tenant_id"],
      "group_id" => group,
      "provider" => "slack",
      "connect_id" => Ids.new_connect_id(),
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_TEST",
      "approved_channel_id" => "C_TEST",
      "inbound_agent_id" => router["agent_id"],
      "bot_token" => "xoxb-synthetic-never-used",
      "bot_user_id" => "U_BOT",
      "bot_id" => "B_BOT",
      "app_id" => "A_BOT",
      "oauth_completed_at" => 1,
      "triage_enabled" => true,
      "triage_provisioned_at" => 1
    }

    {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group, connect["connect_id"]), connect)

    {:ok, _} =
      SalixStore.SlackTriageChannels.provision(%{
        "tenant_id" => router["tenant_id"],
        "group_id" => group,
        "connect_id" => connect["connect_id"],
        "installation_generation" => connect["connect_generation"],
        "workspace_id" => "T_TEST",
        "channel_id" => "C_TEST",
        "channel_name" => "test"
      })

    SalixStore.IFC.observe_scope(router["tenant_id"], group, connect["connect_id"], "C_TEST", %{
      kind: "public"
    })

    {:ok, authority} =
      SalixIM.ProviderConnects.get_slack_triage_authority(
        router["tenant_id"],
        group,
        connect["connect_id"],
        "C_TEST"
      )

    target =
      Map.take(authority, ~w(connect_id connect_generation workspace_id))
      |> Map.merge(%{"channel_id" => "C_TEST", "thread_ts" => "1789113600.000001"})

    route =
      Map.merge(
        Map.take(authority, ~w(tenant_id group_id connect_id connect_generation workspace_id)),
        %{"channel_id" => "C_TEST", "root_thread_ts" => target["thread_ts"]}
      )

    {:ok, :triage} =
      SalixIM.Provider.Slack.ThreadRouteOwner.claim_triage(route, String.duplicate("a", 64))

    message = %{
      "message_ts" => target["thread_ts"],
      "message_ts_us" => 1_789_113_600_000_001,
      "version" => 3_578_227_200_000_002,
      "actor_kind" => "user",
      "actor_id" => "U_HUMAN",
      "text" => "Original question"
    }

    Agent.update(Ports, &%{&1 | page: %{complete?: true, messages: [message], reactions: []}})

    communication =
      cond do
        opts[:ordinary_assignment] ->
          SalixIM.Triage.WorkerSelection.pending_communication()

        opts[:immediate_reply] ->
          %{"kind" => "reply", "text" => "Useful immediate correction", "source_refs" => []}

        true ->
          %{"kind" => "silence", "reason" => "investigate"}
      end

    payload = %{
      "target" => target,
      "source_messages" => [message],
      "source_authority" => [
        %{"message_ts" => message["message_ts"], "observed_version" => message["version"]}
      ],
      "target_cutoff" => %{"event_message_timestamps" => [message["message_ts"]]},
      "communication" => communication,
      "delegations" => [
        %{
          "task" => "Inspect source",
          "source_refs" => ["source-A"],
          "worker_ref" => "comma-agent://" <> worker["agent_id"]
        }
      ]
    }

    payload =
      if opts[:ordinary_assignment],
        do: Map.put(payload, "ordinary_worker_assignment", true),
        else: payload

    {namespace, obligation, project_id} = seed_original!(router, payload)

    grant = %{
      "namespace_key" => TriageKeys.namespace_key(namespace),
      "obligation_id" => obligation,
      "index" => 0,
      "worker_agent_id" => worker["agent_id"]
    }

    if opts[:immediate_reply] do
      {:ok, original} = SalixIM.Triage.Investigation.original(grant)
      claim = Map.put(original, :claim_token, ULID.generate())
      assert {:ok, %{outcome: :applied}} = SalixIM.Triage.SlackEffectAdapter.apply(claim)
      if opts[:pause_task_context], do: Agent.update(Ports, &Map.put(&1, :pause_context, true))
    end

    if opts[:pause_accepted],
      do: Agent.update(Ports, &Map.put(&1, :pause_accepted_agent, worker["agent_id"]))

    if opts[:unavailable_worker],
      do: Agent.update(Ports, &Map.put(&1, :unavailable_agent, worker["agent_id"]))

    if opts[:pause_unavailable], do: Agent.update(Ports, &Map.put(&1, :pause_unavailable, true))

    f = %{
      router: router,
      worker: worker["agent_id"],
      group: group,
      connect: connect,
      authority: authority,
      obligation: obligation,
      project_id: project_id,
      grant: grant
    }

    if opts[:skip_task_creation], do: f, else: create_fixture_task!(f, opts)
  end

  def create_fixture_task!(f, opts) do
    %{router: router, worker: worker, group: group, obligation: obligation, grant: grant} = f

    attrs = %{
      "client_request_id" => "triage-delegation:#{obligation}:0",
      "title" => "Inspect source",
      "content" => "Inspect source",
      "source_refs" => if(opts[:ordinary], do: %{}, else: %{"triage_investigation" => grant})
    }

    {:ok, task} =
      ConversationServer.reserve_task_conversation_id(
        group,
        router["agent_id"],
        worker,
        attrs
      )

    {:ok, _} =
      TaskConversationInput.create_with_id(
        group,
        task,
        router["agent_id"],
        worker,
        attrs
        |> Map.put("schedule", %{"schedule_id" => nil, "command" => attrs["content"]})
        |> Map.put("initial_message_attrs", %{
          "actor_type" => "agent",
          "agent_id" => router["agent_id"],
          "content" => attrs["content"],
          "client_request_id" => "delegate-task-" <> task
        })
      )

    f = Map.put(f, :task, task)

    if opts[:pause_task_context], do: f, else: await_worker(f)
  end

  defp await_worker(f) do
    eventually(fn -> Enum.any?(inputs(), fn {id, _, _} -> id == f.worker end) end)
    {_, command, _} = Enum.find(inputs(), fn {id, _, _} -> id == f.worker end)
    Map.merge(f, %{session: command.session_id, origin: command.trusted_origin})
  end

  defp inputs, do: Agent.get(Ports, & &1.inputs)

  defp tool_ctx(f, command, opts),
    do: %{
      tenant_id: f.router["tenant_id"],
      group_id: f.group,
      agent_id: f.worker,
      session_id: f.session,
      ifc_mode: :enforce,
      source_message_ids: [opts[:source_message_id]],
      trusted_origin: command.trusted_origin
    }

  defp api(f, name, params) do
    SalixIM.Provider.call_api(f.worker, "internal", name, %{
      "connect_id" => "internal",
      "params" => params,
      "tool_context" => %{"session_id" => f.session, "trusted_origin" => f.origin}
    })
  end

  defp seed_memory!(agent, path, content, label) do
    {:ok, event} = SalixAgent.AgentWorkspace.prepare_write(agent, path, content)
    event = if label, do: Map.put(event, "ifc_label", label), else: event

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent,
               "memory-fixture-#{SystemsRuntime.Proc.unique_integer([:positive])}",
               %{},
               [event]
             )
  end

  defp read_source!(f) do
    assert {:ok, source} = api(f, "internal.triage.read_source", %{})
    source
  end

  defp complete(f, source, decision),
    do:
      api(f, "internal.triage.complete", %{
        "source_snapshot" => source["source_snapshot"],
        "decision" => decision
      })

  # Worker input recovers through the delivery lease, the retry backoff and the
  # Participant drain timer; the clock settles through that chain.
  defp eventually(fun), do: SystemsClock.settle(eager: true, until: fn -> fun.() end)

  defp seed_original!(router, payload_overrides) do
    run_id = "handoff-read-" <> SalixStore.ULID.generate()
    namespace = "handoff-boundary"
    namespace_key = TriageKeys.namespace_key(namespace)
    obligation = "triage-product-" <> Crypto.hex(run_id)
    project_id = "project-" <> run_id

    Repo.query!(
      "INSERT INTO triage_runs (record_key, namespace_key, run_id, body) VALUES ($1,$2,$3,$4)",
      [
        "handoff-run://#{run_id}",
        namespace_key,
        run_id,
        %{
          "schema" => "comma.triage-run.v1",
          "run_id" => run_id,
          "authoritative" => true,
          "created_at" => 1,
          "status" => "evaluated"
        }
      ]
    )

    Repo.query!(
      """
      INSERT INTO triage_product_obligations (namespace_key, run_id, obligation_id, payload, state)
      VALUES ($1,$2,$3,$4,'applied')
      """,
      [
        namespace_key,
        run_id,
        obligation,
        Map.merge(
          %{
            "schema" => "comma.triage-product-obligation.v1",
            "obligation_id" => obligation,
            "namespace" => namespace,
            "fence_key" => "handoff-fence://#{run_id}",
            "run_id" => run_id,
            "target" => %{},
            "communication" => %{"kind" => "silence", "reason" => "investigation"},
            "context_candidates" => [],
            "target_cutoff" => %{},
            "settled_at" => 1,
            "product_identity" => %{
              "project_id" => project_id,
              "project_salix_group_id" => router["group_id"],
              "agent_id" => "product-router",
              "salix_agent_id" => router["agent_id"]
            },
            "delegations" => [
              %{"task" => "Inspect original source", "source_refs" => ["source-A"]}
            ]
          },
          payload_overrides
        )
      ]
    )

    {namespace, obligation, project_id}
  end
end
