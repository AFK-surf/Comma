defmodule SalixIM.ConversationSourceProgressTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  use SalixStore.QueueCase, queues: [:conversation_log_recovery]

  alias SalixAgent.InternalSessionStore.PG, as: SessionPG
  alias SalixIM.{ConversationPGStore, ConversationParticipantPGStore, ConversationSource}
  alias SalixStore.{AgentPGStore, ConversationLogRecovery, Ids, Repo, S3}

  defmodule WakeOnly do
    def notify_conversation(agent, source) do
      send(
        SystemsRuntime.fetch_env!(:salix_im, :source_progress_test_pid),
        {:source_woken, agent, source}
      )

      :ok
    end

    def conversation_progress(_, _, _), do: raise("recovery called a per-Session RPC")
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    overrides = [
      {:salix_store, :s3_backend, S3.Fake},
      {:salix_im, :agent_delivery_mod, WakeOnly},
      {:salix_im, :source_progress_test_pid, self()}
    ]

    previous =
      Enum.map(overrides, fn {app, key, value} ->
        old = SystemsRuntime.get_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, old}
      end)

    start_supervised!(S3.Fake)
    group = Ids.new_group_id(Ids.new_tenant_id())
    SalixAgent.TestSupport.create_control_group!(group)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SalixIM.TestSupport.Fleet.stop_all!()
      for {app, key, value} <- previous, do: SystemsRuntime.put_env(app, key, value)
    end)

    %{group: group}
  end

  test "one JOIN preserves Agent filters, Router binding and inactive provider work", %{
    group: group
  } do
    worker = agent(group, "worker")
    router = agent(group, "router")
    session = Ids.new_session_id()
    normal = participant(worker, session, %{"state" => nil})
    router_participant = participant(router, Ids.new_session_id())
    inactive = participant(worker, session, %{"state" => "inactive"})
    filtered = participant(worker, session, %{"notification_filter" => %{"messages" => "none"}})

    external =
      participant(worker, session, %{"payload" => %{"session_id" => session, "runs_on" => %{}}})

    provider = %{
      "participant_id" => Ids.new_participant_id(),
      "actor_type" => "provider",
      "provider" => "slack",
      "target_key" => "slack:connect:C_TEST:thread",
      "payload" => %{"connect_id" => "connect", "channel_id" => "C_TEST", "thread_ts" => "1.0"},
      "state" => "inactive",
      "notification_filter" => %{"messages" => "none"},
      "delivery_log_cursor_seq" => 0
    }

    {scope, _} =
      conversation(group, [normal, router_participant, inactive, filtered, external, provider])

    observed = candidate(scope)
    pending = consumers(observed)

    assert MapSet.new(Enum.map(pending, & &1.id)) ==
             MapSet.new([
               normal["participant_id"],
               router_participant["participant_id"],
               provider["participant_id"]
             ])

    assert Enum.find(pending, &(&1.id == router_participant["participant_id"])).session ==
             router["router_session_id"]

    assert :ok = ConversationLogRecovery.complete(observed)
    assert recovery_count(scope) == 1

    accept(worker, session, scope, normal["participant_id"])
    accept(router, router["router_session_id"], scope, router_participant["participant_id"])
    assert Enum.map(consumers(observed), & &1.id) == [provider["participant_id"]]

    provider_scope =
      ConversationParticipantPGStore.new(group, scope.conversation_id, provider["participant_id"])

    assert {:ok, current, revision} = ConversationParticipantPGStore.read(provider_scope)

    assert {:ok, _} =
             ConversationParticipantPGStore.execute(
               ConversationParticipantPGStore.prepare(
                 provider_scope,
                 revision,
                 Map.put(current, "delivery_log_cursor_seq", 1),
                 :updated
               )
             )

    assert consumers(observed) == []

    assert {:ok, config} = AgentPGStore.read_config(router["agent_id"])
    next_session = Ids.new_session_id()

    assert {:ok, _} =
             AgentPGStore.put_config(
               router["agent_id"],
               Map.put(config.record, "router_session_id", next_session),
               config.revision
             )

    assert [%{id: id, session: ^next_session}] = consumers(observed)
    assert id == router_participant["participant_id"]
  end

  test "completion retains concurrent canonical tail and membership targets", %{group: group} do
    worker = agent(group, "worker")
    part = participant(worker, Ids.new_session_id())
    {scope, _} = conversation(group, [part])
    old = candidate(scope)

    part_scope =
      ConversationParticipantPGStore.new(group, scope.conversation_id, part["participant_id"])

    assert {:ok, record, revision} = ConversationParticipantPGStore.read(part_scope)

    assert {:ok, _} =
             ConversationParticipantPGStore.execute(
               ConversationParticipantPGStore.prepare(
                 part_scope,
                 revision,
                 Map.put(record, "state", "inactive"),
                 :updated
               )
             )

    assert :ok = ConversationLogRecovery.complete(old)
    assert recovery_count(scope) == 1
    member_target = candidate(scope)
    assert member_target.membership_revision > old.membership_revision
    assert {:ok, _, rev} = ConversationPGStore.read(scope)
    assert {:ok, :inserted, _, _, _} = ConversationPGStore.append(scope, rev, message())
    assert :ok = ConversationLogRecovery.complete(member_target)
    assert recovery_count(scope) == 1
    assert :ok = ConversationLogRecovery.complete(candidate(scope))
    assert recovery_count(scope) == 0
  end

  test "retiring after an unfinished snapshot cannot skip the original Triage tail action", %{
    group: group
  } do
    worker = agent(group, "worker")
    session = Ids.new_session_id()
    part = participant(worker, session)
    assert {:ok, head} = AgentPGStore.peek(worker["agent_id"])
    assert {:ok, _} = SessionPG.create(worker["agent_id"], session, head.epoch)

    {scope, _} =
      conversation(group, [part], %{
        "kind" => "agent_task",
        "status" => "active",
        "task_worker_agent_id" => worker["agent_id"],
        "source_refs" => %{"triage_investigation" => %{"worker_agent_id" => worker["agent_id"]}}
      })

    observed = candidate(scope)
    observer = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:salix_store, :repo, :query],
      fn _, _, metadata, _ ->
        if metadata.params == [group, scope.conversation_id] and
             String.contains?(metadata.query, "LEFT JOIN LATERAL") and
             Process.get(handler) != true do
          Process.put(handler, true)
          send(observer, {:consumers_observed, self()})
          receive do: (:continue_recovery -> :ok)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    recovery = SystemsRuntime.Task.async(fn -> ConversationSource.recover(observed) end)
    settle_receive({:consumers_observed, reader})

    Repo.query!(
      "UPDATE salix_sessions SET deleted_at=clock_timestamp() WHERE agent_id=$1 AND session_id=$2",
      [worker["agent_id"], session]
    )

    send(reader, :continue_recovery)
    assert {:ok, :pending} = settled_await(recovery)
    :telemetry.detach(handler)
    settle_receive({:source_woken, _, _})
    assert recovery_count(scope) == 1
    assert {:ok, %{"status" => "active"}, _} = ConversationPGStore.read(scope)
    assert [%{retired: true, unfinished: false}] = consumers(observed)

    assert ConversationSource.recover(candidate(scope)) in [:ok, {:ok, :pending}]
    assert {:ok, %{"status" => "escalated"}, _} = ConversationPGStore.read(scope)
    assert :ok = ConversationSource.recover(candidate(scope))
    assert recovery_count(scope) == 0
  end

  defp agent(group, role),
    do: SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group), %{"role" => role})

  defp participant(agent, session, extra \\ %{}) do
    Map.merge(
      %{
        "participant_id" => Ids.new_participant_id(),
        "actor_type" => "agent",
        "agent_id" => agent["agent_id"],
        "state" => "active",
        "role_label" => "Worker",
        "notification_filter" => %{"messages" => "all", "statuses" => "none"},
        "payload" => %{"session_id" => session},
        "source_start_seq" => 0
      },
      extra
    )
  end

  defp conversation(group, participants, extra \\ %{}) do
    scope = ConversationPGStore.new(group, Ids.new_conversation_id())

    record =
      Map.merge(
        %{
          "kind" => "user_chat",
          "status" => "active",
          "title" => "Consumer progress",
          "created_at" => 1,
          "updated_at" => 1,
          "participants" => participants
        },
        extra
      )

    assert {:ok, :inserted, record, _, _} =
             ConversationPGStore.create_with_message(scope, record, message())

    {scope, record}
  end

  defp message,
    do: %{
      "message_id" => Ids.new_message_id(),
      "kind" => "message",
      "content" => "command",
      "created_at" => 1
    }

  defp candidate(scope) do
    assert %{rows: [[seq, status, membership]]} =
             Repo.query!(
               "SELECT target_seq,status_version,membership_revision FROM conversation_log_recovery WHERE group_id=$1 AND conversation_id=$2",
               [scope.group_id, scope.conversation_id]
             )

    Map.merge(Map.from_struct(scope), %{
      target_seq: seq,
      status_version: status,
      membership_revision: membership
    })
  end

  defp consumers(candidate) do
    assert {:ok, %{rows: rows}} = ConversationLogRecovery.consumers(candidate)

    Enum.flat_map(rows, fn row ->
      case Enum.drop(row, 20) do
        [nil | _] ->
          []

        [id, _, _, session, retired, unfinished] ->
          [%{id: id, session: session, retired: retired, unfinished: unfinished}]
      end
    end)
  end

  defp accept(agent, session, scope, participant) do
    assert {:ok, head} = AgentPGStore.peek(agent["agent_id"])

    loaded =
      case SessionPG.read(agent["agent_id"], session) do
        {:error, :not_found} -> SessionPG.create(agent["agent_id"], session, head.epoch)
        result -> result
      end

    assert {:ok, revision} = loaded

    assert {{:ok, :committed}, _} =
             SessionPG.input_revision(revision, head.epoch, %{
               source_message_id: Ids.new_message_id(),
               payload: %{content: "body", created_at: 1},
               conversation_source: %{
                 "conversation_id" => scope.conversation_id,
                 "participant_id" => participant,
                 "generation" => session,
                 "start_seq" => 0,
                 "seq" => 1
               }
             })
  end

  defp recovery_count(scope),
    do:
      Repo.query!(
        "SELECT count(*) FROM conversation_log_recovery WHERE group_id=$1 AND conversation_id=$2",
        [scope.group_id, scope.conversation_id]
      ).rows
      |> hd()
      |> hd()
end
