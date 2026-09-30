defmodule SalixIM.TriageInvestigationRuntimeTest do
  use ExUnit.Case, async: false
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
          send(pid, {:context_paused, self()})

          receive do
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
          send(Agent.get(__MODULE__, & &1.pid), {:agent_unavailable, self()})

          receive do
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
        send(pid, {:agent_accepted, self(), opts[:source_message_id], result})

        receive do
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
        send(state.pid, {:reply_lookup_paused, self()})

        receive do
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
          send(Agent.get(__MODULE__, & &1.pid), {:slack_rejected, reason})
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
        send(state.pid, {:slack_post, params})
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
            send(state.pid, {:reaction_read, conn.query_params})

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

            send(pid, {:reaction_added, self(), params})

            if pause?,
              do:
                (receive do
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
        old = Application.fetch_env(app, key)
        Application.put_env(app, key, value)
        {app, key, old}
      end

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, old} <- previous do
        case old do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end)

    start_supervised!(SalixStore.S3.Fake)
    test_pid = self()

    start_supervised!(%{
      id: :ports,
      start:
        {Agent, :start_link,
         [fn -> %{pid: test_pid, posts: %{}, inputs: [], page: nil} end, [name: Ports]]}
    })

    :ok
  end

  test "silence settles through the actual Participant queue with no Router or Slack delivery" do
    f = fixture!()
    source = read_source!(f)

    assert {:ok, result} =
             complete(f, source, %{
               "kind" => "silence",
               "reason" => "Already covered",
               "source_refs" => []
             })

    assert result["delivery_status"] == "pending"

    eventually(fn ->
      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      task["status"] == "ready_for_review"
    end)

    assert Agent.get(Ports, & &1.posts) == %{}
    refute Enum.any?(inputs(), fn {id, _, _} -> id == f.router["agent_id"] end)

    assert {:ok, %{"participants" => members}} =
             Conversations.list_group_conversation_participants(f.group, f.task)

    assert Enum.find(members, &(&1["role_label"] == "delegator"))["notification_filter"][
             "messages"
           ] == "none"
  end

  test "silence preserves unavailable evidence as a private result, not a useful-context claim" do
    Agent.update(Ports, &Map.put(&1, :run_worker, true))
    Application.put_env(:salix_agent, :llm, CapturedWorker)
    f = fixture!()

    eventually(fn ->
      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      task["status"] == "ready_for_review"
    end)

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(f.group, f.task, limit: 20)

    completion = Enum.find(messages, &get_in(&1, ["metadata", "triage_investigation_result"]))

    assert get_in(completion, [
             "metadata",
             "triage_investigation_result",
             "payload",
             "communication",
             "reason_code"
           ]) == "insufficient_evidence"

    assert Agent.get(Ports, & &1.posts) == %{}
    refute Enum.any?(inputs(), fn {id, _, _} -> id == f.router["agent_id"] end)
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
    assert_receive {:slack_post, params}, 5_000
    assert params["text"] == decision["text"]

    eventually(fn ->
      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      task["status"] == "ready_for_review"
    end)

    assert {:ok, %{"participants" => members}} =
             Conversations.list_group_conversation_participants(f.group, f.task)

    delegator = Enum.find(members, &(&1["role_label"] == "delegator"))
    assert delegator["notification_filter"]["messages"] == "all"

    context =
      Enum.filter(inputs(), fn {id, _, opts} ->
        id == f.router["agent_id"] and
          String.starts_with?(opts[:source_message_id] || "", "triage-participation:")
      end)

    assert [{_, payload, opts}] = context
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

    refute_receive {:slack_post, _}, 100
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
    assert_receive {:slack_post, _}, 5_000
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

    refute_receive {:slack_post, _}, 100
  end

  test "scheduled Worker completion updates the existing follow-up despite rewritten wording" do
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

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = payload || $2::jsonb WHERE obligation_id = $1",
      [
        f.obligation,
        %{"recheck_event_ids" => ["recheck:worker"], "recheck_context_refs" => [context_ref]}
      ]
    )

    {:ok, [before]} = SalixStore.TriageProductRuntime.list_context(f.project_id)
    f = create_fixture_task!(f, [])
    assert {:ok, context} = api(f, "internal.triage.read_context", %{})
    assert context["entries"] == sources
    assert context["__ifc__"] == %{"label" => ["group|" <> f.group]}
    source = read_source!(f)

    decision = %{
      "kind" => "silence",
      "reason_code" => "no_useful_addition",
      "reason" => "Waiting for the requested verification.",
      "source_refs" => [],
      "context_candidates" => [
        follow_up
        |> Map.put("subject", "Access verification pending")
        |> Map.put("value", "The account is enabled; verify the next login")
        |> Map.put("recheck_after_hours", 24)
        |> Map.put("source_refs", [hd(source["messages"])["source_ref"]])
      ]
    }

    assert {:ok, result} = complete(f, source, decision)
    assert_completed(f)
    assert {:ok, replay} = complete(f, source, decision)
    assert replay["message_id"] == result["message_id"]
    assert {:ok, [after_entry]} = SalixStore.TriageProductRuntime.list_context(f.project_id)
    assert after_entry.entry_id == entry_id
    assert after_entry.payload["subject"] == "Access verification pending"
    assert after_entry.payload["value"] == "The account is enabled; verify the next login"
    assert after_entry.payload["schedule_id"] == before.payload["schedule_id"]
    assert after_entry.payload["recheck_after_hours"] == 1
    assert {:ok, _} = SalixCluster.Schedules.get(before.payload["schedule_id"])
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

    refute_receive {:slack_post, _}, 50
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

  for recovery <- [:owner_append, :participant_verify], source_available? <- [true, false] do
    @tag :stale_silence_recovery
    @tag source_unavailable: not source_available?
    test "#{recovery} rejects obsolete silence context (source available: #{source_available?})" do
      f = fixture!()
      source = read_source!(f)

      decision = %{
        "kind" => "silence",
        "reason" => "Already covered",
        "source_refs" => [],
        "context_candidates" => [
          %{
            "kind" => "project_fact",
            "subject" => "Current status",
            "value" => "Obsolete status must not be retained",
            "confidence" => "explicit",
            "source_refs" => [hd(source["messages"])["source_ref"]]
          }
        ]
      }

      case unquote(recovery) do
        :owner_append ->
          segment =
            Keys.ctl_group_conversation_message_segment(f.group, f.task, "000000000000000001")

          :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :put, segment})
          assert {:error, _} = complete(f, source, decision)
          {:ok, pending} = Conversations.get_group_conversation(f.group, f.task)
          assert get_in(pending, ["metadata", "triage_investigation_state", "state"]) == "pending"
          SalixIM.TestSupport.Fleet.stop_all!()
          add_source_message()
          Agent.update(Ports, &Map.put(&1, :source_unavailable, not unquote(source_available?)))
          :ok = SalixStore.S3.Fake.clear_blackhole()
          {:ok, _} = SalixIM.ConversationPlacement.ensure_started(f.group, f.task)

        :participant_verify ->
          parent = self()

          lock =
            Task.async(fn ->
              Repo.transaction(fn ->
                Repo.query!(
                  "SELECT 1 FROM triage_product_obligations WHERE obligation_id = $1 FOR UPDATE",
                  [f.obligation]
                )

                send(parent, :context_commit_locked)

                receive do
                  :release -> :ok
                after
                  10_000 -> Repo.rollback(:test_lock_not_released)
                end
              end)
            end)

          assert_receive :context_commit_locked, 5_000
          assert {:ok, _} = complete(f, source, decision)

          eventually(fn ->
            [[waiting]] =
              Repo.query!(
                "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid != pg_backend_pid() AND wait_event_type = 'Lock' AND query LIKE '%triage_product_obligations%'"
              ).rows

            waiting > 0
          end)

          stop_result_owner(f)
          add_source_message()
          Agent.update(Ports, &Map.put(&1, :source_unavailable, not unquote(source_available?)))
          send(lock.pid, :release)
          assert {:ok, :ok} = Task.await(lock)
          restart_result_owner(f)
      end

      expected = if unquote(source_available?), do: "retry", else: "failed"

      eventually(fn ->
        {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
        get_in(task, ["metadata", "triage_investigation_state", "state"]) == expected
      end)

      assert [[0]] =
               Repo.query!("SELECT count(*) FROM triage_context_entries WHERE project_id = $1", [
                 f.project_id
               ]).rows

      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      assert get_in(task, ["metadata", "triage_investigation_state", "state"]) == expected
      assert task["task_worker_agent_id"] == f.worker
      assert Agent.get(Ports, & &1.posts) == %{}
      refute_receive {:slack_post, _}, 50
    end
  end

  test "Worker reactions use the frozen workspace emoji catalog" do
    f = fixture!(skip_task_creation: true)

    {:ok, expression} =
      SalixIM.Triage.ExpressionContext.build(
        "social",
        {:ok, %{"party_parrot" => "provider-owned-url"}}
      )

    Repo.query!(
      "UPDATE triage_product_obligations SET payload = jsonb_set(payload, '{expression_context}', $2::jsonb) WHERE obligation_id = $1",
      [f.obligation, expression]
    )

    f = create_fixture_task!(f, [])
    source = read_source!(f)
    assert "party_parrot" in source["expression_context"]["allowed_emojis"]

    decision = %{
      "kind" => "reaction",
      "emoji" => "party_parrot",
      "source_refs" => [hd(source["messages"])["source_ref"]]
    }

    assert {:error, :invalid_triage_completion} =
             complete(f, source, %{decision | "emoji" => "invented_emoji"})

    assert {:ok, _} = complete(f, source, decision)
    assert_receive {:reaction_added, _, %{"name" => "party_parrot"}}, 5_000
    assert_completed(f)
    refute_receive {:slack_post, _}, 50
  end

  test "the installed bot identity cannot become a personal knowledge owner" do
    f = fixture!()

    Agent.update(Ports, fn state ->
      update_in(state, [:page, :messages], fn messages ->
        Enum.map(messages, &Map.put(&1, "actor_id", "U_BOT"))
      end)
    end)

    source = read_source!(f)
    assert hd(source["messages"])["actor_kind"] == "agent"

    assert {:ok, _} =
             complete(f, source, %{
               "kind" => "silence",
               "reason" => "No public addition",
               "source_refs" => [],
               "context_candidates" => [
                 %{
                   "kind" => "project_fact",
                   "subject" => "Tone",
                   "value" => "Brief replies",
                   "knowledge_scope" => "person",
                   "confidence" => "explicit",
                   "source_refs" => [hd(source["messages"])["source_ref"]]
                 }
               ]
             })

    assert_completed(f)

    [[payload]] =
      Repo.query!("SELECT payload FROM triage_context_entries WHERE project_id = $1", [
        f.project_id
      ]).rows

    assert payload["knowledge_scope"] == "unattributed"
    refute payload["scope_owner"]
  end

  test "reaction confirmation is recovered after process loss and newer source messages" do
    f = fixture!()
    source = read_source!(f)
    Agent.update(Ports, &Map.put(&1, :pause_reaction, true))

    decision = %{
      "kind" => "reaction",
      "emoji" => "tada",
      "source_refs" => [hd(source["messages"])["source_ref"]]
    }

    assert {:ok, _} = complete(f, source, decision)
    assert_receive {:reaction_added, http, params}, 5_000
    assert params["timestamp"] == "1789113600.000001"
    stop_result_owner(f)
    add_source_message()
    Agent.update(Ports, &Map.put(&1, :pause_reaction, false))
    send(http, :release)
    restart_result_owner(f)
    assert_completed(f)
    refute_receive {:reaction_added, _, _}, 100

    assert {:ok, %{"participants" => members}} =
             Conversations.list_group_conversation_participants(f.group, f.task)

    assert Enum.find(members, &(&1["role_label"] == "delegator"))["notification_filter"][
             "messages"
           ] == "none"

    assert_receive {:reaction_read, %{"full" => "true"}}
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

    assert_receive {:slack_post, _}, 5_000
    assert_receive {:context_paused, io}, 5_000
    stop_result_owner(f)
    Agent.update(Ports, &(&1 |> Map.put(:pause_context, false) |> Map.put(:context_failures, 1)))
    send(io, :release)
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
    refute_receive {:slack_post, _}, 100
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

    assert_receive {:reply_lookup_paused, io}, 5_000
    add_source_message()
    Agent.update(Ports, &Map.put(&1, :pause_reply_lookup, false))
    send(io, :release)

    eventually(fn ->
      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      get_in(task, ["metadata", "triage_investigation_state", "state"]) == "retry"
    end)

    refute_receive {:slack_post, _}, 100
    assert Agent.get(Ports, & &1.posts) == %{}
  end

  test "a source change before Task creation preserves human continuation without promising a Task" do
    f = fixture!(immediate_reply: true, skip_task_creation: true)
    assert_receive {:slack_post, _}, 5_000
    add_source_message()

    {:ok, original} = SalixIM.Triage.Investigation.original(f.grant)
    claim = Map.put(original, :claim_token, ULID.generate())

    assert {:ok, [%{"status" => "suppressed_stale"}]} =
             SalixIM.Triage.DelegationEffect.apply(claim, delegation_port: Ports)

    assert {:ok, %{"data" => [], "has_more" => false}} =
             Conversations.list_group_conversations(f.group, kind: "agent_task", limit: 10)

    target = original.payload["target"]
    identity = original.payload["product_identity"]
    {:ok, scope} = SalixStore.SlackTriageThreadSubscriptions.product_scope(target, identity)
    route = Map.delete(scope, "agent_id")
    assert {:ok, :active} = SalixStore.SlackTriageThreadSubscriptions.status(scope)

    assert :admit =
             SalixIM.Provider.Slack.TriageThreadSubscription.continuation(
               f.authority,
               route
             )

    assert {_, context, context_opts} =
             Enum.find(inputs(), fn {id, _, opts} ->
               id == f.router["agent_id"] and
                 opts[:source_message_id] == "triage-participation:" <> f.obligation
             end)

    assert context_opts[:no_wake]
    assert context[:trusted_origin]["task_conversation_id"] == nil
    assert String.contains?(context.content, "triage-delegation:" <> f.obligation)

    refute Enum.any?(inputs(), fn {id, _, _} -> id == f.worker end)
    refute_receive {:slack_post, _}, 100
  end

  test "an immediate reply retains a pending investigation and later silence joins its existing Task" do
    f = fixture!(immediate_reply: true, pause_task_context: true)
    assert_receive {:slack_post, _}, 5_000
    assert_receive {:context_paused, io}, 5_000

    first =
      Enum.find(inputs(), fn {id, payload, _} ->
        id == f.router["agent_id"] and payload[:trusted_origin]["task_conversation_id"] == nil
      end)

    assert {_, first_payload, _} = first
    assert String.contains?(first_payload.content, "triage-delegation:" <> f.obligation)

    {:ok, %{"participants" => members}} =
      Conversations.list_group_conversation_participants(f.group, f.task)

    worker_participant = Enum.find(members, &(&1["agent_id"] == f.worker))

    {:ok, owner} =
      SalixIM.ConversationFleet.ensure_participant_started(
        f.group,
        f.task,
        worker_participant["participant_id"]
      )

    fleet = Process.whereis(SalixIM.ConversationFleetSup)
    fleet_ref = Process.monitor(fleet)
    {:ok, task_owner} = SalixIM.ConversationFleet.ensure_started(f.group, f.task)
    task_owner_ref = Process.monitor(task_owner)
    owner_ref = Process.monitor(owner)
    :ok = :sys.suspend(fleet)

    # Queue demand startup before the supervisor receives the old owner's exit.
    # Both paths must converge on one replacement without stopping the fleet.
    restart =
      try do
        restart =
          Task.async(fn ->
            SalixIM.ConversationFleet.ensure_participant_started(
              f.group,
              f.task,
              worker_participant["participant_id"]
            )
          end)

        eventually(fn ->
          {:messages, messages} = Process.info(fleet, :messages)
          Enum.any?(messages, &match?({:"$gen_call", {pid, _}, _} when pid == restart.pid, &1))
        end)

        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 5_000
        restart
      after
        :sys.resume(fleet)
      end

    assert {:ok, replacement} = Task.await(restart, 5_000)
    add_source_message()
    Agent.update(Ports, &Map.put(&1, :pause_context, false))
    send(io, :release)

    SalixIM.ConversationParticipantActor.wake(
      f.group,
      f.task,
      worker_participant["participant_id"]
    )

    f = await_worker(f)
    source = read_source!(f)

    {:ok, _} =
      ConversationServer.append_group_conversation_agent_message(f.group, f.task, f.worker, %{
        "content" => "Private investigation notes"
      })

    assert {:ok, _} =
             complete(f, source, %{
               "kind" => "silence",
               "reason" => "The immediate answer suffices",
               "source_refs" => []
             })

    assert_completed(f)

    assert Enum.any?(inputs(), fn {id, payload, _} ->
             id == f.router["agent_id"] and
               payload[:trusted_origin]["task_conversation_id"] == f.task
           end)

    {:ok, followup} =
      ConversationServer.append_group_conversation_agent_message(f.group, f.task, f.worker, %{
        "content" => "Further investigation requested later"
      })

    eventually(fn ->
      Enum.any?(inputs(), fn {id, _, opts} ->
        id == f.router["agent_id"] and
          String.contains?(opts[:source_message_id] || "", followup["message_id"])
      end)
    end)

    refute Enum.any?(inputs(), fn {id, payload, _} ->
             id == f.router["agent_id"] and
               String.contains?(payload[:content] || "", "Private investigation notes")
           end)

    before_join =
      Enum.count(inputs(), fn {id, _, opts} ->
        id == f.router["agent_id"] and
          String.contains?(opts[:source_message_id] || "", followup["message_id"])
      end)

    {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
    {:ok, messages} = Conversations.list_group_conversation_messages(f.group, f.task, limit: 30)
    completion = Enum.find(messages, &get_in(&1, ["metadata", "triage_investigation_result"]))
    payload = completion["metadata"]["triage_investigation_result"]
    assert :ok = SalixIM.Triage.Investigation.join_task(%{payload: payload["payload"]})
    Process.sleep(100)

    assert before_join ==
             Enum.count(inputs(), fn {id, _, opts} ->
               id == f.router["agent_id"] and
                 String.contains?(opts[:source_message_id] || "", followup["message_id"])
             end)

    assert task["conversation_id"] == f.task
    refute_received {:DOWN, ^fleet_ref, :process, ^fleet, _}
    assert map_size(Agent.get(Ports, & &1.posts)) == 1

    assert {:ok, %{"data" => [_one]}} =
             Conversations.list_group_conversations(f.group, kind: "agent_task", limit: 10)

    # The replacement remains supervised and can recover from another crash.
    replacement_ref = Process.monitor(replacement)
    Process.exit(replacement, :kill)
    assert_receive {:DOWN, ^replacement_ref, :process, ^replacement, :killed}, 5_000

    eventually(fn ->
      key =
        SalixIM.ConversationParticipantActor.key(
          f.group,
          f.task,
          worker_participant["participant_id"]
        )

      case Registry.lookup(SalixIM.ConversationRegistry, key) do
        [{pid, _}] -> pid != replacement and Process.alive?(pid)
        [] -> false
      end
    end)

    assert Process.alive?(fleet)
    assert Process.alive?(task_owner)
    refute_received {:DOWN, ^task_owner_ref, :process, ^task_owner, _}
  end

  test "changed sources retry the same Worker twice then fail without a stale public reply" do
    f = fixture!()

    replacement =
      SalixAgent.TestSupport.create_control_agent_in_group!(f.router["tenant_id"], f.group)

    assert {:ok, _} =
             SalixAgent.TriageWorker.configure(
               f.group,
               f.router["agent_id"],
               replacement["agent_id"],
               0,
               %{"actor_user_id" => "admin", "request_id" => "new-worker"}
             )

    for attempt <- 1..3 do
      source = read_source!(f)
      Agent.update(Ports, &Map.put(&1, :pause_reply_lookup, true))

      assert {:ok, _} =
               complete(f, source, %{
                 "kind" => "reply",
                 "text" => "Answer to the observed source",
                 "source_refs" => [],
                 "context_candidates" => [
                   %{
                     "kind" => "project_fact",
                     "subject" => "Current status",
                     "value" => "Unverified old status",
                     "confidence" => "explicit",
                     "source_refs" => [hd(source["messages"])["source_ref"]]
                   },
                   %{
                     "kind" => "follow_up",
                     "subject" => "Old status check",
                     "value" => "Check obsolete status",
                     "confidence" => "explicit",
                     "source_refs" => [hd(source["messages"])["source_ref"]],
                     "follow_up_basis" => "agent_owned",
                     "recheck_after_hours" => 1
                   }
                 ]
               })

      assert_receive {:reply_lookup_paused, io}, 5_000
      add_source_message()
      Agent.update(Ports, &Map.put(&1, :pause_reply_lookup, false))
      send(io, :release)
      expected = if attempt < 3, do: "retry", else: "failed"

      eventually(fn ->
        {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
        get_in(task, ["metadata", "triage_investigation_state", "state"]) == expected
      end)

      assert [[0]] =
               Repo.query!("SELECT count(*) FROM triage_context_entries WHERE project_id = $1", [
                 f.project_id
               ]).rows
    end

    {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
    assert task["status"] == "failed"
    assert task["task_worker_agent_id"] == f.worker
    {:ok, messages} = Conversations.list_group_conversation_messages(f.group, f.task, limit: 30)
    retries = Enum.filter(messages, &get_in(&1, ["metadata", "triage_investigation_retry"]))
    assert length(retries) == 2

    assert Enum.all?(
             retries,
             &(get_in(&1, ["metadata", "triage_investigation_retry", "worker_agent_id"]) ==
                 f.worker)
           )

    assert Agent.get(Ports, & &1.posts) == %{}
    refute Enum.any?(inputs(), fn {id, _, _} -> id == replacement["agent_id"] end)
    refute Enum.any?(inputs(), fn {id, _, _} -> id == f.router["agent_id"] end)
  end

  @tag :failed_context_commit
  test "permanent provider rejection fails the Task without continuation or new context" do
    f = fixture!()
    source = read_source!(f)
    Agent.update(Ports, &Map.put(&1, :reject_post, :channel_unavailable))

    assert {:ok, _} =
             complete(f, source, %{
               "kind" => "reply",
               "text" => "Source-backed answer",
               "source_refs" => [],
               "context_candidates" => [
                 %{
                   "kind" => "project_fact",
                   "subject" => "Unsettled answer",
                   "value" => "A failed completion must not commit this candidate",
                   "confidence" => "explicit",
                   "source_refs" => [hd(source["messages"])["source_ref"]]
                 }
               ]
             })

    assert_receive {:slack_rejected, :channel_unavailable}, 5_000

    eventually(fn ->
      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      task["status"] == "failed"
    end)

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM triage_context_entries WHERE project_id = $1", [
               f.project_id
             ]).rows

    assert Agent.get(Ports, & &1.posts) == %{}
    refute Enum.any?(inputs(), fn {id, _, _} -> id == f.router["agent_id"] end)
  end

  test "exhausted Worker command delivery does not leave an unstarted investigation active" do
    f = fixture!(unavailable_worker: true)

    {:ok, %{"participants" => members}} =
      Conversations.list_group_conversation_participants(f.group, f.task)

    id = Enum.find(members, &(&1["agent_id"] == f.worker))["participant_id"]

    eventually(fn ->
      {:ok, task} = Conversations.get_group_conversation(f.group, f.task)
      task["status"] == "escalated"
    end)

    eventually(fn -> source_rejected?(f, id) end)
    {:ok, session} = InternalSessionStore.read(f.worker, f.session)
    assert SalixAgent.InternalSession.export(session).input_queue == []

    assert Agent.get(Ports, & &1.posts) == %{}
    refute Enum.any?(inputs(), fn {id, _, _} -> id == f.router["agent_id"] end)
  end

  test "accepted Worker command survives consumer restart without duplicate work" do
    f = fixture!(pause_accepted: true)
    assert_receive {:agent_accepted, io, source, {:ok, :created}}, 5_000
    Process.exit(io, :kill)
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

  test "failure escalation survives loss of the consumer before its frontier commit" do
    f = fixture!(unavailable_worker: true, pause_unavailable: true)

    for _ <- 1..2 do
      assert_receive {:agent_unavailable, io}, 5_000
      send(io, :release)
    end

    assert_receive {:agent_unavailable, io}, 5_000
    key = Keys.agent_internal_runtime_session(f.worker, f.session)
    SalixStore.S3.Fake.set_fault({:pause, :put, key})
    send(io, :release)
    eventually(fn -> SalixStore.S3.Fake.paused?() end)

    assert {:ok, %{"status" => "escalated"}} =
             Conversations.get_group_conversation(f.group, f.task)

    Process.exit(io, :kill)
    SalixStore.S3.Fake.release_pause()
    Agent.update(Ports, &Map.put(&1, :pause_unavailable, false))
    notify_worker(f)
    eventually(fn -> source_admitted?(f) end)

    assert {:ok, %{"status" => "escalated"}} =
             Conversations.get_group_conversation(f.group, f.task)
  end

  test "an exhausted command cannot escalate a replacement Worker session" do
    f = fixture!(unavailable_worker: true, pause_unavailable: true)

    for _ <- 1..2 do
      assert_receive {:agent_unavailable, io}, 5_000
      send(io, :release)
    end

    assert_receive {:agent_unavailable, io}, 5_000
    replacement = Ids.new_session_id()

    assert {:ok, participant} =
             ConversationServer.reconcile_group_conversation_agent_participants(
               f.group,
               f.task,
               %{
                 "desired" => %{
                   "agent_id" => f.worker,
                   "role_label" => "worker",
                   "payload" => %{"session_id" => replacement}
                 },
                 "selector" => %{"role_label" => "worker"}
               }
             )

    assert get_in(participant, ["payload", "session_id"]) == replacement
    send(io, :release)

    monitor = Process.monitor(io)
    assert_receive {:DOWN, ^monitor, :process, ^io, _}, 5_000
    assert {:error, :not_found} = InternalSessionStore.read(f.worker, replacement)
    assert {:ok, %{"status" => "active"}} = Conversations.get_group_conversation(f.group, f.task)
    assert Agent.get(Ports, & &1.posts) == %{}
  end

  test "ordinary Worker input survives a consumer crash without duplicate work" do
    f = fixture!(pause_accepted: true, ordinary: true)
    assert_receive {:agent_accepted, io, source, {:ok, :created}}, 5_000
    Process.exit(io, :kill)
    Agent.update(Ports, &Map.delete(&1, :pause_accepted_agent))
    notify_worker(f)
    eventually(fn -> source_admitted?(f) end)
    {:ok, session} = SessionData.read(f.worker, f.session)

    assert Enum.count(
             session.input_queue,
             &(get_in(&1, ["payload", "source_message_id"]) == source)
           ) == 1
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

  defp source_rejected?(f, participant) do
    case InternalSessionStore.read(f.worker, f.session) do
      {:ok, session} ->
        is_map(
          get_in(SalixAgent.InternalSession.conversation_sources(session), [
            participant,
            "last_rejection"
          ])
        )

      _ ->
        false
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

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
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
               "memory-fixture-#{System.unique_integer([:positive])}",
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
  # Participant drain timer; on a loaded runner that chain outlasted 10s. Keep
  # the 1s poll: these tests kill Participant owners, and polling faster packs
  # enough kills into the fleet supervisor's restart window to take it down.
  @eventually_timeout_ms 30_000

  defp eventually(fun),
    do:
      SalixAgent.LiveLlmTestSupport.eventually(
        fn -> if fun.(), do: {:ok, true}, else: :retry end,
        @eventually_timeout_ms
      )

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
