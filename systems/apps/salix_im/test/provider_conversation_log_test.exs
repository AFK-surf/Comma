defmodule SalixIM.ProviderConversationLogTest do
  use ExUnit.Case, async: false

  alias SalixIM.{ConversationServer, Conversations}
  alias SalixStore.{Ids, Keys, S3}

  setup do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    prev_placement = Application.get_env(:salix_im, :conversation_placement)
    prev_provider_delivery = Application.get_env(:salix_im, :slack_conversation_delivery_mod)

    SalixIM.TestSupport.Fleet.stop_all!()

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(
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
        Application.delete_env(:salix_im, :delivery_recovery_test_pid)
      end
    end)

    :ok
  end

  test "indexed recovery republishes a status after its log append fails" do
    Application.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.CaptureProviderDelivery
    )

    Application.put_env(:salix_im, :delivery_recovery_test_pid, self())

    ids =
      delivery_group_fixture!() |> create_delivery_conversation!("Before status change", "all")

    assert {:ok, []} = SalixStore.ConversationLogRecovery.claim(8)

    prefix = Keys.ctl_group_conversation_messages_segments_prefix(ids.group, ids.conversation)
    S3.Fake.blackhole({:fail, 503, :put, {:prefix, prefix}})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:ok, updated} =
             ConversationServer.update_group_conversation(ids.group, ids.conversation, %{
               "title" => "Recovered status title"
             })

    assert updated["title"] == "Recovered status title"
    assert {:ok, [candidate]} = SalixStore.ConversationLogRecovery.claim(8)

    SalixIM.TestSupport.Fleet.stop_all!()
    assert {:error, _} = SalixIM.ConversationSource.recover(candidate)

    assert {:ok, [^candidate]} =
             SalixStore.ConversationLogRecovery.claim(
               8,
               System.system_time(:millisecond) + 60_000
             )

    S3.Fake.clear_blackhole()
    assert result = SalixIM.ConversationSource.recover(candidate)
    assert result in [:ok, {:ok, :pending}]

    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(ids.group, ids.conversation,
               limit: 32
             )

    assert Enum.any?(
             messages,
             &(get_in(&1, ["provider_status", "title"]) == "Recovered status title")
           )
  end

  test "public append wakes the participant owner and drains its delivery" do
    Application.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.CaptureProviderDelivery
    )

    Application.put_env(:salix_im, :delivery_recovery_test_pid, self())

    ids =
      delivery_group_fixture!()
      |> create_delivery_conversation!("Public participant wake")

    agent_id = ids.agent
    message_id = append_delivery!(ids, "public-participant-wake")

    assert_receive {:provider_delivery_captured, ^agent_id}, 2_000

    assert eventually(fn ->
             delivery_status(ids, message_id) == "delivered"
           end)
  end

  test "retryable delivery waits across participant owner restart instead of replaying immediately" do
    Application.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.RetryProviderDelivery
    )

    Application.put_env(:salix_im, :delivery_recovery_test_pid, self())

    ids =
      delivery_group_fixture!()
      |> create_delivery_conversation!("Delivery retry")

    agent_id = ids.agent
    message_id = append_delivery!(ids, "retryable-delivery")
    assert_receive {:retry_provider_delivery_attempt, ^agent_id}, 2_000

    assert eventually(fn ->
             delivery_status(ids, message_id) == "retry_waiting"
           end)

    stop_participant_owner!(ids)
    assert :ok = ConversationServer.wake_participant(ids.group, ids.conversation, ids.participant)
    refute_receive {:retry_provider_delivery_attempt, ^agent_id}, 300

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

  test "an exact delivery-state read fault is not projected as an empty delivery list" do
    {ids, message_id, delivery} = delivered_fixture!("Exact delivery-state read fault")

    state_key =
      Keys.ctl_group_conversation_participant_delivery_state(
        ids.group,
        ids.conversation,
        ids.participant,
        delivery["delivery_id"]
      )

    assert :ok = S3.Fake.blackhole({:fail, 503, :get, state_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:error, _reason} =
             Conversations.group_conversation_delivery_status(
               ids.group,
               ids.conversation,
               participant_id: ids.participant,
               message_id: message_id,
               limit: 1
             )
  end

  test "a delivery-state list fault is not projected as an empty delivery list" do
    {ids, _message_id, _delivery} = delivered_fixture!("Delivery-state list fault")

    deliveries_prefix =
      Keys.ctl_group_conversation_participant_deliveries_prefix(
        ids.group,
        ids.conversation,
        ids.participant
      )

    assert :ok = S3.Fake.set_fault({:fail, 503, :list, deliveries_prefix})

    assert {:error, _reason} =
             Conversations.group_conversation_delivery_status(
               ids.group,
               ids.conversation,
               participant_id: ids.participant,
               limit: 1
             )
  end

  test "a listed delivery-state read fault is not projected as an empty delivery list" do
    {ids, _message_id, delivery} = delivered_fixture!("Listed delivery-state read fault")

    state_key =
      Keys.ctl_group_conversation_participant_delivery_state(
        ids.group,
        ids.conversation,
        ids.participant,
        delivery["delivery_id"]
      )

    assert :ok = S3.Fake.blackhole({:fail, 503, :get, state_key})
    on_exit(fn -> S3.Fake.clear_blackhole() end)

    assert {:error, _reason} =
             Conversations.group_conversation_delivery_status(
               ids.group,
               ids.conversation,
               participant_id: ids.participant,
               limit: 1
             )
  end

  test "shared recovery settles an inactive provider after owner loss without new sends" do
    previous = Application.get_env(:salix_agent, :conversation_source_mod)
    Application.put_env(:salix_agent, :conversation_source_mod, SalixIM.ConversationSource)
    on_exit(fn -> restore(:salix_agent, :conversation_source_mod, previous) end)

    Application.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.BlockingProviderDelivery
    )

    Application.put_env(:salix_im, :delivery_recovery_test_pid, self())
    ids = delivery_group_fixture!() |> create_delivery_conversation!("Shared recovery")
    message = append_delivery!(ids, "restart")
    assert_receive {:provider_delivery_blocked, _, _}, 2_000

    assert {:ok, %{"state" => "inactive"}} =
             ConversationServer.deactivate_group_conversation_participant(
               ids.group,
               ids.conversation,
               ids.participant
             )

    append_delivery!(ids, "after-deactivation")
    SalixIM.TestSupport.Fleet.stop_all!()
    [record] = active_delivery_records(ids)

    key =
      Keys.ctl_group_conversation_participant_delivery_state(
        ids.group,
        ids.conversation,
        ids.participant,
        record["delivery_id"]
      )

    {:ok, _} = SalixStore.CasRecord.update(key, &Map.put(&1, "delivery_started_at", 0))

    Application.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.VerifiedProviderDelivery
    )

    for _ <- 1..6,
        do:
          assert(
            {:ok, _} =
              SalixIM.ConversationLogRecovery.sweep(System.system_time(:millisecond) + 60_000)
          )

    assert_receive :provider_delivery_verified, 2_000
    assert eventually(fn -> delivery_status(ids, message) == "delivered" end)
    refute_receive {:provider_delivery_captured, _}, 100
  end

  test "cutover discards old pending output but retains history and new output" do
    Application.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.BlockingProviderDelivery
    )

    Application.put_env(:salix_im, :delivery_recovery_test_pid, self())
    ids = delivery_group_fixture!() |> create_delivery_conversation!("Automatic cutover")
    old = append_delivery!(ids, "old")
    assert_receive {:provider_delivery_blocked, _, _}, 2_000
    pending = append_delivery!(ids, "pending")
    SalixIM.TestSupport.Fleet.stop_all!()

    {:ok, _} =
      SalixStore.CasRecord.update(
        Keys.ctl_group_conversation(ids.group, ids.conversation),
        &Map.delete(&1, "log_start_seq")
      )

    {:ok, _} =
      SalixStore.CasRecord.update(
        Keys.ctl_group_conversation_participant_state(
          ids.group,
          ids.conversation,
          ids.participant
        ),
        &Map.delete(&1, "delivery_log_cursor_seq")
      )

    Application.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.CaptureProviderDelivery
    )

    new = append_delivery!(ids, "new")
    assert_receive {:provider_delivery_captured, _}, 2_000
    assert eventually(fn -> delivery_status(ids, new) == "delivered" end)
    assert delivery_status(ids, old) == "unknown"
    refute_receive {:provider_delivery_captured, _}, 100
    {:ok, messages} = Conversations.list_group_conversation_messages(ids.group, ids.conversation)
    assert Enum.map(messages, & &1["message_id"]) == [old, pending, new]
    SalixIM.TestSupport.Fleet.stop_all!()
    assert :ok = ConversationServer.wake_participant(ids.group, ids.conversation, ids.participant)
    refute_receive {:provider_delivery_captured, _}, 100
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
    now = System.system_time(:millisecond)

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

  defp delivered_fixture!(title) do
    Application.put_env(
      :salix_im,
      :slack_conversation_delivery_mod,
      __MODULE__.CaptureProviderDelivery
    )

    Application.put_env(:salix_im, :delivery_recovery_test_pid, self())

    ids =
      delivery_group_fixture!()
      |> create_delivery_conversation!(title)

    message_id = append_delivery!(ids, "delivery-status-read-fault")
    agent_id = ids.agent

    assert_receive {:provider_delivery_captured, ^agent_id}, 2_000

    assert eventually(fn ->
             delivery_status(ids, message_id) == "delivered"
           end)

    assert [delivery] = delivery_records(ids)
    {ids, message_id, delivery}
  end

  defp active_delivery_records(ids) do
    ids
    |> delivery_records()
    |> Enum.filter(&(&1["status"] in ["pending", "delivering", "retry_waiting"]))
  end

  defp delivery_records(ids) do
    prefix =
      Keys.ctl_group_conversation_participant_deliveries_prefix(
        ids.group,
        ids.conversation,
        ids.participant
      )

    assert {:ok, objects} = S3.list_all(prefix)

    objects
    |> Enum.filter(&String.ends_with?(&1.key, "/state.json"))
    |> Enum.map(fn %{key: key} ->
      assert {:ok, %{body: body}} = S3.get(key)
      Jason.decode!(body)
    end)
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
        Process.sleep(10)
        stop_participant_owner_until_quiet!(key, attempts_left - 1, stable_empty_count + 1)

      [{pid, _value}] ->
        assert DynamicSupervisor.terminate_child(SalixIM.ConversationFleetSup, pid) in [
                 :ok,
                 {:error, :not_found}
               ]

        Process.sleep(10)
        stop_participant_owner_until_quiet!(key, attempts_left - 1, 0)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp eventually(fun, retries \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, retries) do
    case fun.() do
      true ->
        true

      _ ->
        Process.sleep(20)
        eventually(fun, retries - 1)
    end
  end

  defmodule BlockingProviderDelivery do
    @moduledoc false

    def post_message(_tenant, connect, _params, _surface) do
      agent_id = connect["inbound_agent_id"]

      send(
        Application.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        {:provider_delivery_blocked, self(), agent_id}
      )

      receive do
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

      send(
        Application.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        {:provider_delivery_captured, agent_id}
      )

      {:ok, :created}
    end

    def find_message(_, _, _, _, _), do: {:ok, nil}
  end

  defmodule VerifiedProviderDelivery do
    def post_message(_, _, _, _) do
      send(
        Application.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        {:provider_delivery_captured, :duplicate}
      )

      {:ok, :created}
    end

    def find_message(_, _, _, _, _) do
      send(
        Application.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        :provider_delivery_verified
      )

      {:ok, %{"ts" => "123.456"}}
    end
  end

  defmodule RetryProviderDelivery do
    @moduledoc false

    def post_message(_tenant, connect, _params, _surface) do
      agent_id = connect["inbound_agent_id"]

      send(
        Application.fetch_env!(:salix_im, :delivery_recovery_test_pid),
        {:retry_provider_delivery_attempt, agent_id}
      )

      {:error, :temporary_unavailable}
    end

    def find_message(_, _, _, _, _), do: {:ok, nil}
  end
end
