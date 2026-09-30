defmodule SalixStore.ScheduleRuns do
  @moduledoc """
  Postgres data access for schedule run claims
  (docs/storage-search.md).

  The PG image of the retired create-once run objects
  (`ctl/schedule_runs/{id}/{scheduled_for_iso}.json`): the composite primary
  key `(schedule_id, scheduled_for_ms)` IS the firing claim —
  `INSERT ... ON CONFLICT DO NOTHING` wins or observes, exactly the legacy
  `If-None-Match: *` PUT, with the ambiguous-outcome branch gone (a PG insert
  either lands, conflicts, or errors).

  Claims are retention-pruned via `prune_older_than/1` — the S3 prefix
  accumulated forever. The prune window only trims the *audit trail*; claim
  correctness needs the row only while its window can still be re-selected by
  the sweep (bounded by the schedule's recurrence, far inside any sane
  retention).

  Store faults surface as `{:error, :unavailable}` on every entry point.
  """

  import Ecto.Query

  alias SalixStore.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "schedule_runs" do
      field(:schedule_id, :string, primary_key: true)
      field(:scheduled_for_ms, :integer, primary_key: true)
      field(:disposition, :string)
      field(:receiver, :string)
      field(:agent_id, :string)
      field(:agent_group_id, :string)
      field(:conversation_id, :string)
      field(:node, :string)
      field(:fired_at, :integer)
      # The frozen delivery target (occurrence authority, #871): "" is the
      # explicit claimed-session-less sentinel; NULL marks a legacy claim
      # from before the column existed.
      field(:session_id, :string)
      field(:inserted_at, :utc_datetime_usec)
    end
  end

  @type claim_attrs :: %{optional(String.t()) => term()}

  @doc """
  Claim one `(schedule_id, scheduled_for_ms)` window. `:claimed` means this
  caller won the insert; `:exists` means a claim (any disposition) was already
  durable — read it back with `disposition/2` and follow it.
  """
  @spec claim(String.t(), integer(), claim_attrs()) ::
          :claimed | :exists | {:error, :unavailable}
  def claim(schedule_id, scheduled_for_ms, attrs)
      when is_binary(schedule_id) and is_integer(scheduled_for_ms) and is_map(attrs) do
    row = %{
      schedule_id: schedule_id,
      scheduled_for_ms: scheduled_for_ms,
      disposition: attrs["disposition"] || "dispatch",
      receiver: attrs["receiver"],
      agent_id: attrs["agent_id"],
      agent_group_id: attrs["agent_group_id"],
      conversation_id: attrs["conversation_id"],
      node: attrs["node"],
      fired_at: attrs["fired_at"],
      session_id: attrs["session_id"]
    }

    case Repo.insert_all(Row, [row],
           on_conflict: :nothing,
           conflict_target: [:schedule_id, :scheduled_for_ms]
         ) do
      {1, _} -> :claimed
      {0, _} -> :exists
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Durable disposition of an existing claim."
  @spec disposition(String.t(), integer()) ::
          {:ok, :dispatch | :skipped_stale | :undeliverable}
          | {:error, :not_found}
          | {:error, :invalid_run_claim}
          | {:error, :unavailable}
  def disposition(schedule_id, scheduled_for_ms)
      when is_binary(schedule_id) and is_integer(scheduled_for_ms) do
    case Repo.get_by(Row, schedule_id: schedule_id, scheduled_for_ms: scheduled_for_ms) do
      nil -> {:error, :not_found}
      %Row{disposition: d} when d in [nil, "dispatch"] -> {:ok, :dispatch}
      %Row{disposition: "skipped_stale"} -> {:ok, :skipped_stale}
      %Row{disposition: "undeliverable"} -> {:ok, :undeliverable}
      %Row{} -> {:error, :invalid_run_claim}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Durable disposition AND frozen delivery target of an existing claim (the
  occurrence authority, #871): every dispatcher — winner, loser, resume,
  recover — delivers to the CLAIMED target, never its own definition
  snapshot and never the mutable current definition. `:sessionless` is the
  explicit frozen "" sentinel; `:legacy_snapshot` marks a pre-migration
  claim that never froze a target and keeps the old snapshot-driven
  dispatch (bounded, pre-deploy population).
  """
  @spec claim_state(String.t(), integer()) ::
          {:ok,
           %{
             disposition: :dispatch | :skipped_stale | :undeliverable,
             target: {:session, String.t()} | :sessionless | :legacy_snapshot
           }}
          | {:error, :not_found}
          | {:error, :invalid_run_claim}
          | {:error, :unavailable}
  def claim_state(schedule_id, scheduled_for_ms)
      when is_binary(schedule_id) and is_integer(scheduled_for_ms) do
    case Repo.get_by(Row, schedule_id: schedule_id, scheduled_for_ms: scheduled_for_ms) do
      nil ->
        {:error, :not_found}

      %Row{} = row ->
        with {:ok, disposition} <- normalize_disposition(row.disposition) do
          {:ok, %{disposition: disposition, target: normalize_target(row.session_id)}}
        end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp normalize_disposition(d) when d in [nil, "dispatch"], do: {:ok, :dispatch}
  defp normalize_disposition("skipped_stale"), do: {:ok, :skipped_stale}
  defp normalize_disposition("undeliverable"), do: {:ok, :undeliverable}
  defp normalize_disposition(_), do: {:error, :invalid_run_claim}

  defp normalize_target(nil), do: :legacy_snapshot
  defp normalize_target(""), do: :sessionless
  defp normalize_target(session_id), do: {:session, session_id}

  @doc """
  Resolve an open `dispatch` claim to the terminal `undeliverable`
  disposition — the durable, truthful outcome that must exist BEFORE the
  schedule anchor advances past a permanently undeliverable occurrence
  (`ScheduleDispatch.tla` `AdvanceRequiresDurableOutcome`). Idempotent: an
  already-`undeliverable` claim answers :ok; a claim already resolved any
  other way is left untouched and answers `{:error, :invalid_run_claim}`.
  """
  @spec resolve_undeliverable(String.t(), integer()) ::
          :ok | {:error, :not_found} | {:error, :invalid_run_claim} | {:error, :unavailable}
  def resolve_undeliverable(schedule_id, scheduled_for_ms)
      when is_binary(schedule_id) and is_integer(scheduled_for_ms) do
    {count, _} =
      Repo.update_all(
        from(r in Row,
          where:
            r.schedule_id == ^schedule_id and r.scheduled_for_ms == ^scheduled_for_ms and
              (is_nil(r.disposition) or r.disposition in ["dispatch", "undeliverable"])
        ),
        set: [disposition: "undeliverable"]
      )

    if count == 1 do
      :ok
    else
      case disposition(schedule_id, scheduled_for_ms) do
        {:error, :not_found} -> {:error, :not_found}
        _ -> {:error, :invalid_run_claim}
      end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "All claims for one schedule, as legacy-shaped string-keyed maps."
  @spec list_for(String.t()) :: {:ok, [map()]} | {:error, :unavailable}
  def list_for(schedule_id) when is_binary(schedule_id) do
    rows =
      Row
      |> where([r], r.schedule_id == ^schedule_id)
      |> Repo.all()
      |> Enum.map(&to_record/1)

    {:ok, rows}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Delete RESOLVED claims older than the retention window. Returns the count.

  A claim is audit trail (prunable) only once its live definition can no
  longer re-select the window: the anchor has advanced past it, or the
  definition itself is gone (one-shots delete after advance). An unresolved
  dispatch claim — e.g. a blocked target whose anchor is deliberately held —
  is load-bearing state, not audit: pruning it would let a later sweep
  re-claim the still-due window as `skipped_stale` and advance without a
  receiver ACK, losing the occurrence (`ScheduleDispatch.tla`'s
  immutable-disposition / ACK-before-advance properties).
  """
  @spec prune_older_than(pos_integer()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def prune_older_than(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {count, _} =
      Row
      |> where([r], r.inserted_at < ^cutoff)
      |> where(
        [r],
        fragment(
          "NOT EXISTS (SELECT 1 FROM schedules s WHERE s.id = ? AND (s.last_run IS NULL OR s.last_run < ?))",
          r.schedule_id,
          r.scheduled_for_ms
        )
      )
      |> Repo.delete_all()

    {:ok, count}
  rescue
    _ -> {:error, :unavailable}
  end

  defp to_record(%Row{} = row) do
    %{
      "schedule_id" => row.schedule_id,
      "scheduled_for_ms" => row.scheduled_for_ms,
      "disposition" => row.disposition,
      "receiver" => row.receiver,
      "agent_id" => row.agent_id,
      "agent_group_id" => row.agent_group_id,
      "conversation_id" => row.conversation_id,
      "node" => row.node,
      "fired_at" => row.fired_at,
      "session_id" => row.session_id
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end
end
