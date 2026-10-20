defmodule SalixMeet.RuntimeEventsTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet"]
  alias SalixMeet.{OwnerAttributionSnapshot, RuntimeEvents, Store}

  defmodule BatchArtifactRuntime do
    def stream_meeting_artifact_write(_agent_id, _env_id, path, _meeting_id, source_ref, _size) do
      case source_ref do
        "accepted" -> {:ok, %{"type" => "vfs_write", "path" => path, "ref" => %{"id" => path}}}
        "rejected" -> {:error, :source_changed}
      end
    end

    def discard_prepared_workspace_write(event) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :runtime_events_test_pid),
        {:discarded, event}
      )

      :ok
    end

    def stat_workspace(_agent_id, _path), do: {:error, :not_found}
  end

  defmodule FailingCleanupRuntime do
    def discard_prepared_workspace_write(event) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :runtime_events_test_pid),
        {:discard_attempt, event}
      )

      if event["path"] == "/second",
        do: {:error, :delete_unavailable},
        else: :ok
    end
  end

  defmodule RecordingArtifactRuntime do
    def stream_meeting_artifact_write(_agent_id, _env_id, path, _meeting_id, source_ref, _size) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :runtime_events_test_pid),
        {:artifact_read, source_ref}
      )

      {:ok, %{"type" => "vfs_write", "path" => path, "ref" => %{"id" => path}}}
    end

    def discard_prepared_workspace_write(_event), do: :ok
    def stat_workspace(_agent_id, _path), do: {:error, :not_found}
  end

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn ->
      if is_nil(previous_backend) do
        SystemsRuntime.delete_env(:salix_store, :s3_backend)
      else
        SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
      end
    end)

    :ok
  end

  test "explicit refusal ends calendar admission, freezes the reason and blocks retry" do
    for code <- ~w(admission_denied meeting_full removed_from_meeting) do
      id = "refused-#{code}-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      assert {:ok, _, _} =
               Store.create_once(id,
                 state: %{
                   "status" => "joining",
                   "source" => %{"kind" => "calendar"},
                   "end_at" => SystemsClock.system_time(:second) + 600,
                   "join_dispatch" => %{"status" => "dispatched", "attempt_count" => 1}
                 }
               )

      event = %{
        "type" => "joiner_event",
        "meeting_id" => id,
        "joiner_event" => %{
          "type" => "status",
          "status" => "error",
          "reason_code" => code,
          "message" => "refused"
        }
      }

      apply_event!(event, "refusal")

      apply_event!(
        %{
          "type" => "meeting_runtime_update",
          "meeting_id" => id,
          "status" => "failed",
          "reason_code" => code
        },
        "terminal"
      )

      apply_event!(
        %{event | "joiner_event" => %{"type" => "status", "status" => "in_meeting"}},
        "late-admission"
      )

      apply_event!(
        %{
          "type" => "meeting_runtime_update",
          "meeting_id" => id,
          "status" => "failed",
          "reason_code" => "admission_timeout"
        },
        "late-timeout"
      )

      assert {:ok, doc, _} = Store.get(id)
      assert doc["state"]["status"] == "failed"
      refute get_in(doc, ["state", "joiner_status_notifications", "in_meeting"])
      assert doc["state"]["reason_code"] == code
      refute doc["state"]["joined_at"]
      refute Store.join_retry_candidate?(doc)

      assert {:error, :terminal_meeting} =
               Store.claim_join_dispatch(id, %{"generation" => "test", "claimed_by" => "test"})
    end
  end

  test "removal preserves recorded captions and cannot be reopened by late admission" do
    id = "removed-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    assert {:ok, _, _} =
             Store.create_once(id,
               state: %{
                 "status" => "active",
                 "joined_at" => 123,
                 "captions" => [%{"text" => "recorded before removal"}]
               }
             )

    event = %{
      "type" => "joiner_event",
      "meeting_id" => id,
      "joiner_event" => %{
        "type" => "meeting_ended",
        "reason_code" => "removed_from_meeting",
        "timestamp" => 200
      }
    }

    apply_event!(event, "removed")

    apply_event!(
      %{
        event
        | "joiner_event" => %{"type" => "status", "status" => "in_meeting", "timestamp" => 300}
      },
      "late"
    )

    assert {:ok, doc, _} = Store.get(id)
    assert doc["state"]["status"] == "processing"
    assert doc["state"]["joined_at"] == 123

    apply_event!(
      %{
        "type" => "meeting_runtime_update",
        "meeting_id" => id,
        "status" => "done",
        "reason_code" => "removed_from_meeting"
      },
      "done"
    )

    assert {:ok, doc, _} = Store.get(id)
    assert doc["state"]["status"] == "done"
    assert doc["state"]["reason_code"] == "removed_from_meeting"
    assert [%{"text" => "recorded before removal"}] = doc["state"]["captions"]
  end

  defp apply_event!(event, source) do
    assert {:ok, prepared} = RuntimeEvents.prepare(%{}, event)
    assert :ok = RuntimeEvents.apply(prepared, source)
  end

  test "joiner status checkpoints the joined-to-left duration boundaries" do
    meeting_id = "runtime-duration-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: %{"status" => "joining"})

    in_meeting = %{
      "type" => "joiner_event",
      "meeting_id" => meeting_id,
      "joiner_event" => %{
        "type" => "status",
        "status" => "in_meeting",
        "timestamp" => 1_000
      }
    }

    assert {:ok, prepared} = RuntimeEvents.prepare(%{}, in_meeting)
    assert :ok = RuntimeEvents.apply(prepared, "runtime-duration-joined")

    left = %{
      "type" => "joiner_event",
      "meeting_id" => meeting_id,
      "joiner_event" => %{"type" => "status", "status" => "left", "timestamp" => 1_601}
    }

    assert {:ok, prepared} = RuntimeEvents.prepare(%{}, left)
    assert :ok = RuntimeEvents.apply(prepared, "runtime-duration-left")
    assert {:ok, doc, _etag} = Store.get(meeting_id)

    assert doc["state"]["status"] == "processing"
    assert doc["state"]["joined_at"] == 1_000
    assert doc["state"]["left_at"] == 1_601
  end
  describe "terminal one-way valve" do
    test "a late done event cannot rewrite a terminal status or summary" do
      meeting_id = "valve-late-done-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id,
                 state: %{
                   "status" => "failed",
                   "error" => "runtime_lost",
                   "summary" => %{"title" => "Original", "action_items" => []}
                 }
               )

      event = %{
        "type" => "meeting_runtime_update",
        "meeting_id" => meeting_id,
        "status" => "done",
        "summary" => %{"title" => "Late summary", "action_items" => []},
        "captions" => [%{"speaker" => "A", "text" => "late caption"}]
      }

      assert {:ok, prepared} = RuntimeEvents.prepare(%{}, event)
      assert :ok = RuntimeEvents.apply(prepared, "valve-late-done-event")
      assert {:ok, doc, _etag} = Store.get(meeting_id)

      assert doc["state"]["status"] == "failed"
      assert doc["state"]["summary"] == %{"title" => "Original", "action_items" => []}

      late = doc["state"]["late_runtime_status"]
      assert late["status"] == "done"
      assert late["summary"]["title"] == "Late summary"
      assert is_integer(late["received_at"])
      assert is_binary(late["runtime_event_id"])

      # Non-valve fields still merge through their normal idempotent paths.
      assert [%{"text" => "late caption"}] =
               Enum.map(doc["state"]["captions"], &Map.take(&1, ["text"]))
    end

    # meet-native's real failure sequence: the joiner status=error callback
    # first, then (after that callback drains) the meeting_runtime_update
    # status=failed terminal. Both faces must land on the same failed
    # *attempt*; the second must not undo the first.
    test "the runtime's two-callback pre-join failure is one failed attempt, not a failed meeting" do
      meeting_id = "prejoin-fail-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      end_at = SystemsClock.system_time(:second) + 600

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id,
                 state: %{
                   "status" => "joining",
                   "source" => %{"kind" => "calendar"},
                   "end_at" => end_at,
                   "join_requested_at" => 1,
                   "join_dispatch" => %{"status" => "dispatched", "attempt_count" => 1}
                 }
               )

      joiner_error = %{
        "type" => "joiner_event",
        "meeting_id" => meeting_id,
        "joiner_event" => %{
          "type" => "status",
          "status" => "error",
          "message" => "admission_timeout: no admit within 10m0s"
        }
      }

      terminal_failed = %{
        "type" => "meeting_runtime_update",
        "meeting_id" => meeting_id,
        "status" => "failed",
        "error" => "admission_timeout: no admit within 10m0s"
      }

      assert {:ok, prepared} = RuntimeEvents.prepare(%{}, joiner_error)
      assert :ok = RuntimeEvents.apply(prepared, "prejoin-fail-joiner")
      assert {:ok, after_joiner, _etag} = Store.get(meeting_id)
      assert after_joiner["state"]["status"] == "joining"
      assert after_joiner["state"]["join_dispatch"]["status"] == "failed"

      assert {:ok, prepared} = RuntimeEvents.prepare(%{}, terminal_failed)
      assert :ok = RuntimeEvents.apply(prepared, "prejoin-fail-terminal")
      assert {:ok, doc, _etag} = Store.get(meeting_id)

      assert doc["state"]["status"] == "joining"
      assert doc["state"]["join_dispatch"]["status"] == "failed"
      assert doc["state"]["join_dispatch"]["last_error"] =~ "admission_timeout"
      assert doc["state"]["error"] =~ "admission_timeout"
      assert Store.join_retry_candidate?(doc)
    end
  end
end
