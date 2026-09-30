defmodule SalixMeetTest do
  @moduledoc """
  `SalixMeet.list_group_meetings/1`: the compact meeting-record listing the
  dashboard reads over erpc — group-scoped, newest first, and stripped of
  runtime internals (tokens, leases, raw captions).
  """
  use ExUnit.Case, async: false

  alias SalixMeet.{FallbackMessageManifest, Store}
  alias SalixStore.{Keys, MeetingGroupProjectionReadiness, MeetingGroupProjections, Repo}

  # A backend whose GET latency is paid by the CALLING process, so a sequential
  # reader spends 30 x @get_latency_ms while a concurrent one does not. The
  # shared `SalixStore.S3.Fake` `{:delay, ...}` fault sleeps inside its own
  # GenServer and would serialize every reader, which cannot show the difference.
  defmodule SlowGetBackend do
    @get_latency_ms 40

    def latency_ms, do: @get_latency_ms

    def get(key, opts) do
      Process.sleep(@get_latency_ms)
      SalixStore.S3.Fake.get(key, opts)
    end

    defdelegate put(key, body, opts), to: SalixStore.S3.Fake
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: SalixStore.S3.Fake
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
    defdelegate stream(key, opts), to: SalixStore.S3.Fake
    defdelegate head(key), to: SalixStore.S3.Fake
    defdelegate delete(key, opts), to: SalixStore.S3.Fake
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake
  end

  defmodule ContextGetBackend do
    @moduledoc false

    def get(key, opts) do
      send(
        Application.fetch_env!(:salix_meet, :context_test_owner),
        {:meeting_state_read_surface, SystemsObservability.Context.current_surface()}
      )

      SalixStore.S3.Fake.get(key, opts)
    end

    defdelegate put(key, body, opts), to: SalixStore.S3.Fake
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: SalixStore.S3.Fake
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
    defdelegate stream(key, opts), to: SalixStore.S3.Fake
    defdelegate head(key), to: SalixStore.S3.Fake
    defdelegate delete(key, opts), to: SalixStore.S3.Fake
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake
  end

  setup do
    prev_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()
    Repo.query!("TRUNCATE meeting_group_projections")
    :ok = MeetingGroupProjections.mark_ready(%{"mode" => "test"})
    :ok = MeetingGroupProjectionReadiness.refresh()

    on_exit(fn ->
      if prev_s3 do
        Application.put_env(:salix_store, :s3_backend, prev_s3)
      else
        Application.delete_env(:salix_store, :s3_backend)
      end
    end)

    :ok
  end

  test "public records expose bounded outcome text without raw provider errors" do
    create_meeting!("mtg-refused", "group-reasons", %{
      "status" => "failed",
      "reason_code" => "admission_denied",
      "error" => "private-runtime-detail"
    })

    assert {:ok, [record]} = SalixMeet.list_group_meetings("group-reasons")
    assert record["reason_code"] == "admission_denied"
    assert record["reason_message"] == "入会请求被拒绝。"
    refute inspect(record) =~ "private-runtime-detail"
  end

  test "lists only the group's meetings, newest first, as compact records" do
    create_meeting!("mtg-old", "group-a", %{
      "title" => "Weekly sync",
      "status" => "done",
      "start_at" => 1_000,
      "runtime_token" => "secret-token",
      "captions" => [%{"speaker" => "Ann", "text" => "hi"}],
      "artifacts" => %{"transcript" => %{"path" => "/meetings/mtg-old/transcript.txt"}},
      "summary" => %{
        "title" => "Weekly sync",
        "key_points" => ["Shipped v2"],
        "action_items" => [%{"description" => "Send notes", "owner" => "Ann"}]
      },
      "delivery" => %{
        "status" => "failed_terminal",
        "failure_kind" => "canvas_unavailable",
        "error" => "channel_not_found",
        "canvas_url" => "https://example.slack.com/docs/T/F-CANVAS",
        "canvas_url_source" => "derived",
        "canvas_create" => %{"canvas_id" => "F-CANVAS", "status" => "v3_ready"},
        "canvas_link" => %{"status" => "resolved"},
        "canvas_access" => %{"status" => "abandoned"}
      },
      "slack_ref" => %{"channel_id" => "C123", "thread_ts" => "111.222"}
    })

    create_meeting!("mtg-new", "group-a", %{
      "title" => "Design review",
      "status" => "active",
      "start_at" => 2_000,
      "error" => "runtime-secret-sentinel",
      "delivery" => %{"failure_kind" => "hostile-secret-sentinel"}
    })

    create_meeting!("mtg-other", "group-b", %{"title" => "Other group", "start_at" => 3_000})

    assert {:ok, [newest, oldest]} = SalixMeet.list_group_meetings("group-a")

    assert newest["meeting_id"] == "mtg-new"
    assert newest["status"] == "active"
    assert newest["delivery_failure_kind"] == nil
    assert newest["notes_delivery_status"] == nil
    assert newest["notes_delivery_surface"] == nil
    refute Map.has_key?(newest, "error")
    refute inspect(newest) =~ "runtime-secret-sentinel"
    refute inspect(newest) =~ "hostile-secret-sentinel"

    assert oldest["meeting_id"] == "mtg-old"
    assert oldest["title"] == "Weekly sync"
    assert oldest["captions_count"] == 1
    assert oldest["artifacts"] == ["transcript"]

    assert oldest["summary"]["action_items"] == [
             %{"description" => "Send notes", "owner" => "Ann"}
           ]

    assert oldest["slack_channel_id"] == "C123"
    assert oldest["delivery_status"] == "failed_terminal"
    assert oldest["delivery_failure_kind"] == "canvas_unavailable"
    assert oldest["notes_delivery_status"] == "unavailable"
    assert oldest["notes_delivery_surface"] == nil
    assert oldest["canvas_id"] == "F-CANVAS"
    assert oldest["canvas_create_status"] == "created"
    assert oldest["canvas_url"] == "https://example.slack.com/docs/T/F-CANVAS"
    assert oldest["canvas_url_source"] == "derived"
    assert oldest["canvas_link_status"] == "resolved"
    assert oldest["canvas_access_status"] == "unavailable"
    refute Map.has_key?(oldest, "delivery_error")

    # Runtime internals never cross the boundary.
    refute Map.has_key?(oldest, "runtime_token")
    refute Map.has_key?(oldest, "captions")
  end

  test "returns an empty list for a group with no meetings" do
    assert {:ok, []} = SalixMeet.list_group_meetings("group-empty")
  end

  test "normalizes internal Canvas state-machine values at the public boundary" do
    create_meeting!("mtg-canvas-public", "group-canvas-public", %{
      "delivery" => %{
        "canvas_url_source" => "future-internal-source",
        "canvas_create" => %{"status" => "v2_fallback_unknown"},
        "canvas_link" => %{"status" => "pending"},
        "canvas_access" => %{"status" => "v2_link_shared"}
      }
    })

    assert {:ok, [meeting]} = SalixMeet.list_group_meetings("group-canvas-public")
    assert meeting["canvas_create_status"] == "reconciling"
    assert meeting["canvas_link_status"] == "resolving"
    assert meeting["canvas_access_status"] == "link_shared"
    assert meeting["canvas_url_source"] == "unknown"
  end

  test "reports a rolling old worker's terminal normal summary as visible notes" do
    create_meeting!("mtg-legacy-terminal-summary", "group-legacy-terminal-summary", %{
      "status" => "done",
      "delivery" => %{
        "status" => "failed_terminal",
        "failure_kind" => "canvas_unavailable",
        "summary_message_ts" => "111.legacy",
        "summary_message_kind" => "summary"
      }
    })

    assert {:ok, [meeting]} =
             SalixMeet.list_group_meetings("group-legacy-terminal-summary")

    assert meeting["notes_delivery_status"] == "visible"
    assert meeting["notes_delivery_surface"] == "canvas_link_message"
    refute meeting["published_at"]
  end

  test "preserves a pre-multipart worker's hash-confirmed single fallback as visible" do
    create_meeting!("mtg-legacy-single-fallback", "group-legacy-single-fallback", %{
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
          "event_type" =>
            FallbackMessageManifest.part_event_type("mtg-legacy-single-fallback", 1),
          "status" => "created"
        },
        "notes_delivery" => %{
          "status" => "visible",
          "surface" => "message_fallback",
          "kind" => "summary_fallback",
          "message_ts" => "111.legacy-fallback"
        }
      }
    })

    assert {:ok, [meeting]} = SalixMeet.list_group_meetings("group-legacy-single-fallback")
    assert meeting["notes_delivery_status"] == "visible"
    assert meeting["notes_delivery_surface"] == "message_fallback"
  end

  test "does not expose a forged fallback visibility checkpoint without content proof" do
    create_meeting!("mtg-forged-fallback", "group-forged-fallback", %{
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
        }
      }
    })

    assert {:ok, [meeting]} = SalixMeet.list_group_meetings("group-forged-fallback")
    assert meeting["notes_delivery_status"] == "unavailable"
    assert meeting["notes_delivery_surface"] == nil
  end

  test "group reads do not amplify with unrelated meeting volume" do
    create_meeting!("mtg-target", "group-target", %{"title" => "Target", "start_at" => 1})

    for ordinal <- 1..120 do
      create_meeting!("mtg-unrelated-#{ordinal}", "group-unrelated-#{ordinal}", %{
        "title" => "Unrelated #{ordinal}",
        "start_at" => ordinal
      })
    end

    SalixStore.S3.Fake.reset_read_log()

    assert {:ok,
            %{
              "meetings" => [%{"meeting_id" => "mtg-target"}],
              "completeness" => "complete"
            }} =
             SalixMeet.list_group_meetings_bounded("group-target", limit: 50, deadline_ms: 500)

    reads = SalixStore.S3.Fake.read_log()
    target_key = Keys.meet_state("mtg-target")

    refute Enum.any?(reads, &match?({:list, "meet/", _opts}, &1))
    assert Enum.count(reads, &(&1 == {:get, target_key})) == 1

    refute Enum.any?(reads, fn
             {:get, "meet/mtg-unrelated-" <> _rest} -> true
             _other -> false
           end)
  end

  test "exact group meeting reads are projection-scoped and fail closed across groups" do
    create_meeting!("mtg-exact", "group-exact", %{
      "title" => "Exact meeting",
      "status" => "done",
      "summary" => %{"key_points" => ["bounded"]},
      "artifacts" => %{"transcript" => %{"path" => "/meeting/transcript.txt"}}
    })

    SalixStore.S3.Fake.reset_read_log()

    assert {:ok,
            %{
              "meeting_id" => "mtg-exact",
              "title" => "Exact meeting",
              "artifacts" => ["transcript"]
            }} =
             SalixMeet.get_group_meeting_bounded("group-exact", "mtg-exact", deadline_ms: 500)

    refute Enum.any?(SalixStore.S3.Fake.read_log(), &match?({:list, _prefix, _opts}, &1))

    assert {:error, :not_found} =
             SalixMeet.get_group_meeting_bounded("group-other", "mtg-exact", deadline_ms: 500)

    assert {:error, :not_found} =
             SalixMeet.get_group_meeting_bounded("group-exact", "mtg-missing", deadline_ms: 500)
  end

  test "labelled exact reads preserve public JSON and use the same group ownership gate" do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    connect_id = "meeting-ifc-exact"

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_group(group_id), %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "router_conversation_id" => SalixStore.Ids.new_conversation_id(),
        "ifc" => %{"mode" => "enforce"}
      })

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "connect_id" => connect_id,
        "provider" => "slack"
      })

    SalixStore.IFC.observe_scope(tenant_id, group_id, connect_id, "C_MEETING", %{kind: "public"})

    create_meeting!("mtg-ifc-exact", group_id, %{
      "tenant_id" => tenant_id,
      "connect_id" => connect_id,
      "provider" => "slack",
      "status" => "done",
      "summary" => %{"key_points" => ["Published notes"]},
      "slack_ref" => %{"channel_id" => "C_MEETING"},
      "delivery" => %{"status" => "published", "published_at" => 123}
    })

    assert {:ok, plain} = SalixMeet.get_group_meeting_bounded(group_id, "mtg-ifc-exact")

    assert {:ok, ^plain, %{"label" => ["space|meeting-ifc-exact"]}} =
             SalixMeet.get_group_meeting_bounded(group_id, "mtg-ifc-exact", with_ifc: true)

    refute Map.has_key?(plain, "ifc")
    refute Map.has_key?(plain, "connect_id")

    assert {:error, :not_found} =
             SalixMeet.get_group_meeting_bounded("other-group", "mtg-ifc-exact", with_ifc: true)

    assert {:error, :invalid} =
             SalixMeet.get_group_meeting_bounded(group_id, "mtg-ifc-exact", with_ifc: "yes")
  end

  test "bounded state reads preserve observability context in async workers" do
    group_id = "group-context"
    create_meeting!("mtg-context", group_id, %{"start_at" => 1})

    previous_owner = Application.get_env(:salix_meet, :context_test_owner)
    Application.put_env(:salix_meet, :context_test_owner, self())
    Application.put_env(:salix_store, :s3_backend, ContextGetBackend)

    on_exit(fn ->
      if previous_owner,
        do: Application.put_env(:salix_meet, :context_test_owner, previous_owner),
        else: Application.delete_env(:salix_meet, :context_test_owner)
    end)

    assert {:ok, %{"meetings" => [%{"meeting_id" => "mtg-context"}]}} =
             SystemsObservability.Context.with_surface("bft", fn ->
               SalixMeet.list_group_meetings_bounded(group_id, limit: 10, deadline_ms: 500)
             end)

    assert_receive {:meeting_state_read_surface, "bft"}
  end

  # A backend that raises rather than returning a typed error: what a genuinely
  # broken index looks like from inside the read.
  defmodule CrashingStateBackend do
    def get(_key, _opts), do: raise("meeting state read crashed")

    defdelegate list(prefix, opts), to: SalixStore.S3.Fake
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: SalixStore.S3.Fake
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
    defdelegate stream(key, opts), to: SalixStore.S3.Fake
    defdelegate head(key), to: SalixStore.S3.Fake
    defdelegate delete(key, opts), to: SalixStore.S3.Fake
  end

  # `Task.async/1` LINKS. A crashing index read therefore killed the CALLER
  # before `Task.yield/2` could return the `{:exit, _}` diagnostic that clause
  # exists to produce, so a broken index took down the Triage freeze that was
  # only asking it a bounded question.
  test "a crashing projected-state read is a typed diagnostic and the caller survives" do
    create_meeting!("mtg-crashing", "group-crashing", %{"start_at" => 1})

    Application.put_env(:salix_store, :s3_backend, CrashingStateBackend)
    caller = self()

    assert {:error, :unavailable} =
             SalixMeet.list_group_meetings_bounded("group-crashing", limit: 50, deadline_ms: 500)

    assert self() == caller
    assert Process.alive?(caller)
  end

  test "reports an explicit truncation instead of returning an incomplete group" do
    for ordinal <- 1..101 do
      create_meeting!("mtg-crowded-#{ordinal}", "group-crowded", %{"start_at" => ordinal})
    end

    assert {:error, :truncated} =
             SalixMeet.list_group_meetings_bounded("group-crowded", limit: 50, deadline_ms: 500)
  end

  test "new meeting state is projected before it becomes durable" do
    id = "mtg-projection-create"
    group_id = "group-projection-create"

    assert {:ok, _doc, _etag} = Store.create_once(id, state: %{"group_id" => group_id})
    assert {:ok, ^group_id} = MeetingGroupProjections.fetch_group(id)
    assert {:ok, _state} = SalixStore.S3.get(SalixStore.Keys.meet_state(id))
  end

  test "a refused projection leaves authoritative state absent and a retry converges" do
    id = "mtg-projection-refusal"
    group_id = "group-projection-refusal"
    state_key = SalixStore.Keys.meet_state(id)

    assert :ok = MeetingGroupProjections.ensure("group-conflict", id)

    assert {:error, {:meeting_group_projection_unavailable, :identity_conflict}} =
             Store.create_once(id, state: %{"group_id" => group_id})

    assert {:error, :not_found} = SalixStore.S3.get(state_key)

    Repo.query!("DELETE FROM meeting_group_projections WHERE meeting_id = $1", [id])

    assert {:ok, _doc, _etag} = Store.create_once(id, state: %{"group_id" => group_id})
    assert {:ok, ^group_id} = MeetingGroupProjections.fetch_group(id)
    assert {:ok, _state} = SalixStore.S3.get(state_key)
  end

  test "an existing state repairs a missing group projection before reporting exists" do
    id = "mtg-projection-repair"
    group_id = "group-projection-repair"

    doc = %{
      "id" => id,
      "epoch" => 0,
      "leader_node" => nil,
      "lease_until" => nil,
      "join_requested_at" => nil,
      "state" => %{"group_id" => group_id},
      "created_at" => 1
    }

    assert {:ok, _put} =
             SalixStore.S3.put(SalixStore.Keys.meet_state(id), Jason.encode!(doc),
               if_none_match: "*"
             )

    assert {:error, :exists} = Store.create_once(id, state: %{"group_id" => group_id})
    assert {:ok, ^group_id} = MeetingGroupProjections.fetch_group(id)
  end

  test "legacy state stays unavailable until the later online backfill seals readiness" do
    SalixStore.S3.Fake.reset()
    Repo.query!("TRUNCATE meeting_group_projections")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'meeting_group_projection_v1'")
    :ok = MeetingGroupProjectionReadiness.refresh()
    id = "mtg-legacy-backfill"
    group_id = "group-legacy-backfill"

    doc = %{
      "id" => id,
      "epoch" => 0,
      "leader_node" => nil,
      "lease_until" => nil,
      "join_requested_at" => nil,
      "state" => %{"group_id" => group_id, "status" => "done"},
      "created_at" => 1
    }

    assert {:ok, _put} =
             SalixStore.S3.put(SalixStore.Keys.meet_state(id), Jason.encode!(doc),
               if_none_match: "*"
             )

    assert {:error, :meeting_source_unsealed} =
             SalixMeet.list_group_meetings_bounded(group_id, limit: 50, deadline_ms: 500)

    # PR #934 deploys the projection-first writer without invoking this entrypoint.
    # The test call represents the later release after that rollout barrier.
    refute function_exported?(SalixMeet.Release, :backfill_group_projection, 0)
    refute function_exported?(SalixMeet.Release, :backfill_group_projection, 1)

    assert :ok = SalixMeet.Release.run_online_group_projection_backfill()

    assert {:ok, %{"meetings" => [%{"meeting_id" => ^id}], "completeness" => "complete"}} =
             SalixMeet.list_group_meetings_bounded(group_id, limit: 50, deadline_ms: 500)
  end

  test "later online backfill seals an empty authoritative corpus" do
    SalixStore.S3.Fake.reset()
    Repo.query!("TRUNCATE meeting_group_projections")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'meeting_group_projection_v1'")
    :ok = MeetingGroupProjectionReadiness.refresh()

    refute MeetingGroupProjectionReadiness.ready?()
    assert :ok = SalixMeet.Release.run_online_group_projection_backfill()
    assert MeetingGroupProjectionReadiness.ready?()

    assert {:ok, %{"meetings" => [], "completeness" => "complete", "truncated" => false}} =
             SalixMeet.list_group_meetings_bounded("group-empty-after-backfill",
               limit: 50,
               deadline_ms: 500
             )
  end

  test "a later online retry repairs missing rows but never deletes an orphan" do
    id = "mtg-projection-repair-after-seal"
    group_id = "group-projection-repair-after-seal"

    assert {:ok, _doc, _etag} = Store.create_once(id, state: %{"group_id" => group_id})
    assert :ok = SalixMeet.Release.audit_group_projection()

    Repo.query!("DELETE FROM meeting_group_projections WHERE meeting_id = $1", [id])

    assert {:error, {:projection_mismatch, ^id, {:error, :not_found}}} =
             SalixMeet.Release.audit_group_projection()

    assert :ok = SalixMeet.Release.run_online_group_projection_backfill()
    assert :ok = SalixMeet.Release.audit_group_projection()
    assert {:ok, ^group_id} = MeetingGroupProjections.fetch_group(id)

    assert :ok = MeetingGroupProjections.ensure("group-orphan", "mtg-projection-orphan")

    assert {:error, {:projection_count_mismatch, 1, 2}} =
             SalixMeet.Release.audit_group_projection()

    assert {:error, {:projection_count_mismatch, 1, 2}} =
             SalixMeet.Release.run_online_group_projection_backfill()

    assert {:ok, "group-orphan"} =
             MeetingGroupProjections.fetch_group("mtg-projection-orphan")

    assert {:error, {:projection_count_mismatch, 1, 2}} =
             SalixMeet.Release.audit_group_projection()
  end

  test "the periodic projection auditor detects drift without repairing authority" do
    id = "mtg-periodic-projection-audit"
    group_id = "group-periodic-projection-audit"

    assert {:ok, _doc, _etag} = Store.create_once(id, state: %{"group_id" => group_id})
    Repo.query!("DELETE FROM meeting_group_projections WHERE meeting_id = $1", [id])

    auditor =
      start_supervised!(
        {SalixMeet.MeetingGroupProjectionAuditor, name: nil, interval_ms: 60_000, page_size: 10}
      )

    assert {:error, {:projection_mismatch, ^id, {:error, :not_found}}} =
             SalixMeet.MeetingGroupProjectionAuditor.audit_now(auditor)

    assert {:error, :not_found} = MeetingGroupProjections.fetch_group(id)

    assert :ok = SalixMeet.Release.run_online_group_projection_backfill()
    assert :ok = MeetingGroupProjections.ensure("group-orphan", "mtg-periodic-orphan")

    assert {:error, {:projection_count_mismatch, 1, 2}} =
             SalixMeet.MeetingGroupProjectionAuditor.audit_now(auditor)

    assert {:ok, "group-orphan"} = MeetingGroupProjections.fetch_group("mtg-periodic-orphan")
  end

  test "a thirty-meeting group answers inside its own deadline on a slow backend" do
    group_id = "group-thirty"

    for ordinal <- 1..30 do
      create_meeting!("mtg-thirty-#{ordinal}", group_id, %{"start_at" => ordinal})
    end

    Application.put_env(:salix_store, :s3_backend, SlowGetBackend)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake) end)

    # PostgreSQL performs the bounded projection query; only the 30
    # authoritative state GETs pay this backend latency. Serialized they would
    # exceed the inner budget, while bounded concurrency fits.
    assert 30 * SlowGetBackend.latency_ms() > 1_000

    assert {:ok, %{"meetings" => meetings, "completeness" => "complete", "truncated" => false}} =
             SalixMeet.list_group_meetings_bounded(group_id, limit: 50, deadline_ms: 2_000)

    assert length(meetings) == 30
  end

  test "a repeated meeting CAS never depends on or rebuilds the derived projection" do
    id = "mtg-steady-projection"
    group_id = "group-steady-projection"

    assert {:ok, _doc, etag} = Store.create_once(id, state: %{"group_id" => group_id})

    SalixStore.S3.Fake.reset_put_log()
    Repo.query!("DELETE FROM meeting_group_projections WHERE meeting_id = $1", [id])

    assert {:ok, _doc, etag} = Store.update_state(id, etag, &Map.put(&1, "status", "active"))
    assert {:ok, _doc, _etag} = Store.update_state(id, etag, &Map.put(&1, "status", "done"))

    # A different process reaches the same answer from authoritative state
    # alone. The projection is not a meeting write control plane.
    assert {:ok, doc, fresh_etag} = Store.get(id)

    assert {:ok, _doc, _etag} =
             Task.async(fn ->
               Store.update_state(doc["id"], fresh_etag, &Map.put(&1, "status", "failed"))
             end)
             |> Task.await(5_000)

    assert {:error, :not_found} = MeetingGroupProjections.fetch_group(id)
  end

  defp create_meeting!(id, group_id, state) do
    state = Map.put(state, "group_id", group_id)
    {:ok, _doc, _etag} = Store.create_once(id, state: state)
  end
end
