defmodule SalixStore.TriageIntake do
  @moduledoc """
  Group-scoped read index of canonical provider receipts. It owns no work,
  admission status, retry, or timer. Provider receipt storage remains the
  source of truth; its recovery ring can rebuild missing index entries.
  """
  alias SalixStore.Repo

  def observe(group_id, receipt) when is_binary(group_id) and is_map(receipt) do
    case Repo.query(
           """
           INSERT INTO triage_intake_events
             (receipt_ref, group_id, connect_id, received_at_ms, receipt)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (receipt_ref) DO NOTHING
           """,
           [
             receipt["receipt_ref"],
             group_id,
             receipt["connect_id"],
             receipt["created_at"],
             receipt
           ],
           timeout: 250
         ) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Newest receipts in one group, optionally for one Slack channel."
  def recent(group_id, limit, channel_id \\ nil)

  def recent(group_id, limit, channel_id)
      when is_binary(group_id) and limit in 1..20 and
             (is_nil(channel_id) or
                (is_binary(channel_id) and channel_id != "" and byte_size(channel_id) <= 256)) do
    case Repo.query(
           """
           SELECT receipt FROM triage_intake_events WHERE group_id = $1
             AND ($3::text IS NULL OR receipt #>> '{triage_event,bucket,channel_id}' = $3)
           ORDER BY received_at_ms DESC, receipt_ref DESC LIMIT $2
           """,
           [group_id, limit + 1, channel_id]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         %{receipts: rows |> Enum.take(limit) |> Enum.map(&hd/1), truncated: length(rows) > limit}}

      {:error, _} ->
        {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  def recent(_group, _limit, _channel_id), do: {:error, :invalid}

  def by_refs(group_id, refs)
      when is_binary(group_id) and is_list(refs) and length(refs) <= 20 do
    case Repo.query(
           "SELECT receipt FROM triage_intake_events WHERE group_id = $1 AND receipt_ref = ANY($2)",
           [group_id, refs],
           timeout: 250
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def by_refs(_group, _refs), do: {:error, :invalid}
end
