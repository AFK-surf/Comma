defmodule BridgeForTeams.MeetingsTest do
  @moduledoc """
  `BridgeForTeams.Meetings` reads bot-attended meeting records from Salix over
  the erpc boundary (same-BEAM salix node with fake S3 in tests) and
  normalizes summaries/action items for Triage context.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.Meetings
  alias BridgeForTeams.Schema.Project

  test "list_triage_meetings/2 returns the project group's normalized meetings from Salix" do
    group_id = "group-meetings-#{System.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      SalixMeet.Store.create_once("mtg-bft-#{System.unique_integer([:positive])}",
        state: %{
          "group_id" => group_id,
          "provider" => "slack",
          "title" => "Portfolio weekly sync",
          "status" => "done",
          "start_at" => 1_751_400_000,
          "summary" => %{
            "title" => "Portfolio weekly sync",
            "key_points" => ["Two term sheets in motion"],
            "action_items" => [
              %{"description" => "Send diligence memo", "owner" => "Alex", "deadline" => "Friday"}
            ]
          },
          "artifacts" => %{"transcript" => %{"path" => "/meetings/x/transcript.txt"}},
          "slack_ref" => %{"channel_id" => "C42", "thread_ts" => "1.2"}
        }
      )

    project = %Project{salix_group_id: group_id}

    assert {:ok, [meeting]} = Meetings.list_triage_meetings(project, limit: 25)
    assert meeting["title"] == "Portfolio weekly sync"
    assert meeting["status"] == "done"
    assert meeting["artifacts"] == ["transcript"]
    assert Meetings.summarized?(meeting)

    assert [%{"description" => "Send diligence memo", "owner" => "Alex", "deadline" => "Friday"}] =
             Meetings.action_items(meeting)
  end

  # GET latency paid by the calling process, so a sequential reader is slow and
  # a boundedly-concurrent one is not.
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

  test "list_triage_meetings/2 answers a thirty-meeting group through the whole nested budget" do
    group_id = "group-triage-thirty-#{System.unique_integer([:positive])}"

    for ordinal <- 1..30 do
      {:ok, _doc, _etag} =
        SalixMeet.Store.create_once("mtg-triage-#{group_id}-#{ordinal}",
          state: %{"group_id" => group_id, "status" => "active", "start_at" => ordinal}
        )
    end

    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SlowGetBackend)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous) end)

    # BFT wait (3000ms) > erpc call (2500ms) > SalixMeet read (2000ms): every
    # leg has to be wide enough for the group's own bounded read, and the reads
    # inside it concurrent enough to fit.
    assert 30 * SlowGetBackend.latency_ms() > 1_000

    assert {:ok, meetings} =
             Meetings.list_triage_meetings(%Project{salix_group_id: group_id}, limit: 50)

    assert length(meetings) == 30
  end

  defmodule CrashingMeetingSource do
    @moduledoc false
    def list_group_meetings_bounded(_group_id, _opts), do: exit(:meeting_source_crashed)
  end

  defmodule UnsealedMeetingSource do
    @moduledoc false

    def list_group_meetings_bounded(_group_id, _opts),
      do: {:error, :meeting_source_unsealed}
  end

  # `Task.async/1` LINKS. A crashing meeting source therefore killed the caller —
  # the Triage freeze — before `Task.yield/2` could ever return the `{:exit, _}`
  # diagnostic that clause exists to produce.
  test "list_triage_meetings/2 turns a crashing source into a typed diagnostic" do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, CrashingMeetingSource)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)
    end)

    caller = self()

    assert {:error, :triage_meeting_source_unavailable} =
             Meetings.list_triage_meetings(%Project{salix_group_id: "group-crashing"}, limit: 10)

    # The freeze is still standing, and still the same process.
    assert self() == caller
    assert Process.alive?(caller)
  end

  test "list_triage_meetings/2 preserves the release-seal diagnostic" do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, UnsealedMeetingSource)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)
    end)

    assert {:error, :meeting_source_unsealed} =
             Meetings.list_triage_meetings(%Project{salix_group_id: "group-unsealed"}, limit: 10)
  end

  test "list_triage_meetings/2 surfaces the source's typed refusal, not a generic timeout" do
    group_id = "group-triage-truncated-#{System.unique_integer([:positive])}"

    for ordinal <- 1..60 do
      {:ok, _doc, _etag} =
        SalixMeet.Store.create_once("mtg-truncated-#{group_id}-#{ordinal}",
          state: %{"group_id" => group_id, "status" => "active", "start_at" => ordinal}
        )
    end

    assert {:error, {:triage_meeting_source_unavailable, :truncated}} =
             Meetings.list_triage_meetings(%Project{salix_group_id: group_id}, limit: 50)
  end

  defmodule ContextMeetingSource do
    @moduledoc false

    def list_group_meetings_bounded(_group_id, opts) do
      send(
        opts[:test_pid],
        {:meeting_source_surface, SystemsObservability.Context.current_surface()}
      )

      {:ok, %{"meetings" => [], "completeness" => "complete", "truncated" => false}}
    end
  end

  test "list_triage_meetings/2 propagates observability context into its supervised task" do
    previous = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ContextMeetingSource)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:bridge_for_teams_core, :salix_client, previous),
        else: Application.delete_env(:bridge_for_teams_core, :salix_client)
    end)

    assert {:ok, []} =
             SystemsObservability.Context.with_surface("bft", fn ->
               Meetings.list_triage_meetings(
                 %Project{salix_group_id: "group-context"},
                 limit: 10,
                 test_pid: self()
               )
             end)

    assert_receive {:meeting_source_surface, "bft"}
  end

  test "action_items/1 normalizes strings and drops blanks" do
    meeting = %{
      "summary" => %{
        "action_items" => ["  Ship the recap  ", "", %{"description" => "   "}, %{"owner" => "x"}]
      }
    }

    assert [%{"description" => "Ship the recap", "owner" => "", "deadline" => ""}] =
             Meetings.action_items(meeting)
  end
end
