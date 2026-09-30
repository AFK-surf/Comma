defmodule SalixAgent.TestSupport.LegacySessionArchive do
  @moduledoc false
  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSessionStore
  alias SalixStore.{ArchiveLog, Codec, Keys, S3}

  # Historical bytes for legacy-reader tests, not a runtime writer. New
  # writes in each scenario still use InternalSessionStore and publish format 3.
  def write(agent, session, captured \\ nil) do
    {:ok, state} =
      if captured, do: {:ok, captured}, else: InternalSessionStore.read(agent, session)

    {:ok, old} = InternalSessionStore.archived_records(agent, state)
    records = old ++ InternalSessionStore.window_records_shaped(state)
    compacted_seq = InternalSession.get(state, :compacted_seq)
    covered = Enum.take_while(records, &(&1.seq <= compacted_seq))
    through = if covered == [], do: 0, else: List.last(covered).seq

    if through == InternalSession.archived_through(state) do
      {:ok, :nothing_to_archive}
    else
      {:ok, _} =
        S3.put(
          Keys.agent_internal_runtime_session_archive(agent, session),
          ArchiveLog.encode(covered)
        )

      next =
        state
        |> InternalSession.export()
        |> Map.put(:archive_chunks, ArchiveLog.spans(covered, 0))
        |> InternalSession.open()
        |> InternalSession.apply_events([
          %{
            "type" => "archive_advance",
            "session_id" => session,
            "archived_through" => through,
            "segments" => []
          }
        ])
        |> InternalSession.export()

      next = %{next | storage_format: 2}

      {:ok, _} =
        S3.put(
          Keys.agent_internal_runtime_session(agent, session),
          Codec.encode_snapshot(%{next | context_provider_states: %{}})
        )

      {:ok, :archived}
    end
  end
end
