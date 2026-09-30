defmodule SalixMeet.MeetingTest do
  @moduledoc """
  Meeting leadership and state share `meet/{id}/state.json`: the lease is folded
  into that object via CAS, so a single ETag fences both leadership
  renewal and state mutation. Two contending nodes → exactly one wins;
  `join_requested_at` is stamped at most once; state is resumable across
  reloads; a stale leader is fenced on renew. Against the Fake backend.
  """
  use ExUnit.Case, async: false

  alias SalixMeet.{Delivery, FallbackMessageManifest, Meeting, Store}
  alias SalixStore.Crypto

  defmodule CountingS3Counter do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> 0 end, name: __MODULE__)
    def increment, do: Agent.update(__MODULE__, &(&1 + 1))
    def value, do: Agent.get(__MODULE__, & &1)
  end

  defmodule CountingS3 do
    @behaviour SalixStore.S3

    alias SalixStore.S3.Fake

    defdelegate put(key, body, opts), to: Fake
    defdelegate put_stream(key, stream, opts), to: Fake
    defdelegate multipart_create(key, opts), to: Fake
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: Fake
    defdelegate multipart_complete(key, upload_id, parts), to: Fake
    defdelegate multipart_abort(key, upload_id), to: Fake

    def get(key, opts) do
      CountingS3Counter.increment()
      Fake.get(key, opts)
    end

    defdelegate stream(key, opts), to: Fake
    defdelegate head(key), to: Fake
    defdelegate delete(key, opts), to: Fake
    defdelegate list(prefix, opts), to: Fake
  end

  defmodule ExpiredActivation do
    @behaviour SalixMeet.Ports.Activation

    @impl true
    def handoff(_state, _summary), do: {:error, :meeting_activation_capability_expired}
  end

  defmodule HeartbeatCrashProbe do
    use Agent

    def start_link(_opts),
      do: Agent.start_link(fn -> %{armed: false, test_pid: nil} end, name: __MODULE__)

    def arm(test_pid),
      do: Agent.update(__MODULE__, &%{&1 | armed: true, test_pid: test_pid})

    def raise_if_armed do
      case Agent.get_and_update(__MODULE__, fn state ->
             if state.armed do
               {{:raise, state.test_pid}, %{state | armed: false}}
             else
               {:ok, state}
             end
           end) do
        {:raise, test_pid} ->
          send(test_pid, :heartbeat_backend_raised)
          raise "simulated heartbeat backend crash"

        :ok ->
          :ok
      end
    end
  end

  defmodule HeartbeatCrashS3 do
    @behaviour SalixStore.S3

    alias SalixStore.S3.Fake

    defdelegate put(key, body, opts), to: Fake
    defdelegate put_stream(key, stream, opts), to: Fake
    defdelegate multipart_create(key, opts), to: Fake
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: Fake
    defdelegate multipart_complete(key, upload_id, parts), to: Fake
    defdelegate multipart_abort(key, upload_id), to: Fake

    def get(key, opts) do
      SalixMeet.MeetingTest.HeartbeatCrashProbe.raise_if_armed()
      Fake.get(key, opts)
    end

    defdelegate stream(key, opts), to: Fake
    defdelegate head(key), to: Fake
    defdelegate delete(key, opts), to: Fake
    defdelegate list(prefix, opts), to: Fake
  end

  setup do
    # These fixtures exercise the retained synchronous adapter / downstream
    # publication contract. Router-owned generation has dedicated integration tests.
    previous_router_summary = Application.get_env(:salix_meet, :router_summary_mod)
    Application.delete_env(:salix_meet, :router_summary_mod)

    on_exit(fn ->
      if previous_router_summary,
        do: Application.put_env(:salix_meet, :router_summary_mod, previous_router_summary),
        else: Application.delete_env(:salix_meet, :router_summary_mod)
    end)

    prev = Application.get_env(:salix_store, :s3_backend)
    prev_driver = Application.get_env(:salix_meet, :runtime_driver)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_meet, :runtime_driver, __MODULE__.RuntimeDriver)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()
    start_supervised!(__MODULE__.RuntimeDriver)

    on_exit(fn ->
      stop_all_meetings()
      Application.put_env(:salix_store, :s3_backend, prev)
      restore_env(:salix_meet, :runtime_driver, prev_driver)
    end)

    {:ok, id: "meet-#{System.unique_integer([:positive])}"}
  end

  defmodule RuntimeDriver do
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def join(doc), do: Agent.update(__MODULE__, &[doc | &1])
    def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)
  end

  describe "create_once" do
    test "creates exactly once; second is :exists", %{id: id} do
      assert {:ok, doc, _etag} = Store.create_once(id)
      assert doc["id"] == id
      assert doc["epoch"] == 0
      assert doc["leader_node"] == nil
      assert doc["join_requested_at"] == nil
      assert {:error, :exists} = Store.create_once(id)
    end
  end

  describe "leadership via CAS on the state object" do
    test "two nodes contend → exactly one wins", %{id: id} do
      t0 = 1_000_000
      assert {:ok, _doc, etag} = Store.create_once(id, now: t0)

      # Both nodes read the same fresh (unowned) doc + ETag, then race the CAS.
      assert {:ok, doc_a, etag_a} =
               Store.claim_leader(id, "node-a", etag, now: t0, ttl_ms: 30_000)

      assert doc_a["leader_node"] == "node-a"
      assert doc_a["epoch"] == 1

      # node-b raced with the SAME (now stale) ETag → loses the CAS.
      assert {:error, :lost} = Store.claim_leader(id, "node-b", etag, now: t0, ttl_ms: 30_000)

      # Re-reading, node-b sees a live, unexpired leader → held_by.
      assert {:ok, _doc, live_etag} = Store.get(id)

      assert {:error, {:held_by, "node-a", _until}} =
               Store.claim_leader(id, "node-b", live_etag, now: t0 + 5_000, ttl_ms: 30_000)

      # node-a renews under its held ETag.
      assert {:ok, doc_a2, _etag} =
               Store.claim_leader(id, "node-a", etag_a, now: t0 + 1_000, ttl_ms: 30_000)

      assert doc_a2["epoch"] == 2
    end

    test "stale leader is stealable; the stale ETag renew is fenced", %{id: id} do
      t0 = 1_000_000
      {:ok, _doc, etag} = Store.create_once(id, now: t0)
      {:ok, _doc_a, etag_a} = Store.claim_leader(id, "node-a", etag, now: t0, ttl_ms: 30_000)

      # After the lease expires, node-b steals via a fresh read.
      {:ok, _doc, etag1} = Store.get(id)

      assert {:ok, doc_b, _etag_b} =
               Store.claim_leader(id, "node-b", etag1, now: t0 + 40_000, ttl_ms: 30_000)

      assert doc_b["leader_node"] == "node-b"
      assert doc_b["epoch"] == 2

      # node-a's stale ETag can no longer renew — fenced.
      assert {:error, :lost} =
               Store.claim_leader(id, "node-a", etag_a, now: t0 + 41_000, ttl_ms: 30_000)
    end
  end

  describe "join-at-most-once" do
    test "join_requested_at is stamped once; second attempt is idempotent", %{id: id} do
      {:ok, _doc, etag} = Store.create_once(id)
      {:ok, _doc, etag} = Store.claim_leader(id, "node-a", etag, ttl_ms: 30_000)

      assert {:ok, doc1, etag1} = Store.set_join_requested(id, etag, at: 5_000)
      assert doc1["join_requested_at"] == 5_000

      # Second attempt under the live ETag: no-op, timestamp unchanged.
      assert {:ok, doc2, _etag2} = Store.set_join_requested(id, etag1, at: 9_999)
      assert doc2["join_requested_at"] == 5_000
    end
  end

  describe "resumable state" do
    test "state survives a reload from S3", %{id: id} do
      {:ok, _doc, etag} = Store.create_once(id)
      {:ok, _doc, etag} = Store.claim_leader(id, "node-a", etag, ttl_ms: 30_000)

      {:ok, _doc, _etag} =
        Store.update_state(id, etag, fn s -> Map.put(s, "agenda", "kickoff") end)

      # Fresh read (as a new process / re-election would do) sees the state.
      assert {:ok, doc, _etag} = Store.get(id)
      assert doc["state"]["agenda"] == "kickoff"
      assert doc["leader_node"] == "node-a"
    end

    test "update_state under a stale ETag is fenced", %{id: id} do
      {:ok, _doc, etag} = Store.create_once(id)
      {:ok, _doc, etag1} = Store.claim_leader(id, "node-a", etag, ttl_ms: 30_000)
      {:ok, _doc, _etag2} = Store.update_state(id, etag1, fn s -> Map.put(s, "x", 1) end)

      # etag1 is now stale → fenced.
      assert {:error, :lost} = Store.update_state(id, etag1, fn s -> Map.put(s, "x", 2) end)
    end
  end

  describe "delivery claims" do
    test "failure updates require the exact node and attempt generation", %{id: id} do
      assert {:ok, _doc, _etag} =
               Store.create_once(id, state: %{"status" => "done"})

      assert {:ok, _doc, _etag, claim_1} =
               Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, failed_doc, _etag} =
               Store.fail_delivery_retrying(id, claim_1, "first failure", now: 1_100)

      assert failed_doc["state"]["delivery"]["status"] == "failed"
      assert failed_doc["state"]["delivery"]["error"] == "first failure"

      assert {:ok, _doc, _etag, claim_2} =
               Store.claim_delivery(id, "node-a", now: 2_000)

      assert claim_2 == %{"claim_node" => "node-a", "attempt_count" => 2}
      assert {:ok, before_stale, before_etag} = Store.get(id)

      assert {:error, :fenced} =
               Store.fail_delivery_retrying(id, claim_1, "stale failure", now: 2_100)

      assert {:ok, after_stale, after_etag} = Store.get(id)
      assert {after_stale, after_etag} == {before_stale, before_etag}
      assert after_stale["state"]["delivery"]["status"] == "delivering"
      assert after_stale["state"]["delivery"]["error"] == ""
    end

    test "a terminal Canvas failure is fenced and never becomes claimable again", %{id: id} do
      assert {:ok, _doc, _etag} = Store.create_once(id, state: %{"status" => "done"})
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, terminal, _etag} =
               Store.fail_delivery_terminal(id, claim, "canvas_unavailable", "channel_not_found",
                 now: 1_100
               )

      delivery = terminal["state"]["delivery"]
      assert delivery["status"] == "failed_terminal"
      assert delivery["failure_kind"] == "canvas_unavailable"
      assert delivery["error"] == "channel_not_found"
      refute delivery["published_at"]

      assert {:error, :not_claimable} = Store.claim_delivery(id, "node-b", now: 2_000)
    end

    test "a claim heartbeat postpones reclaim without changing its generation", %{id: id} do
      assert {:ok, _doc, _etag} =
               Store.create_once(id, state: %{"status" => "done"})

      assert {:ok, _doc, _etag, claim} =
               Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, heartbeat_doc, _etag} =
               Store.heartbeat_delivery(id, claim, now: 1_090)

      assert heartbeat_doc["state"]["delivery"]["last_attempt_at"] == 1_090

      assert {:error, :not_claimable} =
               Store.claim_delivery(id, "node-b", now: 1_120, reclaim_after_ms: 100)

      assert {:ok, _doc, _etag, replacement} =
               Store.claim_delivery(id, "node-b", now: 1_190, reclaim_after_ms: 100)

      assert replacement == %{"claim_node" => "node-b", "attempt_count" => 2}
    end

    test "a heartbeat backend crash does not kill the linked active delivery", %{id: id} do
      previous_backend = Application.get_env(:salix_store, :s3_backend)
      previous_summary = Application.get_env(:salix_meet, :summary_mod)
      previous_pid = Application.get_env(:salix_meet, :heartbeat_test_pid)
      previous_refresh = Application.get_env(:salix_meet, :delivery_claim_refresh_ms)
      previous_retry = Application.get_env(:salix_meet, :delivery_claim_refresh_retry_ms)

      start_supervised!(__MODULE__.HeartbeatCrashProbe)
      Application.put_env(:salix_store, :s3_backend, __MODULE__.HeartbeatCrashS3)
      Application.put_env(:salix_meet, :summary_mod, __MODULE__.BlockingHeartbeatSummary)
      Application.put_env(:salix_meet, :heartbeat_test_pid, self())
      Application.put_env(:salix_meet, :delivery_claim_refresh_ms, 10)
      Application.put_env(:salix_meet, :delivery_claim_refresh_retry_ms, 10)

      on_exit(fn ->
        restore_env(:salix_store, :s3_backend, previous_backend)
        restore_env(:salix_meet, :summary_mod, previous_summary)
        restore_env(:salix_meet, :heartbeat_test_pid, previous_pid)
        restore_env(:salix_meet, :delivery_claim_refresh_ms, previous_refresh)
        restore_env(:salix_meet, :delivery_claim_refresh_retry_ms, previous_retry)
      end)

      assert {:ok, _doc, _etag} =
               Store.create_once(id, state: %{"status" => "done", "provider" => "slack"})

      parent = self()

      {delivery_pid, monitor} =
        spawn_monitor(fn ->
          result = Delivery.deliver_one(id, node: "node-a", now: 1_000)
          send(parent, {:delivery_finished, self(), result})
        end)

      on_exit(fn ->
        if Process.alive?(delivery_pid), do: Process.exit(delivery_pid, :kill)
      end)

      assert_receive {:heartbeat_summary_started, summary_worker}, 1_000
      __MODULE__.HeartbeatCrashProbe.arm(self())
      assert_receive :heartbeat_backend_raised, 500

      Process.sleep(30)
      assert Process.alive?(delivery_pid)

      send(summary_worker, :finish)
      assert_receive {:delivery_finished, ^delivery_pid, :failed}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^delivery_pid, :normal}, 1_000
    end
  end

  defmodule FlipAttribution do
    @behaviour SalixMeet.Ports.OwnerAttribution

    @impl true
    def attribute(_state, summary) do
      id = Application.get_env(:salix_meet, :test_flip_owner_id, "U1")

      items =
        summary["action_items"]
        |> List.wrap()
        |> Enum.map(&Map.put(&1, "owner_slack_id", id))

      {:ok, Map.put(summary, "action_items", items)}
    end
  end

  defmodule BlockingHeartbeatSummary do
    @behaviour SalixMeet.Ports.Summary

    @impl true
    def summarize(_state), do: :skip

    @impl true
    def summarize(_state, _context) do
      test_pid = Application.fetch_env!(:salix_meet, :heartbeat_test_pid)
      send(test_pid, {:heartbeat_summary_started, self()})

      receive do
        :finish -> :skip
      end
    end
  end

  defmodule ContextSummary do
    @behaviour SalixMeet.Ports.Summary

    @impl true
    def summarize(_state), do: :skip

    @impl true
    def prepare_context(_state) do
      context = %{
        "version" => 2,
        "source" => "calibrated+chat",
        "transcript" => "[00:00] Alice: ship it\n\nIn-meeting chat:\nBob: Alice owns it",
        "captions_transcript" => "[00:00] Alice: ship the release",
        "asr_transcript" => "[00:00:01] Unknown: ship it",
        "calibration" => %{
          "mode" => "chunked",
          "complete" => true,
          "planned_chunks" => 2,
          "calibrated_chunks" => 2,
          "fallback_chunks" => 0,
          "transcript" => "must not be duplicated into the durable audit metadata"
        },
        "duration_seconds" => 301
      }

      send(Application.fetch_env!(:salix_meet, :context_test_pid), {:prepared_context, context})
      {:ok, context}
    end

    @impl true
    def summarize(_state, context) do
      send(Application.fetch_env!(:salix_meet, :context_test_pid), {:summary_context, context})

      {:ok,
       %{
         "title" => "Context test",
         "action_items" => [%{"description" => "Ship", "owner" => "Alice"}]
       }}
    end
  end

  defmodule DerivationSummary do
    @behaviour SalixMeet.Ports.Summary

    @impl true
    def summarize(_state), do: :skip

    @impl true
    def prepare_context(state) do
      context = Application.fetch_env!(:salix_meet, :summary_derivation_test_context)

      send(
        Application.fetch_env!(:salix_meet, :summary_derivation_test_pid),
        {:summary_derivation_context_prepared, state["summary"], context}
      )

      {:ok, context}
    end

    @impl true
    def summarize(state, context) do
      send(
        Application.fetch_env!(:salix_meet, :summary_derivation_test_pid),
        {:summary_derivation_called, state["summary"], context}
      )

      case Application.get_env(:salix_meet, :summary_derivation_runtime_update) do
        update when is_map(update) ->
          {:ok, _doc, _etag} =
            SalixMeet.Store.update_state_retrying(state["meeting_id"], &Map.merge(&1, update))

        _ ->
          :ok
      end

      Application.fetch_env!(:salix_meet, :summary_derivation_test_result)
    end
  end

  defmodule ControlledAttribution do
    @behaviour SalixMeet.Ports.OwnerAttribution

    @impl true
    def attribute(_state, summary), do: {:ok, summary}

    @impl true
    def attribute(state, summary, context) do
      send(
        Application.fetch_env!(:salix_meet, :summary_derivation_test_pid),
        {:summary_derivation_attribution, summary, context}
      )

      case Application.get_env(:salix_meet, :summary_derivation_attribution_runtime_update) do
        update when is_map(update) ->
          {:ok, _doc, _etag} =
            SalixMeet.Store.update_state_retrying(state["meeting_id"], &Map.merge(&1, update))

        _ ->
          :ok
      end

      case Application.get_env(:salix_meet, :summary_derivation_attribution_result, :pass) do
        :pass -> {:ok, summary}
        result -> result
      end
    end
  end

  defmodule ContextAttribution do
    @behaviour SalixMeet.Ports.OwnerAttribution

    @impl true
    def attribute(_state, summary), do: {:ok, summary}

    @impl true
    def attribute(_state, summary, context) do
      send(
        Application.fetch_env!(:salix_meet, :context_test_pid),
        {:attribution_context, context}
      )

      enriched =
        update_in(summary, ["action_items", Access.at(0)], fn item ->
          Map.put(item, "owner_slack_id", "U1")
        end)

      {:ok, enriched}
    end
  end

  defmodule RacingContextSummary do
    @behaviour SalixMeet.Ports.Summary

    @impl true
    def summarize(_state), do: :skip

    @impl true
    def prepare_context(state) do
      changed = %{
        "title" => "Changed after context preparation",
        "action_items" => [%{"description" => "Different task", "owner" => "Bob"}]
      }

      {:ok, _doc, _etag} =
        SalixMeet.Store.update_state_retrying(state["meeting_id"], fn live ->
          Map.put(live, "summary", changed)
        end)

      {:ok,
       %{
         "source" => "captions",
         "transcript" => "[00:00] Alice: the original task belongs to Alice"
       }}
    end
  end

  defmodule RacingAttribution do
    @behaviour SalixMeet.Ports.OwnerAttribution

    @impl true
    def attribute(_state, summary), do: {:ok, summary}

    @impl true
    def attribute(state, summary, _context) do
      late_summary = %{
        "title" => "Late runtime S1",
        "action_items" => [%{"description" => "Different task", "owner" => "Bob"}]
      }

      {:ok, _doc, _etag} =
        SalixMeet.Store.update_state_retrying(state["meeting_id"], fn live ->
          Map.put(live, "summary", late_summary)
        end)

      enriched =
        update_in(summary, ["action_items", Access.at(0)], fn item ->
          Map.put(item, "owner_slack_id", "U1")
        end)

      {:ok, enriched}
    end
  end

  describe "canonical owner-attribution context" do
    test "the summary and attribution consume the same checkpointed transcript", %{id: id} do
      previous_summary = Application.get_env(:salix_meet, :summary_mod)
      previous_attribution = Application.get_env(:salix_meet, :owner_attribution_mod)
      previous_pid = Application.get_env(:salix_meet, :context_test_pid)

      Application.put_env(:salix_meet, :summary_mod, ContextSummary)
      Application.put_env(:salix_meet, :owner_attribution_mod, ContextAttribution)
      Application.put_env(:salix_meet, :context_test_pid, self())

      on_exit(fn ->
        restore_env(:salix_meet, :summary_mod, previous_summary)
        restore_env(:salix_meet, :owner_attribution_mod, previous_attribution)
        restore_env(:salix_meet, :context_test_pid, previous_pid)
      end)

      state = %{"status" => "done", "provider" => "slack", "summary" => %{}}
      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, summary} = Delivery.prepare_summary_for_delivery(id, state, claim)
      assert summary["title"] == "Context test"

      assert_receive {:prepared_context, prepared}
      assert_receive {:summary_context, summary_context}
      assert_receive {:attribution_context, attribution_context}
      assert summary_context["transcript"] == attribution_context["transcript"]
      assert summary_context["source"] == attribution_context["source"]

      assert summary_context["transcript_fingerprint"] ==
               attribution_context["transcript_fingerprint"]

      assert summary_context["captions_transcript"] == prepared["captions_transcript"]
      assert summary_context["asr_transcript"] == prepared["asr_transcript"]
      assert summary_context["captions_fingerprint"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
      assert summary_context["asr_fingerprint"] =~ ~r/\Asha256:[0-9a-f]{64}\z/
      assert summary_context["duration_seconds"] == 301

      assert summary_context["calibration"] == %{
               "mode" => "chunked",
               "complete" => true,
               "planned_chunks" => 2,
               "calibrated_chunks" => 2,
               "fallback_chunks" => 0
             }

      refute Map.has_key?(summary_context["calibration"], "transcript")

      assert attribution_context["transcript"] == prepared["transcript"]
      assert attribution_context["source"] == prepared["source"]

      assert {:ok, persisted, _etag} = Store.get(id)

      checkpoint = get_in(persisted, ["state", "delivery", "owner_attribution_context"])
      assert checkpoint == attribution_context

      assert get_in(persisted, [
               "state",
               "delivery",
               "owner_attribution_v2",
               "items",
               "0",
               "user_id"
             ]) == "U1"
    end

    test "a summary changed after context preparation is checkpointed safely unresolved", %{
      id: id
    } do
      previous_summary = Application.get_env(:salix_meet, :summary_mod)
      previous_attribution = Application.get_env(:salix_meet, :owner_attribution_mod)
      previous_pid = Application.get_env(:salix_meet, :context_test_pid)

      Application.put_env(:salix_meet, :summary_mod, RacingContextSummary)
      Application.put_env(:salix_meet, :owner_attribution_mod, ContextAttribution)
      Application.put_env(:salix_meet, :context_test_pid, self())

      on_exit(fn ->
        restore_env(:salix_meet, :summary_mod, previous_summary)
        restore_env(:salix_meet, :owner_attribution_mod, previous_attribution)
        restore_env(:salix_meet, :context_test_pid, previous_pid)
      end)

      original = %{
        "title" => "Original",
        "action_items" => [%{"description" => "Original task", "owner" => "Alice"}]
      }

      state = %{"status" => "done", "provider" => "slack", "summary" => original}
      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, changed} = Delivery.prepare_summary_for_delivery(id, state, claim)
      assert changed["title"] == "Changed after context preparation"
      refute_receive {:attribution_context, _context}, 100

      assert {:ok, persisted, _etag} = Store.get(id)
      snapshot = get_in(persisted, ["state", "delivery", "owner_attribution_v2"])
      assert snapshot["status"] == "complete"
      assert snapshot["outcome"] == "unresolved"
      assert snapshot["items"] == %{}
    end

    test "a runtime update during attribution cannot replace the persisted snapshot-bound summary",
         %{
           id: id
         } do
      previous_summary = Application.get_env(:salix_meet, :summary_mod)
      previous_attribution = Application.get_env(:salix_meet, :owner_attribution_mod)

      Application.put_env(:salix_meet, :summary_mod, SalixMeet.Ports.Summary.None)
      Application.put_env(:salix_meet, :owner_attribution_mod, RacingAttribution)

      on_exit(fn ->
        restore_env(:salix_meet, :summary_mod, previous_summary)
        restore_env(:salix_meet, :owner_attribution_mod, previous_attribution)
      end)

      source = %{
        "title" => "Snapshot S0",
        "action_items" => [%{"description" => "Original task", "owner" => "Alice"}]
      }

      state = %{
        "status" => "done",
        "provider" => "slack",
        "summary" => source,
        "captions" => [%{"speaker" => "Alice", "text" => "I own the original task."}]
      }

      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, ^source} = Delivery.prepare_summary_for_delivery(id, state, claim)
      assert {:ok, persisted, _etag} = Store.get(id)
      assert persisted["state"]["summary"] == source

      snapshot = get_in(persisted, ["state", "delivery", "owner_attribution_v2"])
      assert snapshot["summary"] == source

      assert get_in(persisted, [
               "state",
               "delivery",
               "owner_attribution_context",
               "summary_fingerprint"
             ]) == SalixMeet.OwnerAttributionSnapshot.fingerprint(source)

      assert snapshot["items"]["0"] |> Map.take(~w(provider user_id display_name)) == %{
               "provider" => "slack",
               "user_id" => "U1",
               "display_name" => ""
             }
    end
  end

  describe "summary derivation checkpoint" do
    setup do
      keys = [
        :summary_mod,
        :owner_attribution_mod,
        :summary_derivation_test_pid,
        :summary_derivation_test_context,
        :summary_derivation_test_result,
        :summary_derivation_attribution_result,
        :summary_derivation_runtime_update,
        :summary_derivation_attribution_runtime_update
      ]

      previous = Map.new(keys, &{&1, Application.get_env(:salix_meet, &1)})

      Application.put_env(:salix_meet, :summary_mod, DerivationSummary)
      Application.put_env(:salix_meet, :owner_attribution_mod, ControlledAttribution)
      Application.put_env(:salix_meet, :summary_derivation_test_pid, self())
      Application.put_env(:salix_meet, :summary_derivation_test_context, derivation_context())
      Application.put_env(:salix_meet, :summary_derivation_test_result, :skip)
      Application.put_env(:salix_meet, :summary_derivation_attribution_result, :pass)

      on_exit(fn ->
        Enum.each(previous, fn {key, value} -> restore_env(:salix_meet, key, value) end)
      end)

      :ok
    end

    test "an existing runtime summary is regenerated from v2 captions and ASR", %{id: id} do
      runtime_summary = %{
        "title" => "Runtime summary",
        "action_items" => [%{"description" => "Old task", "owner" => "Unknown"}]
      }

      generated_summary = %{
        "title" => "Evidence-derived summary",
        "action_items" => [%{"description" => "Ship", "owner" => "Alice"}]
      }

      Application.put_env(
        :salix_meet,
        :summary_derivation_test_result,
        {:ok, generated_summary}
      )

      state = %{"status" => "done", "provider" => "slack", "summary" => runtime_summary}
      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, ^generated_summary} =
               Delivery.prepare_summary_for_delivery(id, state, claim)

      assert_receive {:summary_derivation_context_prepared, ^runtime_summary, prepared_context}

      assert_receive {:summary_derivation_called, ^runtime_summary, summary_context}
      assert summary_context["captions_transcript"] == prepared_context["captions_transcript"]
      assert summary_context["asr_transcript"] == prepared_context["asr_transcript"]

      assert {:ok, persisted, _etag} = Store.get(id)
      persisted_state = persisted["state"]
      persisted_context = get_in(persisted_state, ["delivery", "owner_attribution_context"])
      derivation = get_in(persisted_state, ["delivery", "summary_derivation"])

      assert persisted_state["summary"] == generated_summary
      assert derivation == summary_derivation_marker(generated_summary, persisted_context)

      assert persisted_context["summary_fingerprint"] ==
               SalixMeet.OwnerAttributionSnapshot.fingerprint(generated_summary)
    end

    test "an exact v2 derivation survives a failed claim and avoids a second model call", %{
      id: id
    } do
      runtime_summary = %{"title" => "Runtime summary", "action_items" => []}
      generated_summary = %{"title" => "First generated summary", "action_items" => []}

      Application.put_env(
        :salix_meet,
        :summary_derivation_test_result,
        {:ok, generated_summary}
      )

      Application.put_env(
        :salix_meet,
        :summary_derivation_attribution_result,
        {:error, :simulated_attribution_crash}
      )

      state = %{"status" => "done", "provider" => "slack", "summary" => runtime_summary}
      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim_1} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:error, :simulated_attribution_crash} =
               Delivery.prepare_summary_for_delivery(id, state, claim_1)

      assert_receive {:summary_derivation_context_prepared, ^runtime_summary, _context}
      assert_receive {:summary_derivation_called, ^runtime_summary, _context}
      assert_receive {:summary_derivation_attribution, ^generated_summary, _context}

      assert {:ok, after_crash, _etag} = Store.get(id)
      assert get_in(after_crash, ["state", "delivery", "summary_derivation", "version"]) == 2
      refute get_in(after_crash, ["state", "delivery", "owner_attribution_v2"])

      assert {:ok, _failed, _etag} =
               Store.fail_delivery_retrying(id, claim_1, "simulated crash", now: 1_100)

      assert {:ok, retry_doc, _etag, claim_2} =
               Store.claim_delivery(id, "node-b", now: 2_000)

      Application.put_env(
        :salix_meet,
        :summary_derivation_test_result,
        {:ok, %{"title" => "Must not be generated", "action_items" => []}}
      )

      Application.put_env(:salix_meet, :summary_derivation_attribution_result, :pass)

      assert {:ok, ^generated_summary} =
               Delivery.prepare_summary_for_delivery(id, retry_doc["state"], claim_2)

      assert_receive {:summary_derivation_attribution, ^generated_summary, _context}
      refute_receive {:summary_derivation_context_prepared, _summary, _context}
      refute_receive {:summary_derivation_called, _summary, _context}
    end

    test "a derivation whose ASR fingerprint disagrees with its v2 context regenerates", %{
      id: id
    } do
      runtime_summary = %{"title" => "Stale generated summary", "action_items" => []}
      context = bind_test_context_to_summary(derivation_context(), runtime_summary)

      stale_derivation =
        runtime_summary
        |> summary_derivation_marker(context)
        |> Map.put(
          "asr_fingerprint",
          SalixMeet.OwnerAttributionSnapshot.fingerprint("different ASR")
        )

      regenerated = %{"title" => "Regenerated summary", "action_items" => []}
      Application.put_env(:salix_meet, :summary_derivation_test_result, {:ok, regenerated})

      state = %{
        "status" => "done",
        "provider" => "slack",
        "summary" => runtime_summary,
        "delivery" => %{
          "owner_attribution_context" => context,
          "summary_derivation" => stale_derivation
        }
      }

      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, ^regenerated} = Delivery.prepare_summary_for_delivery(id, state, claim)

      refute_receive {:summary_derivation_context_prepared, _summary, _context}
      assert_receive {:summary_derivation_called, ^runtime_summary, ^context}

      assert {:ok, persisted, _etag} = Store.get(id)
      persisted_context = get_in(persisted, ["state", "delivery", "owner_attribution_context"])

      assert get_in(persisted, ["state", "delivery", "summary_derivation"]) ==
               summary_derivation_marker(regenerated, persisted_context)
    end

    test "a derivation whose meeting title input changed regenerates", %{id: id} do
      runtime_summary = %{"title" => "Stale generated summary", "action_items" => []}
      context = bind_test_context_to_summary(derivation_context(), runtime_summary)
      stale_derivation = summary_derivation_marker(runtime_summary, context, %{"title" => "Old"})
      regenerated = %{"title" => "Regenerated for new title", "action_items" => []}

      Application.put_env(:salix_meet, :summary_derivation_test_result, {:ok, regenerated})

      state = %{
        "status" => "done",
        "provider" => "slack",
        "title" => "New",
        "summary" => runtime_summary,
        "delivery" => %{
          "owner_attribution_context" => context,
          "summary_derivation" => stale_derivation
        }
      }

      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, ^regenerated} = Delivery.prepare_summary_for_delivery(id, state, claim)
      assert_receive {:summary_derivation_context_prepared, ^runtime_summary, fresh_context}
      assert_receive {:summary_derivation_called, ^runtime_summary, summary_context}
      assert summary_context["transcript"] == fresh_context["transcript"]
      assert summary_context["asr_transcript"] == fresh_context["asr_transcript"]

      assert {:ok, persisted, _etag} = Store.get(id)
      persisted_context = get_in(persisted, ["state", "delivery", "owner_attribution_context"])

      assert get_in(persisted, ["state", "delivery", "summary_derivation"]) ==
               summary_derivation_marker(regenerated, persisted_context, %{"title" => "New"})
    end

    test "runtime evidence changed during summary generation aborts the stale checkpoint", %{
      id: id
    } do
      runtime_summary = %{"title" => "Runtime summary", "action_items" => []}
      generated_summary = %{"title" => "Stale generated summary", "action_items" => []}

      initial_captions = [%{"speaker" => "Alice", "text" => "Ship the release"}]
      late_captions = [%{"speaker" => "Bob", "text" => "The release is blocked"}]

      Application.put_env(
        :salix_meet,
        :summary_derivation_test_result,
        {:ok, generated_summary}
      )

      Application.put_env(:salix_meet, :summary_derivation_runtime_update, %{
        "title" => "Late meeting title",
        "captions" => late_captions
      })

      state = %{
        "status" => "done",
        "provider" => "slack",
        "title" => "Initial meeting title",
        "captions" => initial_captions,
        "summary" => runtime_summary
      }

      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:error, :summary_source_changed} =
               Delivery.prepare_summary_for_delivery(id, state, claim)

      assert_receive {:summary_derivation_context_prepared, ^runtime_summary, _context}
      assert_receive {:summary_derivation_called, ^runtime_summary, _context}
      refute_receive {:summary_derivation_attribution, _summary, _context}

      assert {:ok, persisted, _etag} = Store.get(id)
      persisted_state = persisted["state"]

      assert persisted_state["title"] == "Late meeting title"
      assert persisted_state["captions"] == late_captions
      assert persisted_state["summary"] == runtime_summary
      refute get_in(persisted_state, ["delivery", "owner_attribution_context"])
      refute get_in(persisted_state, ["delivery", "summary_derivation"])
      refute get_in(persisted_state, ["delivery", "owner_attribution_v2"])
    end

    test "runtime evidence changed before the snapshot CAS forces context re-preparation", %{
      id: id
    } do
      runtime_summary = %{"title" => "Runtime summary", "action_items" => []}
      first_generated = %{"title" => "First generated summary", "action_items" => []}
      regenerated = %{"title" => "Regenerated from current evidence", "action_items" => []}
      initial_captions = [%{"speaker" => "Alice", "text" => "Ship the release"}]
      late_captions = [%{"speaker" => "Bob", "text" => "The release is blocked"}]

      Application.put_env(
        :salix_meet,
        :summary_derivation_test_result,
        {:ok, first_generated}
      )

      Application.put_env(:salix_meet, :summary_derivation_attribution_runtime_update, %{
        "title" => "Late meeting title",
        "captions" => late_captions
      })

      state = %{
        "status" => "done",
        "provider" => "slack",
        "title" => "Initial meeting title",
        "captions" => initial_captions,
        "summary" => runtime_summary
      }

      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim_1} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:error, :summary_source_changed} =
               Delivery.prepare_summary_for_delivery(id, state, claim_1)

      assert_receive {:summary_derivation_context_prepared, ^runtime_summary, _context}
      assert_receive {:summary_derivation_called, ^runtime_summary, _context}
      assert_receive {:summary_derivation_attribution, ^first_generated, _context}

      assert {:ok, after_race, _etag} = Store.get(id)
      assert after_race["state"]["summary"] == first_generated
      refute get_in(after_race, ["state", "delivery", "owner_attribution_v2"])

      assert {:ok, _failed, _etag} =
               Store.fail_delivery_retrying(id, claim_1, "summary source changed", now: 1_100)

      assert {:ok, retry_doc, _etag, claim_2} =
               Store.claim_delivery(id, "node-b", now: 2_000)

      Application.delete_env(:salix_meet, :summary_derivation_attribution_runtime_update)
      Application.put_env(:salix_meet, :summary_derivation_test_result, {:ok, regenerated})

      assert {:ok, ^regenerated} =
               Delivery.prepare_summary_for_delivery(id, retry_doc["state"], claim_2)

      assert_receive {:summary_derivation_context_prepared, ^first_generated, _context}
      assert_receive {:summary_derivation_called, ^first_generated, _context}
      assert_receive {:summary_derivation_attribution, ^regenerated, _context}

      assert {:ok, persisted, _etag} = Store.get(id)
      persisted_state = persisted["state"]
      assert persisted_state["summary"] == regenerated

      assert get_in(persisted_state, ["delivery", "owner_attribution_v2", "summary"]) ==
               regenerated

      context = get_in(persisted_state, ["delivery", "owner_attribution_context"])

      assert get_in(persisted_state, ["delivery", "summary_derivation"]) ==
               summary_derivation_marker(regenerated, context, persisted_state)
    end

    test "a legacy v1 owner context is refreshed before summary generation", %{id: id} do
      runtime_summary = %{"title" => "Runtime summary", "action_items" => []}
      generated_summary = %{"title" => "Fresh v2 summary", "action_items" => []}

      Application.put_env(
        :salix_meet,
        :summary_derivation_test_result,
        {:ok, generated_summary}
      )

      state = %{
        "status" => "done",
        "provider" => "slack",
        "summary" => runtime_summary,
        "delivery" => %{
          "owner_attribution_context" => %{
            "version" => 1,
            "source" => "legacy",
            "transcript" => "stale v1 transcript"
          }
        }
      }

      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, ^generated_summary} =
               Delivery.prepare_summary_for_delivery(id, state, claim)

      assert_receive {:summary_derivation_context_prepared, ^runtime_summary, fresh_context}
      assert fresh_context["version"] == 2
      assert_receive {:summary_derivation_called, ^runtime_summary, summary_context}
      assert summary_context["version"] == 2
      assert summary_context["transcript"] == fresh_context["transcript"]
      assert summary_context["asr_transcript"] == fresh_context["asr_transcript"]

      assert {:ok, persisted, _etag} = Store.get(id)

      assert get_in(persisted, ["state", "delivery", "owner_attribution_context", "version"]) ==
               2
    end

    test "a skipped summary preserves sanitized runtime content without a v2 marker", %{id: id} do
      runtime_summary = %{
        "title" => "Runtime fallback",
        "action_items" => [
          %{
            "description" => "Keep Canvas useful",
            "owner" => "Alice",
            "owner_slack_id" => "UFORGED"
          }
        ]
      }

      empty_context = %{
        "version" => 2,
        "source" => "unavailable",
        "transcript" => "",
        "captions_transcript" => "",
        "asr_transcript" => "",
        "duration_seconds" => 0
      }

      Application.put_env(:salix_meet, :summary_derivation_test_context, empty_context)
      Application.put_env(:salix_meet, :summary_derivation_test_result, :skip)

      clean_runtime = SalixMeet.OwnerAttributionSnapshot.sanitize_summary(runtime_summary)
      state = %{"status" => "done", "provider" => "slack", "summary" => runtime_summary}
      assert {:ok, _doc, _etag} = Store.create_once(id, state: state)
      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)

      assert {:ok, ^clean_runtime} = Delivery.prepare_summary_for_delivery(id, state, claim)
      assert_receive {:summary_derivation_called, ^runtime_summary, _context}

      assert {:ok, persisted, _etag} = Store.get(id)
      persisted_state = persisted["state"]
      persisted_context = get_in(persisted_state, ["delivery", "owner_attribution_context"])

      assert persisted_state["summary"] == clean_runtime
      refute get_in(persisted_state, ["delivery", "summary_derivation"])

      assert persisted_context["summary_fingerprint"] ==
               SalixMeet.OwnerAttributionSnapshot.fingerprint(clean_runtime)
    end
  end

  describe "owner attribution checkpoint" do
    setup %{id: id} do
      prev_mod = Application.get_env(:salix_meet, :owner_attribution_mod)
      Application.put_env(:salix_meet, :owner_attribution_mod, FlipAttribution)
      Application.put_env(:salix_meet, :test_flip_owner_id, "U1")

      on_exit(fn ->
        restore_env(:salix_meet, :owner_attribution_mod, prev_mod)
        Application.delete_env(:salix_meet, :test_flip_owner_id)
      end)

      assert {:ok, _doc, _etag} =
               Store.create_once(id, state: %{"status" => "done", "provider" => "slack"})

      assert {:ok, _doc, _etag, claim} = Store.claim_delivery(id, "node-a", now: 1_000)
      {:ok, claim: claim}
    end

    test "attributes once into delivery state and reuses the immutable checkpoint",
         %{id: id, claim: claim} do
      state = %{"status" => "done", "provider" => "slack"}
      summary = %{"action_items" => [%{"description" => "x", "owner" => "Alice"}]}

      assert {:ok, clean} =
               Delivery.prepare_summary_for_delivery(
                 id,
                 Map.put(state, "summary", summary),
                 claim
               )

      refute Map.has_key?(hd(clean["action_items"]), "owner_slack_id")
      refute Map.has_key?(clean, "owner_attribution_done")

      assert {:ok, first, _etag} = Store.get(id)

      assert get_in(first, ["state", "delivery", "owner_attribution_v2", "items", "0", "user_id"]) ==
               "U1"

      # A real retry would re-run a nondeterministic LLM; force a different
      # mapping and confirm the checkpoint wins so Canvas/notice/activation stay
      # consistent instead of flipping U1 -> U2 under an already-written Canvas.
      Application.put_env(:salix_meet, :test_flip_owner_id, "U2")

      assert {:ok, reused} =
               Delivery.prepare_summary_for_delivery(
                 id,
                 Map.put(state, "summary", clean),
                 claim
               )

      refute Map.has_key?(hd(reused["action_items"]), "owner_slack_id")

      assert {:ok, persisted, _etag} = Store.get(id)

      refute Map.has_key?(
               hd(persisted["state"]["summary"]["action_items"]),
               "owner_slack_id"
             )

      assert get_in(persisted, [
               "state",
               "delivery",
               "owner_attribution_v2",
               "items",
               "0",
               "user_id"
             ]) == "U1"
    end

    test "nil and empty summaries still checkpoint a completed unresolved snapshot", %{id: id} do
      previous_summary = Application.get_env(:salix_meet, :summary_mod)
      Application.put_env(:salix_meet, :summary_mod, SalixMeet.Ports.Summary.None)

      on_exit(fn -> restore_env(:salix_meet, :summary_mod, previous_summary) end)

      for {suffix, summary} <- [{"nil", nil}, {"empty", %{}}] do
        meeting_id = "#{id}-#{suffix}"

        state =
          %{"status" => "done", "provider" => "slack"}
          |> Map.put("summary", summary)

        assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state)

        assert {:ok, _doc, _etag, claim} =
                 Store.claim_delivery(meeting_id, "node-a", now: 1_000)

        assert {:ok, prepared} =
                 Delivery.prepare_summary_for_delivery(meeting_id, state, claim)

        assert prepared in [nil, %{}]
        assert {:ok, persisted, _etag} = Store.get(meeting_id)
        snapshot = get_in(persisted, ["state", "delivery", "owner_attribution_v2"])
        assert snapshot["status"] == "complete"
        assert snapshot["outcome"] == "unresolved"
        assert snapshot["summary"] == %{}
        assert SalixMeet.OwnerAttributionSnapshot.complete?(snapshot)
      end
    end
  end

  describe "post-publication activation claims" do
    test "a rolling old worker's terminal normal summary is upgraded atomically", %{id: id} do
      assert {:ok, _doc, _etag} =
               Store.create_once(id,
                 state: %{
                   "status" => "done",
                   "delivery" => %{
                     "status" => "failed_terminal",
                     "failure_kind" => "canvas_unavailable",
                     "summary_message_ts" => "111.legacy",
                     "summary_message_kind" => "summary"
                   }
                 }
               )

      assert {:ok, :activation, claimed_doc, _etag, claim} =
               Store.claim_terminal_work(id, "node-a", now: 1_000)

      delivery = claimed_doc["state"]["delivery"]

      assert delivery["notes_delivery"] == %{
               "status" => "visible",
               "surface" => "canvas_link_message",
               "kind" => "summary",
               "message_ts" => "111.legacy",
               "visible_at" => 1
             }

      assert delivery["activation"]["status"] == "activating"
      assert claim == %{"claim_node" => "node-a", "attempt_count" => 1}
    end

    test "a pre-multipart worker's hash-confirmed single fallback remains activatable", %{id: id} do
      assert {:ok, _doc, _etag} =
               Store.create_once(id,
                 state: %{
                   "status" => "done",
                   "delivery" => %{
                     "status" => "failed_terminal",
                     "failure_kind" => "canvas_unavailable",
                     "summary_message_ts" => "111.legacy-fallback",
                     "summary_message_kind" => "canvas_failure",
                     "message_post" => %{
                       "kind" => "canvas_failure",
                       "content_kind" => "summary_fallback_v1",
                       "content_sha256" => "legacy-content-hash",
                       "confirmed_content_sha256" => "legacy-content-hash",
                       "event_type" => FallbackMessageManifest.part_event_type(id, 1),
                       "status" => "created"
                     },
                     "notes_delivery" => %{
                       "status" => "visible",
                       "surface" => "message_fallback",
                       "kind" => "summary_fallback",
                       "message_ts" => "111.legacy-fallback"
                     },
                     "activation" => %{"status" => "pending", "attempt_count" => 0}
                   }
                 }
               )

      assert {:ok, :activation, _doc, _etag, claim} =
               Store.claim_terminal_work(id, "node-a", now: 1_000)

      assert claim == %{"claim_node" => "node-a", "attempt_count" => 1}
    end

    test "a terminal Canvas fallback activates only after durable full notes are visible", %{
      id: id
    } do
      assert {:ok, _doc, _etag} =
               Store.create_once(id,
                 state: %{
                   "status" => "done",
                   "delivery" => fallback_delivery(id, notes_visible: true)
                 }
               )

      assert {:ok, :activation, _doc, _etag, claim} =
               Store.claim_terminal_work(id, "node-a", now: 1_000)

      assert claim == %{"claim_node" => "node-a", "attempt_count" => 1}
      assert {:ok, completed, _etag} = Store.complete_activation(id, claim, :queued, now: 1_010)
      assert get_in(completed, ["state", "delivery", "activation", "status"]) == "queued"
      refute get_in(completed, ["state", "delivery", "published_at"])
    end

    test "a forged fallback visibility checkpoint cannot activate", %{id: id} do
      assert {:ok, _doc, _etag} =
               Store.create_once(id,
                 state: %{
                   "status" => "done",
                   "delivery" => %{
                     "status" => "failed_terminal",
                     "failure_kind" => "canvas_unavailable",
                     "summary_message_ts" => "111.forged",
                     "summary_message_kind" => "canvas_failure",
                     "notes_delivery" => %{
                       "status" => "visible",
                       "surface" => "message_fallback",
                       "kind" => "summary_fallback",
                       "message_ts" => "111.forged"
                     },
                     "activation" => %{"status" => "pending", "attempt_count" => 0}
                   }
                 }
               )

      refute Store.activation_delivery_ready?(
               %{
                 "status" => "failed_terminal",
                 "summary_message_ts" => "111.forged",
                 "summary_message_kind" => "canvas_failure",
                 "notes_delivery" => %{
                   "status" => "visible",
                   "surface" => "message_fallback",
                   "kind" => "summary_fallback",
                   "message_ts" => "111.forged"
                 }
               },
               id
             )

      assert {:error, :not_claimable} = Store.claim_activation(id, "node-a", now: 1_000)
    end

    test "a malformed fallback block fails closed instead of crashing activation", %{id: id} do
      delivery = fallback_delivery(id, notes_visible: true)

      assert Store.activation_delivery_ready?(delivery, id)
      refute Store.activation_delivery_ready?(delivery, id <> "-other-meeting")

      refute Store.activation_delivery_ready?(
               Map.put(delivery, "fallback_message_manifest", "bad-manifest"),
               id
             )

      [valid_block] =
        get_in(delivery, ["fallback_message_manifest", "parts", Access.at(0), "blocks"])

      refute Store.activation_delivery_ready?(
               put_in(
                 delivery,
                 ["fallback_message_manifest", "parts", Access.at(0), "blocks"],
                 valid_block
               ),
               id
             )

      malformed =
        delivery
        |> put_in(["fallback_message_manifest", "parts", Access.at(0), "blocks"], ["bad-block"])
        |> put_in(["message_post", "blocks"], ["bad-block"])

      refute Store.activation_delivery_ready?(malformed, id)

      assert {:ok, _doc, _etag} =
               Store.create_once(id, state: %{"status" => "done", "delivery" => malformed})

      assert {:error, :not_claimable} = Store.claim_terminal_work(id, "node-a", now: 1_000)

      bad_counter_id = id <> "-bad-counter"

      bad_counter =
        bad_counter_id
        |> fallback_delivery(part_status: "posting")
        |> put_in(
          ["fallback_message_manifest", "parts", Access.at(0), "post_attempts"],
          "bad-counter"
        )
        |> put_in(["message_post", "post_attempts"], "bad-counter")

      assert {:ok, _doc, _etag} =
               Store.create_once(bad_counter_id,
                 state: %{"status" => "done", "delivery" => bad_counter}
               )

      assert {:error, :not_claimable} =
               Store.claim_terminal_work(bad_counter_id, "node-a", now: 1_000)
    end

    test "a rolling old worker's terminal fallback manifest is reclaimed for repair", %{id: id} do
      for {suffix, part_status} <- [{"incomplete", "posting"}, {"confirmed", "created"}] do
        meeting_id = "#{id}-#{suffix}"

        assert {:ok, _doc, _etag} =
                 Store.create_once(meeting_id,
                   state: %{
                     "status" => "done",
                     "delivery" => fallback_delivery(meeting_id, part_status: part_status)
                   }
                 )

        assert {:ok, :delivery, claimed, _etag, claim} =
                 Store.claim_terminal_work(meeting_id, "node-a", now: 1_000)

        assert claimed["state"]["delivery"]["status"] == "delivering"
        assert claim == %{"claim_node" => "node-a", "attempt_count" => 1}
      end
    end

    test "a conflicted or abandoned terminal fallback manifest is not reclaimed", %{id: id} do
      for part_status <- ["conflict", "abandoned"] do
        meeting_id = "#{id}-#{part_status}"

        assert {:ok, _doc, _etag} =
                 Store.create_once(meeting_id,
                   state: %{
                     "status" => "done",
                     "delivery" => fallback_delivery(meeting_id, part_status: part_status)
                   }
                 )

        assert {:error, :not_claimable} =
                 Store.claim_terminal_work(meeting_id, "node-a", now: 1_000)
      end
    end

    test "a thin Canvas warning or retryable link message cannot activate", %{id: id} do
      assert {:ok, _doc, _etag} =
               Store.create_once(id,
                 state: %{
                   "status" => "done",
                   "delivery" => %{
                     "status" => "failed_terminal",
                     "failure_kind" => "canvas_unavailable",
                     "summary_message_ts" => "111.thin",
                     "summary_message_kind" => "canvas_failure",
                     "activation" => %{"status" => "pending", "attempt_count" => 0}
                   }
                 }
               )

      assert {:error, :not_claimable} = Store.claim_activation(id, "node-a", now: 1_000)

      assert {:ok, _doc, _etag} =
               Store.update_state_retrying(id, fn state ->
                 Map.put(state, "delivery", %{
                   "status" => "failed",
                   "summary_message_ts" => "222.retryable",
                   "summary_message_kind" => "summary",
                   "activation" => %{"status" => "pending", "attempt_count" => 0}
                 })
               end)

      assert {:error, :not_claimable} = Store.claim_activation(id, "node-b", now: 2_000)
    end

    test "a terminal activation costs one state read per delivery pass", %{id: id} do
      assert {:ok, _doc, _etag} =
               Store.create_once(id,
                 state: %{
                   "status" => "done",
                   "delivery" => %{
                     "status" => "published",
                     "published_at" => 1,
                     "activation" => %{"status" => "queued", "attempt_count" => 1}
                   }
                 }
               )

      start_supervised!(CountingS3Counter)
      Application.put_env(:salix_store, :s3_backend, CountingS3)

      assert :not_claimable = Delivery.deliver_one(id, node: "node-a", now: 1_000)
      assert CountingS3Counter.value() == 1
    end

    test "activation retries are independently fenced and terminal completion is stable", %{
      id: id
    } do
      assert {:ok, _doc, _etag} =
               Store.create_once(id,
                 state: %{
                   "status" => "done",
                   "delivery" => %{
                     "status" => "published",
                     "published_at" => 1,
                     "activation" => %{
                       "status" => "pending",
                       "attempt_count" => 0,
                       "updated_at" => 1
                     }
                   }
                 }
               )

      assert {:ok, :activation, _doc, _etag, claim_1} =
               Store.claim_terminal_work(id, "node-a", now: 1_000, reclaim_after_ms: 100)

      assert claim_1 == %{"claim_node" => "node-a", "attempt_count" => 1}

      assert {:error, :not_claimable} =
               Store.claim_terminal_work(id, "node-b", now: 1_050, reclaim_after_ms: 100)

      assert {:ok, :activation, _doc, _etag, claim_2} =
               Store.claim_terminal_work(id, "node-b", now: 1_100, reclaim_after_ms: 100)

      assert claim_2 == %{"claim_node" => "node-b", "attempt_count" => 2}
      assert {:error, :fenced} = Store.complete_activation(id, claim_1, :queued, now: 1_110)

      assert {:ok, failed_doc, _etag} =
               Store.fail_activation_retrying(id, claim_2, "temporary", now: 1_120)

      assert get_in(failed_doc, ["state", "delivery", "activation", "status"]) == "failed"

      assert {:ok, :activation, _doc, _etag, claim_3} =
               Store.claim_terminal_work(id, "node-c", now: 1_130, reclaim_after_ms: 100)

      assert claim_3 == %{"claim_node" => "node-c", "attempt_count" => 3}

      assert {:ok, completed_doc, _etag} =
               Store.complete_activation(id, claim_3, :queued, now: 1_140)

      assert get_in(completed_doc, ["state", "delivery", "activation", "status"]) == "queued"
      assert get_in(completed_doc, ["state", "delivery", "activation", "attempt_count"]) == 3
      assert {:error, :not_claimable} = Store.claim_terminal_work(id, "node-d", now: 9_999)

      assert {:error, :fenced} =
               Store.fail_activation_retrying(id, claim_3, "late failure", now: 10_000)
    end

    test "expired activation is terminally skipped and no longer reclaimed", %{id: id} do
      previous_activation = Application.get_env(:salix_meet, :activation_mod)
      Application.put_env(:salix_meet, :activation_mod, ExpiredActivation)
      on_exit(fn -> restore_env(:salix_meet, :activation_mod, previous_activation) end)

      assert {:ok, _doc, _etag} =
               Store.create_once(id,
                 state: %{
                   "status" => "done",
                   "summary" => %{"action_items" => [%{"description" => "Ship"}]},
                   "delivery" => %{
                     "status" => "published",
                     "published_at" => 1,
                     "activation" => %{
                       "status" => "pending",
                       "attempt_count" => 0,
                       "updated_at" => 1
                     }
                   }
                 }
               )

      assert :activation_skipped = Delivery.deliver_one(id, node: "node-a", now: 1_000)
      assert {:ok, completed, _etag} = Store.get(id)
      activation = get_in(completed, ["state", "delivery", "activation"])
      assert activation["status"] == "skipped"
      assert activation["attempt_count"] == 1

      assert :not_claimable = Delivery.deliver_one(id, node: "node-b", now: 9_999)
      assert {:ok, stable, _etag} = Store.get(id)
      assert get_in(stable, ["state", "delivery", "activation", "attempt_count"]) == 1
    end

    test "legacy published records without an activation marker are not backfilled", %{id: id} do
      assert {:ok, _doc, _etag} =
               Store.create_once(id,
                 state: %{
                   "status" => "done",
                   "delivery" => %{"status" => "published", "published_at" => 1}
                 }
               )

      assert {:error, :not_claimable} = Store.claim_activation(id, "node-a", now: 1_000)
    end
  end

  describe "Meeting GenServer" do
    test "becomes leader and holds it; join is at-most-once", %{id: id} do
      {:ok, _pid} = SalixMeet.Application.start_meeting(id, node: "node-a", interval_ms: 50)

      assert eventually(fn -> Meeting.leader?(id) end)

      assert {:ok, ts} = Meeting.join(id)
      assert is_integer(ts)
      assert [%{"id" => ^id}] = RuntimeDriver.calls()

      # Re-join is idempotent: same timestamp.
      assert {:ok, ^ts} = Meeting.join(id)
      assert [_] = RuntimeDriver.calls()

      # A competing node cannot claim while the leader's lease is live.
      {:ok, _doc, etag} = Store.get(id)
      assert {:error, {:held_by, "node-a", _}} = Store.claim_leader(id, "node-b", etag)
    end
  end

  defp fallback_delivery(meeting_id, opts) do
    part_status = Keyword.get(opts, :part_status, "created")
    text = "*Meeting summary*\n\nComplete fallback notes"
    content_sha256 = Crypto.hex(text)
    event_type = FallbackMessageManifest.part_event_type(meeting_id, 1)
    message_ts = if part_status == "created", do: "111.222", else: ""

    blocks = [
      %{
        "type" => "section",
        "block_id" => "comma_meeting_fallback_#{binary_part(content_sha256, 0, 16)}_1",
        "text" => %{"type" => "mrkdwn", "text" => text, "verbatim" => true}
      }
    ]

    blocks_sha256 = Crypto.hex(Jason.encode!(blocks))

    part = %{
      "index" => 1,
      "part_count" => 1,
      "kind" => "canvas_failure",
      "content_kind" => "summary_fallback_v1",
      "content_sha256" => content_sha256,
      "text" => text,
      "blocks" => blocks,
      "blocks_sha256" => blocks_sha256,
      "event_type" => event_type,
      "metadata" => %{
        "event_type" => event_type,
        "event_payload" => %{
          "meeting_id" => meeting_id,
          "kind" => "canvas_failure",
          "content_kind" => "summary_fallback_v1",
          "content_sha256" => content_sha256,
          "part_index" => 1,
          "part_count" => 1
        }
      },
      "status" => part_status,
      "started_at" => 1,
      "post_attempts" => 1,
      "reconcile_attempts" => 0
    }

    part =
      if part_status == "created" do
        part
        |> Map.put("message_ts", message_ts)
        |> Map.put("confirmed_content_sha256", content_sha256)
        |> Map.put("provider_payload_sha256", blocks_sha256)
        |> Map.put("content_proof", "exact_blocks")
      else
        part
      end

    manifest = %{
      "version" => 1,
      "content_kind" => "summary_fallback_v1",
      "content_sha256" => content_sha256,
      "part_count" => 1,
      "status" => if(part_status == "created", do: "confirmed", else: "posting"),
      "parts" => [part]
    }

    delivery = %{
      "status" => "failed_terminal",
      "failure_kind" => "canvas_unavailable",
      "summary_message_ts" => message_ts,
      "summary_message_kind" => "canvas_failure",
      "message_post" => part,
      "fallback_message_manifest" => manifest,
      "activation" => %{"status" => "pending", "attempt_count" => 0, "updated_at" => 1}
    }

    if Keyword.get(opts, :notes_visible, false) do
      Map.put(delivery, "notes_delivery", %{
        "status" => "visible",
        "surface" => "message_fallback",
        "kind" => "summary_fallback",
        "message_ts" => message_ts,
        "manifest_content_sha256" => content_sha256,
        "part_count" => 1
      })
    else
      delivery
    end
  end

  defp derivation_context do
    %{
      "version" => 2,
      "source" => "calibrated",
      "transcript" => "[00:00:00] Alice: ship the release",
      "captions_transcript" => "[00:00] Alice: ship release",
      "asr_transcript" => "[00:00:00] Unknown: ship the release",
      "duration_seconds" => 120
    }
  end

  defp bind_test_context_to_summary(context, summary) do
    context
    |> Map.put(
      "transcript_fingerprint",
      SalixMeet.OwnerAttributionSnapshot.fingerprint(context["transcript"])
    )
    |> Map.put(
      "captions_fingerprint",
      SalixMeet.OwnerAttributionSnapshot.fingerprint(context["captions_transcript"])
    )
    |> Map.put(
      "asr_fingerprint",
      SalixMeet.OwnerAttributionSnapshot.fingerprint(context["asr_transcript"])
    )
    |> Map.put(
      "summary_fingerprint",
      SalixMeet.OwnerAttributionSnapshot.fingerprint(summary)
    )
  end

  defp summary_derivation_marker(summary, context, state \\ %{}) do
    %{
      "version" => 2,
      "kind" => "meeting_summary",
      "input_fingerprint" => summary_source_fingerprint(state, context),
      "canonical_fingerprint" =>
        SalixMeet.OwnerAttributionSnapshot.fingerprint(context["transcript"]),
      "captions_fingerprint" =>
        SalixMeet.OwnerAttributionSnapshot.fingerprint(context["captions_transcript"]),
      "asr_fingerprint" =>
        SalixMeet.OwnerAttributionSnapshot.fingerprint(context["asr_transcript"]),
      "summary_fingerprint" => SalixMeet.OwnerAttributionSnapshot.fingerprint(summary)
    }
  end

  defp summary_source_fingerprint(state, context) do
    artifacts = stringify(state["artifacts"] || %{})

    SalixMeet.OwnerAttributionSnapshot.fingerprint(%{
      "title" => String.trim(to_string(state["title"] || "")),
      "meeting_agent_id" => String.trim(to_string(state["meeting_agent_id"] || "")),
      "captions" => List.wrap(state["captions"]),
      "chats" => List.wrap(state["chats"]),
      "artifacts" => Map.take(artifacts, ~w(audio transcript)),
      "joined_at" => state["joined_at"],
      "left_at" => state["left_at"],
      "duration_seconds" => context["duration_seconds"] || 0
    })
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp stop_all_meetings do
    if Process.whereis(SalixMeet.MeetingSup) do
      SalixMeet.MeetingSup
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(SalixMeet.MeetingSup, pid)
      end)
    end

    :ok
  end
end
