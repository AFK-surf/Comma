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
    group_id = "group-meetings-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _doc, _etag} =
      SalixMeet.Store.create_once("mtg-bft-#{SystemsRuntime.Proc.unique_integer([:positive])}",
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

  defmodule CrashingMeetingSource do
    @moduledoc false
    def list_group_meetings_bounded(_group_id, _opts), do: exit(:meeting_source_crashed)
  end

  defmodule UnsealedMeetingSource do
    @moduledoc false

    def list_group_meetings_bounded(_group_id, _opts),
      do: {:error, :meeting_source_unsealed}
  end

  defmodule ContextMeetingSource do
    @moduledoc false

    def list_group_meetings_bounded(_group_id, opts) do
      SystemsRuntime.Proc.send(
        opts[:test_pid],
        {:meeting_source_surface, SystemsObservability.Context.current_surface()}
      )

      {:ok, %{"meetings" => [], "completeness" => "complete", "truncated" => false}}
    end
  end
end
