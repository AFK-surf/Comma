defmodule SalixMeet.RuntimeEventsTest do
  use ExUnit.Case, async: false

  alias SalixMeet.{OwnerAttributionSnapshot, RuntimeEvents, Store}

  defmodule BatchArtifactRuntime do
    def stream_meeting_artifact_write(_agent_id, _env_id, path, _meeting_id, source_ref, _size) do
      case source_ref do
        "accepted" -> {:ok, %{"type" => "vfs_write", "path" => path, "ref" => %{"id" => path}}}
        "rejected" -> {:error, :source_changed}
      end
    end

    def discard_prepared_workspace_write(event) do
      send(Application.fetch_env!(:salix_meet, :runtime_events_test_pid), {:discarded, event})
      :ok
    end

    def stat_workspace(_agent_id, _path), do: {:error, :not_found}
  end

  defmodule FailingCleanupRuntime do
    def discard_prepared_workspace_write(event) do
      send(
        Application.fetch_env!(:salix_meet, :runtime_events_test_pid),
        {:discard_attempt, event}
      )

      if event["path"] == "/second",
        do: {:error, :delete_unavailable},
        else: :ok
    end
  end

  defmodule RecordingArtifactRuntime do
    def stream_meeting_artifact_write(_agent_id, _env_id, path, _meeting_id, source_ref, _size) do
      send(
        Application.fetch_env!(:salix_meet, :runtime_events_test_pid),
        {:artifact_read, source_ref}
      )

      {:ok, %{"type" => "vfs_write", "path" => path, "ref" => %{"id" => path}}}
    end

    def discard_prepared_workspace_write(_event), do: :ok
    def stat_workspace(_agent_id, _path), do: {:error, :not_found}
  end

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn ->
      if is_nil(previous_backend) do
        Application.delete_env(:salix_store, :s3_backend)
      else
        Application.put_env(:salix_store, :s3_backend, previous_backend)
      end
    end)

    :ok
  end

  test "explicit refusal ends calendar admission, freezes the reason and blocks retry" do
    for code <- ~w(admission_denied meeting_full removed_from_meeting) do
      id = "refused-#{code}-#{System.unique_integer([:positive])}"

      assert {:ok, _, _} =
               Store.create_once(id,
                 state: %{
                   "status" => "joining",
                   "source" => %{"kind" => "calendar"},
                   "end_at" => System.system_time(:second) + 600,
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
    id = "removed-#{System.unique_integer([:positive])}"

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

  test "unknown reasons and transport errors never become admission denial" do
    id = "unknown-#{System.unique_integer([:positive])}"
    assert {:ok, _, _} = Store.create_once(id, state: %{"status" => "joining"})

    apply_event!(
      %{
        "type" => "meeting_runtime_update",
        "meeting_id" => id,
        "status" => "failed",
        "reason_code" => "401",
        "error" => "sync status 401"
      },
      "transport"
    )

    assert {:ok, doc, _} = Store.get(id)
    refute doc["state"]["reason_code"]
    assert doc["state"]["error"] == "sync status 401"
  end

  defp apply_event!(event, source) do
    assert {:ok, prepared} = RuntimeEvents.prepare(%{}, event)
    assert :ok = RuntimeEvents.apply(prepared, source)
  end

  test "runtime summary updates strip attribution fields without touching delivery metadata" do
    meeting_id = "runtime-summary-#{System.unique_integer([:positive])}"

    bound_summary = %{"title" => "Bound summary", "action_items" => []}

    owner_attribution =
      OwnerAttributionSnapshot.build(bound_summary, bound_summary, completed_at: 1)

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{
                 "status" => "processing",
                 "delivery" => %{"owner_attribution" => owner_attribution}
               }
             )

    event = %{
      "type" => "meeting_runtime_update",
      "meeting_id" => meeting_id,
      "status" => "done",
      "summary" => %{
        :owner_attribution_done => true,
        "title" => "Runtime summary",
        "action_items" => [
          %{
            "description" => "Ship",
            :owner_slack_id => "UFORGED",
            "nested" => %{"owner_attribution_done" => true, "owner_slack_id" => "UOTHER"}
          }
        ]
      },
      "delivery" => %{"owner_attribution" => %{"status" => "forged"}}
    }

    assert {:ok, %{vfs_events: []} = prepared} = RuntimeEvents.prepare(%{}, event)
    assert :ok = RuntimeEvents.apply(prepared, "runtime-summary-event")
    assert {:ok, doc, _etag} = Store.get(meeting_id)

    assert doc["state"]["summary"] == %{
             "title" => "Runtime summary",
             "action_items" => [
               %{"description" => "Ship", "nested" => %{}}
             ]
           }

    assert get_in(doc, ["state", "delivery", "owner_attribution"]) == owner_attribution
  end

  test "joiner status checkpoints the joined-to-left duration boundaries" do
    meeting_id = "runtime-duration-#{System.unique_integer([:positive])}"
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

  test "a later streamed artifact failure rolls back every earlier prepared artifact" do
    previous_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
    previous_pid = Application.get_env(:salix_meet, :runtime_events_test_pid)
    Application.put_env(:salix_meet, :agent_runtime_mod, BatchArtifactRuntime)
    Application.put_env(:salix_meet, :runtime_events_test_pid, self())

    on_exit(fn ->
      restore_env(:salix_meet, :agent_runtime_mod, previous_runtime)
      restore_env(:salix_meet, :runtime_events_test_pid, previous_pid)
    end)

    meeting_id = "runtime-artifact-batch-#{System.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{"status" => "processing", "meeting_agent_id" => "agt_meeting"}
             )

    event = %{
      "type" => "meeting_runtime_update",
      "meeting_id" => meeting_id,
      "status" => "done",
      "artifacts" => [
        %{
          "kind" => "transcript",
          "filename" => "transcript.txt",
          "source_ref" => "accepted",
          "source_size" => 10
        },
        %{
          "kind" => "audio",
          "filename" => "audio.mp3",
          "source_ref" => "rejected",
          "source_size" => 10
        }
      ]
    }

    assert {:error, {:artifact_ingest_failed, "audio", :source_changed}} =
             RuntimeEvents.prepare(%{"meeting_agent_id" => "agt_meeting"}, event, "env_origin")

    expected_path = "/meetings/" <> meeting_id <> "/transcript.txt"

    assert_receive {:discarded,
                    %{
                      "type" => "vfs_write",
                      "path" => ^expected_path
                    }}
  end

  test "source_error cannot hide a live or unknown artifact source" do
    previous_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
    previous_pid = Application.get_env(:salix_meet, :runtime_events_test_pid)
    Application.put_env(:salix_meet, :agent_runtime_mod, RecordingArtifactRuntime)
    Application.put_env(:salix_meet, :runtime_events_test_pid, self())

    on_exit(fn ->
      restore_env(:salix_meet, :agent_runtime_mod, previous_runtime)
      restore_env(:salix_meet, :runtime_events_test_pid, previous_pid)
    end)

    meeting_id = "runtime-terminal-artifact-#{System.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{"status" => "processing", "meeting_agent_id" => "agt_meeting"}
             )

    base_event = %{
      "type" => "meeting_runtime_update",
      "meeting_id" => meeting_id,
      "status" => "done"
    }

    live_source =
      Map.put(base_event, "artifacts", [
        %{
          "kind" => "audio",
          "source_error" => "unavailable",
          "source_ref" => "still-live",
          "source_size" => 10
        }
      ])

    assert {:error, :artifact_source_error_invalid} =
             RuntimeEvents.prepare(%{"meeting_agent_id" => "agt_meeting"}, live_source, "env")

    unknown_terminal =
      Map.put(base_event, "artifacts", [
        %{"kind" => "audio", "source_error" => "unexpected_connector_error"}
      ])

    assert {:error, :artifact_source_error_invalid} =
             RuntimeEvents.prepare(
               %{"meeting_agent_id" => "agt_meeting"},
               unknown_terminal,
               "env"
             )

    refute_receive {:artifact_read, _source_ref}
  end

  test "prepared cleanup attempts every ref even when one delete fails" do
    previous_runtime = Application.get_env(:salix_meet, :agent_runtime_mod)
    previous_pid = Application.get_env(:salix_meet, :runtime_events_test_pid)
    Application.put_env(:salix_meet, :agent_runtime_mod, FailingCleanupRuntime)
    Application.put_env(:salix_meet, :runtime_events_test_pid, self())

    on_exit(fn ->
      restore_env(:salix_meet, :agent_runtime_mod, previous_runtime)
      restore_env(:salix_meet, :runtime_events_test_pid, previous_pid)
    end)

    first = %{"type" => "vfs_write", "path" => "/first", "ref" => %{"uuid" => "one"}}
    second = %{"type" => "vfs_write", "path" => "/second", "ref" => %{"uuid" => "two"}}

    assert {:error, {:prepared_artifact_cleanup_failed, [:delete_unavailable]}} =
             RuntimeEvents.cleanup_prepared(%{vfs_events: [first, second]})

    assert_receive {:discard_attempt, ^second}
    assert_receive {:discard_attempt, ^first}
  end

  test "streamed artifact preflight rejection emits bounded meeting artifact telemetry" do
    handler_id = "meeting-artifact-preflight-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:salix, :operation, :stop],
        fn event, measurements, metadata, listener ->
          send(listener, {event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    meeting_id = "runtime-artifact-preflight-#{System.unique_integer([:positive])}"

    assert {:ok, _doc, _etag} =
             Store.create_once(meeting_id,
               state: %{"status" => "processing", "meeting_agent_id" => "agt_meeting"}
             )

    event = %{
      "type" => "meeting_runtime_update",
      "meeting_id" => meeting_id,
      "status" => "done",
      "artifacts" =>
        for index <- 1..9 do
          %{
            "kind" => "artifact-#{index}",
            "filename" => "artifact-#{index}.bin",
            "source_ref" => "ref-#{index}",
            "source_size" => 1
          }
        end
    }

    assert {:error, :artifact_count_limit} =
             RuntimeEvents.prepare(%{"meeting_agent_id" => "agt_meeting"}, event, "env_origin")

    assert_receive {
      [:salix, :operation, :stop],
      %{duration: 0},
      %{
        component: "salix_meet",
        operation: "meeting_artifact",
        surface: "system",
        outcome: "rejected"
      }
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  describe "terminal one-way valve" do
    test "a late done event cannot rewrite a terminal status or summary" do
      meeting_id = "valve-late-done-#{System.unique_integer([:positive])}"

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

    test "replaying the terminal event itself is a no-op without a late record" do
      meeting_id = "valve-replay-#{System.unique_integer([:positive])}"

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id,
                 state: %{
                   "status" => "done",
                   "summary" => %{"title" => "Same", "action_items" => []}
                 }
               )

      event = %{
        "type" => "meeting_runtime_update",
        "meeting_id" => meeting_id,
        "status" => "done",
        "summary" => %{"title" => "Same", "action_items" => []}
      }

      assert {:ok, prepared} = RuntimeEvents.prepare(%{}, event)
      assert :ok = RuntimeEvents.apply(prepared, "valve-replay-event")
      assert {:ok, doc, _etag} = Store.get(meeting_id)

      assert doc["state"]["status"] == "done"
      refute Map.has_key?(doc["state"], "late_runtime_status")
    end

    # meet-native's real failure sequence: the joiner status=error callback
    # first, then (after that callback drains) the meeting_runtime_update
    # status=failed terminal. Both faces must land on the same failed
    # *attempt*; the second must not undo the first.
    test "the runtime's two-callback pre-join failure is one failed attempt, not a failed meeting" do
      meeting_id = "prejoin-fail-#{System.unique_integer([:positive])}"
      end_at = System.system_time(:second) + 600

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

    # Only calendar-autojoin-owned meetings have a durable retry owner. A
    # manual Slack meeting keeps the terminal-on-failure behaviour: demoting
    # it would strand it in `joining` with the provider answering
    # `already_active` forever.
    test "a manual Slack meeting's pre-join failure stays terminal" do
      meeting_id = "prejoin-manual-#{System.unique_integer([:positive])}"

      assert {:ok, _doc, _etag} =
               Store.create_once(meeting_id,
                 state: %{
                   "status" => "joining",
                   "source" => "message",
                   "end_at" => System.system_time(:second) + 600,
                   "join_requested_at" => 1,
                   "join_dispatch" => %{"status" => "dispatched", "attempt_count" => 1}
                 }
               )

      event = %{
        "type" => "joiner_event",
        "meeting_id" => meeting_id,
        "joiner_event" => %{
          "type" => "status",
          "status" => "error",
          "message" => "token factory failed"
        }
      }

      assert {:ok, prepared} = RuntimeEvents.prepare(%{}, event)
      assert :ok = RuntimeEvents.apply(prepared, "prejoin-manual-event")
      assert {:ok, doc, _etag} = Store.get(meeting_id)

      assert doc["state"]["status"] == "failed"
      assert doc["state"]["join_dispatch"]["status"] == "dispatched"
      refute Store.join_retry_candidate?(doc)
    end

    test "the same failure stays terminal once joined, after the meeting end, or with the budget spent" do
      terminal_cases = [
        {"joined", %{"joined_at" => 1_700_000_000}},
        {"ended", %{"end_at" => System.system_time(:second) - 1}},
        {"exhausted", %{"join_dispatch" => %{"status" => "dispatched", "attempt_count" => 5}}}
      ]

      for {label, extra} <- terminal_cases do
        meeting_id = "prejoin-terminal-#{label}-#{System.unique_integer([:positive])}"

        base = %{
          "status" => "joining",
          "source" => %{"kind" => "calendar"},
          "end_at" => System.system_time(:second) + 600,
          "join_requested_at" => 1,
          "join_dispatch" => %{"status" => "dispatched", "attempt_count" => 1}
        }

        assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: Map.merge(base, extra))

        event = %{
          "type" => "meeting_runtime_update",
          "meeting_id" => meeting_id,
          "status" => "failed",
          "error" => "token factory failed after 5 attempts"
        }

        assert {:ok, prepared} = RuntimeEvents.prepare(%{}, event)
        assert :ok = RuntimeEvents.apply(prepared, "prejoin-terminal-#{label}")
        assert {:ok, doc, _etag} = Store.get(meeting_id)
        assert doc["state"]["status"] == "failed", label
      end
    end

    test "a late joiner event cannot flip a terminal meeting back to processing" do
      meeting_id = "valve-late-joiner-#{System.unique_integer([:positive])}"
      assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: %{"status" => "done"})

      event = %{
        "type" => "joiner_event",
        "meeting_id" => meeting_id,
        "joiner_event" => %{"type" => "status", "status" => "left", "timestamp" => 1_700_000_000}
      }

      assert {:ok, prepared} = RuntimeEvents.prepare(%{}, event)
      assert :ok = RuntimeEvents.apply(prepared, "valve-late-joiner-event")
      assert {:ok, doc, _etag} = Store.get(meeting_id)

      assert doc["state"]["status"] == "done"
      assert doc["state"]["left_at"] == 1_700_000_000
      assert doc["state"]["late_runtime_status"]["status"] == "processing"
    end
  end
end
