defmodule SalixIM.ProviderConversationLogTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.{ConversationServer, Conversations}
  alias SalixStore.{Ids, Keys, Repo}

  setup do
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_placement = SystemsRuntime.get_env(:salix_im, :conversation_placement)
    prev_provider_delivery = SystemsRuntime.get_env(:salix_im, :slack_conversation_delivery_mod)

    SalixIM.TestSupport.Fleet.stop_all!()

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    SystemsRuntime.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    SalixStore.Repo.query!("DELETE FROM conversation_log_recovery")
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, prev_s3)
        restore(:salix_im, :conversation_placement, prev_placement)
        restore(:salix_im, :slack_conversation_delivery_mod, prev_provider_delivery)
        SystemsRuntime.delete_env(:salix_im, :delivery_recovery_test_pid)
      end
    end)

    :ok
  end

  test "public append wakes the participant owner and drains its delivery" do
    SystemsRuntime.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.CaptureProviderDelivery
    )

    SystemsRuntime.put_env(:salix_im, :delivery_recovery_test_pid, SystemsRuntime.Proc.self())

    ids =
      delivery_group_fixture!()
      |> create_delivery_conversation!("Public participant wake")

    agent_id = ids.agent
    message_id = append_delivery!(ids, "public-participant-wake")

    settle_receive({:provider_delivery_captured, ^agent_id})

    assert eventually(fn ->
             delivery_status(ids, message_id) == "delivered"
           end)
  end

  test "retryable delivery waits across participant owner restart instead of replaying immediately" do
    SystemsRuntime.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.RetryProviderDelivery
    )

    SystemsRuntime.put_env(:salix_im, :delivery_recovery_test_pid, SystemsRuntime.Proc.self())

    ids =
      delivery_group_fixture!()
      |> create_delivery_conversation!("Delivery retry")

    agent_id = ids.agent
    message_id = append_delivery!(ids, "retryable-delivery")
    settle_receive({:retry_provider_delivery_attempt, ^agent_id})

    assert eventually(fn ->
             delivery_status(ids, message_id) == "retry_waiting"
           end)

    stop_participant_owner!(ids)
    assert :ok = ConversationServer.wake_participant(ids.group, ids.conversation, ids.participant)
    settle_refute_receive({:retry_provider_delivery_attempt, ^agent_id}, 300)

    assert {:ok, %{"deliveries" => [delivery]}} =
             Conversations.group_conversation_delivery_status(
               ids.group,
               ids.conversation,
               participant_id: ids.participant,
               message_id: message_id,
               limit: 1
             )

    assert delivery["status"] == "retry_waiting"
    assert delivery["delivery"]["attempts"] == 1
  end

  test "an unknown claim resumes the same Store result before provider I/O", _context do
    SystemsRuntime.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.CaptureProviderDelivery
    )

    SystemsRuntime.put_env(:salix_im, :delivery_recovery_test_pid, SystemsRuntime.Proc.self())
    ids = delivery_group_fixture!() |> create_delivery_conversation!("Unknown claim")

    Repo.query!("""
    CREATE FUNCTION provider_claim_disconnect() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.participant_id = '#{ids.participant}' AND NEW.status = 'delivering' THEN
        PERFORM pg_terminate_backend(pg_backend_pid());
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER provider_claim_disconnect BEFORE INSERT OR UPDATE ON salix_conversation_deliveries FOR EACH ROW EXECUTE FUNCTION provider_claim_disconnect()"
    )

    on_exit(fn ->
      Repo.query!(
        "DROP TRIGGER IF EXISTS provider_claim_disconnect ON salix_conversation_deliveries"
      )

      Repo.query!("DROP FUNCTION IF EXISTS provider_claim_disconnect()")
    end)

    message = append_delivery!(ids, "unknown-claim")

    {:ok, owner} =
      SalixIM.ConversationFleet.ensure_participant_started(
        ids.group,
        ids.conversation,
        ids.participant
      )

    settle_until(fn ->
      state = :sys.get_state(owner)
      match?(%{mode: :settle_claim}, state.active_delivery)
    end)

    refute_received {:provider_delivery_captured, _}
    Repo.query!("DROP TRIGGER provider_claim_disconnect ON salix_conversation_deliveries")
    Repo.query!("DROP FUNCTION provider_claim_disconnect()")
    agent = ids.agent
    settle_receive({:provider_delivery_captured, ^agent})
    assert eventually(fn -> delivery_status(ids, message) == "delivered" end)
    settle_refute_receive({:provider_delivery_captured, _}, 100)
  end

  test "shared recovery settles an inactive provider after owner loss without new sends" do
    previous = SystemsRuntime.get_env(:salix_agent, :conversation_source_mod)
    SystemsRuntime.put_env(:salix_agent, :conversation_source_mod, SalixIM.ConversationSource)
    on_exit(fn -> restore(:salix_agent, :conversation_source_mod, previous) end)

    SystemsRuntime.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.BlockingProviderDelivery
    )

    SystemsRuntime.put_env(:salix_im, :delivery_recovery_test_pid, SystemsRuntime.Proc.self())
    ids = delivery_group_fixture!() |> create_delivery_conversation!("Shared recovery")
    message = append_delivery!(ids, "restart")
    settle_receive({:provider_delivery_blocked, _, _})

    assert {:ok, %{"state" => "inactive"}} =
             ConversationServer.deactivate_group_conversation_participant(
               ids.group,
               ids.conversation,
               ids.participant
             )

    append_delivery!(ids, "after-deactivation")
    SalixIM.TestSupport.Fleet.stop_all!()
    [record] = active_delivery_records(ids)

    Repo.query!(
      "UPDATE salix_conversation_deliveries SET payload=$5, revision=revision+1 WHERE group_id=$1 AND conversation_id=$2 AND participant_id=$3 AND delivery_id=$4",
      [
        ids.group,
        ids.conversation,
        ids.participant,
        record["delivery_id"],
        :erlang.term_to_binary(Map.put(record, "delivery_started_at", 0))
      ]
    )

    SystemsRuntime.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.VerifiedProviderDelivery
    )

    for _ <- 1..6,
        do:
          assert(
            {:ok, _} =
              SalixIM.ConversationLogRecovery.sweep(
                SystemsClock.system_time(:millisecond) + 60_000
              )
          )

    settle_receive(:provider_delivery_verified)
    assert eventually(fn -> delivery_status(ids, message) == "delivered" end)
    settle_refute_receive({:provider_delivery_captured, _}, 100)
  end

  defp delivery_group_fixture! do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Delivery Recovery"})

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Delivery worker",
        "role" => "worker"
      })

    connect = Ids.new_connect_id()

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect), %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "connect_id" => connect,
        "provider" => "slack",
        "inbound_agent_id" => agent["agent_id"]
      })

    %{
      connect: connect,
      tenant: tenant_id,
      group: group_id,
      agent: agent["agent_id"]
    }
  end

  defp create_delivery_conversation!(fixture, title, statuses \\ "none") do
    now = SystemsClock.system_time(:millisecond)

    assert {:ok, conversation} =
             SalixIM.ConversationInput.create_group_conversation(fixture.group, %{
               "title" => title,
               "participants" => [
                 %{
                   "actor_type" => "user",
                   "user_id" => "current",
                   "state" => "active",
                   "notification_filter" => %{"messages" => "all", "statuses" => "none"},
                   "created_at" => now,
                   "updated_at" => now
                 },
                 %{
                   "actor_type" => "provider",
                   "provider" => "slack",
                   "target_key" => fixture.connect,
                   "payload" => %{"connect_id" => fixture.connect, "channel_id" => "C1"},
                   "role_label" => "provider",
                   "state" => "active",
                   "notification_filter" => %{"messages" => "all", "statuses" => statuses},
                   "created_at" => now,
                   "updated_at" => now
                 }
               ]
             })

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(
               fixture.group,
               conversation["conversation_id"]
             )

    participant = Enum.find(participants, &(&1["actor_type"] == "provider"))

    Map.merge(fixture, %{
      conversation: conversation["conversation_id"],
      participant: participant["participant_id"]
    })
  end

  defp append_delivery!(ids, request_id) do
    assert {:ok, %{"message_id" => message_id}} =
             ConversationServer.append_group_conversation_message(
               ids.group,
               ids.conversation,
               %{
                 "content" => "delivery recovery " <> request_id
               }
             )

    message_id
  end

  defp active_delivery_records(ids) do
    ids
    |> delivery_records()
    |> Enum.filter(&(&1["status"] in ["pending", "delivering", "retry_waiting"]))
  end

  defp delivery_records(ids) do
    %{rows: rows} =
      Repo.query!(
        "SELECT payload FROM salix_conversation_deliveries WHERE group_id=$1 AND conversation_id=$2 AND participant_id=$3 ORDER BY delivery_id LIMIT 100",
        [ids.group, ids.conversation, ids.participant]
      )

    Enum.map(rows, fn [body] -> :erlang.binary_to_term(body, [:safe]) end)
  end

  defp delivery_status(ids, message_id) do
    case Conversations.group_conversation_delivery_status(
           ids.group,
           ids.conversation,
           participant_id: ids.participant,
           message_id: message_id,
           limit: 1
         ) do
      {:ok, %{"deliveries" => [delivery]}} -> delivery["status"]
      _ -> nil
    end
  end

  defp stop_participant_owner!(ids) do
    key =
      SalixIM.ConversationParticipantActor.key(
        ids.group,
        ids.conversation,
        ids.participant
      )

    stop_participant_owner_until_quiet!(key, 100, 0)
  end

  defp stop_participant_owner_until_quiet!(_key, 0, _stable_empty_count),
    do: flunk("participant owner did not quiesce before recovery assertion")

  defp stop_participant_owner_until_quiet!(key, attempts_left, stable_empty_count) do
    case Registry.lookup(SalixIM.ConversationRegistry, key) do
      [] when stable_empty_count >= 1 ->
        :ok

      [] ->
        SystemsClock.sleep(10)
        stop_participant_owner_until_quiet!(key, attempts_left - 1, stable_empty_count + 1)

      [{pid, _value}] ->
        assert DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, pid) in [
                 :ok,
                 {:error, :not_found}
               ]

        SystemsClock.sleep(10)
        stop_participant_owner_until_quiet!(key, attempts_left - 1, 0)
    end
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)

  defmodule BlockingProviderDelivery do
    @moduledoc false

    def post_message(_tenant, connect, _params, _surface) do
      agent_id = connect["inbound_agent_id"]

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        {:provider_delivery_blocked, SystemsRuntime.Proc.self(), agent_id}
      )

      SystemsRuntime.Proc.receive do
        :release_provider_delivery -> {:ok, :created}
      after
        5_000 -> {:error, :test_delivery_timeout}
      end
    end

    def find_message(_, _, _, _, _), do: {:ok, nil}
  end

  defmodule CaptureProviderDelivery do
    @moduledoc false

    def post_message(_tenant, connect, _params, _surface) do
      agent_id = connect["inbound_agent_id"]

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        {:provider_delivery_captured, agent_id}
      )

      {:ok, :created}
    end

    def find_message(_, _, _, _, _), do: {:ok, nil}
  end

  defmodule VerifiedProviderDelivery do
    def post_message(_, _, _, _) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        {:provider_delivery_captured, :duplicate}
      )

      {:ok, :created}
    end

    def find_message(_, _, _, _, _) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        :provider_delivery_verified
      )

      {:ok, %{"ts" => "123.456"}}
    end
  end

  defmodule RetryProviderDelivery do
    @moduledoc false

    def post_message(_tenant, connect, _params, _surface) do
      agent_id = connect["inbound_agent_id"]

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        {:retry_provider_delivery_attempt, agent_id}
      )

      {:error, :temporary_unavailable}
    end

    def find_message(_, _, _, _, _), do: {:ok, nil}
  end
end
