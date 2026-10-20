defmodule SalixMeetTest do
  @moduledoc """
  `SalixMeet.list_group_meetings/1`: the compact meeting-record listing the
  dashboard reads over erpc — group-scoped, newest first, and stripped of
  runtime internals (tokens, leases, raw captions).
  """
  use SystemsClock.Case, async: false

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
      SystemsRuntime.Proc.sleep(@get_latency_ms)
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
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_meet, :context_test_owner),
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
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> :ok
    end

    SalixStore.S3.Fake.reset()
    Repo.query!("TRUNCATE meeting_group_projections")
    :ok = MeetingGroupProjections.mark_ready(%{"mode" => "test"})
    :ok = MeetingGroupProjectionReadiness.refresh()

    on_exit(fn ->
      if prev_s3 do
        SystemsRuntime.put_env(:salix_store, :s3_backend, prev_s3)
      else
        SystemsRuntime.delete_env(:salix_store, :s3_backend)
      end
    end)

    :ok
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

  test "new meeting state is projected before it becomes durable" do
    id = "mtg-projection-create"
    group_id = "group-projection-create"

    assert {:ok, _doc, _etag} = Store.create_once(id, state: %{"group_id" => group_id})
    assert {:ok, ^group_id} = MeetingGroupProjections.fetch_group(id)
    assert {:ok, _state} = SalixStore.S3.get(SalixStore.Keys.meet_state(id))
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

  defp create_meeting!(id, group_id, state) do
    state = Map.put(state, "group_id", group_id)
    {:ok, _doc, _etag} = Store.create_once(id, state: state)
  end
end
