defmodule SalixStore.SessionIdentityMigrationE2ETest do
  use ExUnit.Case, async: false

  alias SalixStore.{Codec, Crypto, Ids, Keys, S3, SessionIdMigration, Timers}
  alias SalixStore.Migrations.SessionIdentity

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous_backend) end)
    :ok
  end

  test "migrates agent-scoped session owners and references, then reruns cleanly" do
    %{group_id: group_id, agent_a: agent_a, agent_b: agent_b} = hierarchy()
    legacy_session_id = "im-shared-legacy-session"
    conversation_id = Ids.new_conversation_id()
    deadline_ms = 1_800_000_000_000
    timer_id = "legacy-timer"

    internal_a_key = put_internal_session(agent_a, legacy_session_id)
    internal_b_key = put_internal_session(agent_b, legacy_session_id)
    external_key = put_external_session(agent_a, legacy_session_id)
    legacy_external_key = put_legacy_external_session(agent_a, legacy_session_id)

    conversation_key = Keys.ctl_group_conversation(group_id, conversation_id)

    put_json(conversation_key, %{
      "conversation_id" => conversation_id,
      "participants" => [
        %{
          "participant_id" => "worker-a",
          "agent_id" => agent_a,
          "payload" => %{"session_id" => legacy_session_id}
        },
        %{
          "participant_id" => "worker-b",
          "agent_id" => agent_b,
          "payload" => %{"session_id" => legacy_session_id}
        }
      ]
    })

    old_timer_key =
      Keys.timer(
        agent_a,
        legacy_session_id,
        timer_id,
        Timers.minute_bucket(deadline_ms)
      )

    put_json(old_timer_key, %{
      "agent_id" => agent_a,
      "session_id" => legacy_session_id,
      "timer_id" => timer_id,
      "deadline_ms" => deadline_ms
    })

    schedule_key = Keys.schedule(Ids.new_schedule_id())

    put_json(schedule_key, %{
      "agent_id" => agent_b,
      "session_id" => legacy_session_id,
      "status" => "active"
    })

    slack_status_key = Keys.ctl_im_slack_router_status_window("legacy-connect")

    put_json(slack_status_key, %{
      "agent_id" => agent_a,
      "session_id" => legacy_session_id,
      "targets" => [
        %{"source_agent_id" => agent_b, "source_session_id" => legacy_session_id}
      ]
    })

    assert {:ok, _stats} = SessionIdentity.run()
    assert {:ok, maps} = SessionIdMigration.read_all()

    target_a = get_in(maps, [agent_a, legacy_session_id])
    target_b = get_in(maps, [agent_b, legacy_session_id])

    assert Ids.valid_session_id?(target_a)
    assert Ids.valid_session_id?(target_b)
    refute target_a == target_b

    assert_moved_snapshot(
      internal_a_key,
      Keys.agent_internal_runtime_session(agent_a, target_a),
      target_a
    )

    assert %{events: [%{"session_id" => ^target_a, "result" => tool_result}]} =
             read_snapshot(Keys.agent_internal_runtime_session(agent_a, target_a))

    assert tool_result["session_id"] == legacy_session_id

    assert_moved_snapshot(
      internal_b_key,
      Keys.agent_internal_runtime_session(agent_b, target_b),
      target_b
    )

    assert {:error, :not_found} = S3.get(external_key)

    assert %{"session_id" => ^target_a} =
             read_json(Keys.agent_external_runtime_session(agent_a, target_a))

    assert {:error, :not_found} = S3.get(legacy_external_key)

    assert %{"participants" => participants} = read_json(conversation_key)
    assert get_in(Enum.at(participants, 0), ["payload", "session_id"]) == target_a
    assert get_in(Enum.at(participants, 1), ["payload", "session_id"]) == target_b

    new_timer_key =
      Keys.timer(agent_a, target_a, timer_id, Timers.minute_bucket(deadline_ms))

    assert {:error, :not_found} = S3.get(old_timer_key)
    assert %{"session_id" => ^target_a} = read_json(new_timer_key)
    assert %{"session_id" => ^target_b} = read_json(schedule_key)

    assert %{"session_id" => ^target_a, "targets" => [slack_target]} =
             read_json(slack_status_key)

    assert slack_target["source_session_id"] == target_b

    assert {:ok, _stats} = SessionIdentity.run()
    assert {:ok, ^maps} = SessionIdMigration.read_all()
  end

  test "reuses the reserved target after an interrupted owner move" do
    %{agent_a: agent_id} = hierarchy()
    legacy_session_id = "im-interrupted-session"
    source_key = put_internal_session(agent_id, legacy_session_id)

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :delete, source_key})

    assert {:error, {:session_identity_migration_failed, _reason}} = SessionIdentity.run()
    assert {:ok, first_map} = SessionIdMigration.read(agent_id)
    target_id = first_map.session_ids[legacy_session_id]
    target_key = Keys.agent_internal_runtime_session(agent_id, target_id)

    assert {:ok, _source} = S3.get(source_key)
    assert {:ok, _target} = S3.get(target_key)

    assert {:ok, _stats} = SessionIdentity.run()
    assert {:ok, second_map} = SessionIdMigration.read(agent_id)
    assert second_map.session_ids == first_map.session_ids
    assert {:error, :not_found} = S3.get(source_key)
    assert %{session_id: ^target_id} = read_snapshot(target_key)
  end

  test "finishes references after the owner was already moved" do
    %{group_id: group_id, agent_a: agent_id} = hierarchy()
    legacy_session_id = "im-owner-already-moved"
    conversation_id = Ids.new_conversation_id()

    assert {:ok, session_ids} = SessionIdMigration.reserve(agent_id, [legacy_session_id])
    target_id = session_ids[legacy_session_id]
    target_key = Keys.agent_internal_runtime_session(agent_id, target_id)

    assert {:ok, _} =
             S3.put(
               target_key,
               Codec.encode_snapshot(%{agent_id: agent_id, session_id: target_id, messages: []})
             )

    conversation_key = Keys.ctl_group_conversation(group_id, conversation_id)

    put_json(conversation_key, %{
      "conversation_id" => conversation_id,
      "participants" => [
        %{
          "participant_id" => "worker",
          "agent_id" => agent_id,
          "payload" => %{"session_id" => legacy_session_id}
        }
      ]
    })

    assert {:ok, _stats} = SessionIdentity.run()
    assert %{session_id: ^target_id} = read_snapshot(target_key)

    assert %{"participants" => [participant]} = read_json(conversation_key)
    assert get_in(participant, ["payload", "session_id"]) == target_id
    assert {:ok, %{session_ids: ^session_ids}} = SessionIdMigration.read(agent_id)
  end

  defp hierarchy do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    %{
      group_id: group_id,
      agent_a: Ids.new_agent_id(group_id),
      agent_b: Ids.new_agent_id(group_id)
    }
  end

  defp put_internal_session(agent_id, session_id) do
    key = Keys.agent_internal_runtime_session(agent_id, session_id)

    assert {:ok, _} =
             S3.put(
               key,
               Codec.encode_snapshot(%{
                 agent_id: agent_id,
                 session_id: session_id,
                 messages: [],
                 events: [
                   %{
                     "type" => "tool_result",
                     "session_id" => session_id,
                     "result" => %{"session_id" => session_id}
                   }
                 ]
               })
             )

    key
  end

  defp put_external_session(agent_id, session_id) do
    key =
      Keys.agent_external_runtime_sessions_prefix(agent_id) <>
        Crypto.hex(session_id) <> ".json"

    put_json(key, %{
      "agent_id" => agent_id,
      "session_id" => session_id,
      "status" => "failed",
      "last_error" => "external runtime identity changed",
      "runtime" => %{"binding" => %{"kind" => "external"}, "payload" => %{}},
      "input_message_queue" => [],
      "message_count" => 0,
      "updated_at" => 200
    })

    key
  end

  defp put_legacy_external_session(agent_id, session_id) do
    key =
      "ctl/external_runtime_sessions/#{agent_id}/#{Crypto.hex(session_id)}.json"

    put_json(key, %{
      "agent_id" => agent_id,
      "session_id" => session_id,
      "status" => "ready",
      "last_error" => nil,
      "updated_at" => 100,
      "events" => [%{"event_id" => "broken-history"}]
    })

    key
  end

  defp put_json(key, value) do
    assert {:ok, _} = S3.put(key, Jason.encode!(value))
  end

  defp read_json(key) do
    assert {:ok, %{body: body}} = S3.get(key)
    Jason.decode!(body)
  end

  defp read_snapshot(key) do
    assert {:ok, %{body: body}} = S3.get(key)
    Codec.decode_snapshot(body)
  end

  defp assert_moved_snapshot(source_key, target_key, target_session_id) do
    assert {:error, :not_found} = S3.get(source_key)
    assert %{session_id: ^target_session_id} = read_snapshot(target_key)
    assert String.contains?(target_key, Crypto.hex(target_session_id))
  end
end
