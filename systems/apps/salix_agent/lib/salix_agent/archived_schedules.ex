defmodule SalixAgent.ArchivedSchedules do
  @moduledoc """
  The archive side of an agent's schedules: pause on archive, resume on
  unarchive, and reconcile a stale observation of either.

  Modeled in tla/salix/SchedulePauseOnArchive.tla.

  Two stores, three writers, no shared transaction. The archive fact lives
  in the agent's S3 control record; the schedules live in Postgres. Archive
  (`AgentControl.delete/1`) writes the record, then pauses. Unarchive
  (`AgentControl.unarchive/2`) resumes, then clears the record. The sweep
  (`ArchivedScheduleSweep`) reads records and acts on what it saw — possibly
  long after, by which time an unarchive may have run to completion. Two
  rules make every interleaving converge:

  1. **Epoch fence, in Postgres.** Every archive bumps `archive_epoch` on
     the record. A pause is *for* an epoch and marks its rows with it; an
     unarchive stamps every agent-receiver row `unarchived_epoch` with the
     epoch it is clearing, in the same statement that resumes the marked
     ones. A pause for epoch N refuses rows already stamped `>= N`: the
     unarchive of that archive has happened, however stale the pauser's
     view of the record. Both are single `UPDATE`s, so row locks order
     them, and READ COMMITTED re-checks the predicate after a wait.
  2. **Re-validate after pausing, against S3.** A row created after the
     unarchive carries no stamp, so the fence cannot protect it. A pauser
     that paused anything re-reads the record; if it is no longer archived
     it resumes what it paused (rows marked with its epoch or older). A row
     can only be created for a live agent — after the record was cleared —
     so that re-read necessarily observes the clear.

  Failures are bounded, not hidden. A pause or re-validation that fails
  leaves rows either active (the sweeper's blocked classification holds
  them at fire time) or archive-paused on a live agent; the sweep
  reconciles both directions on its next run (`reconcile_live/3`). A
  resume that fails aborts the unarchive before the record is touched.
  """

  alias SalixStore.Schedules

  @type pause_summary :: %{paused: non_neg_integer(), undone: non_neg_integer()}

  @doc "Is this control record archived? (`archived_at` presence, as `AgentControl.archived?/1`.)"
  @spec archived?(map()) :: boolean()
  def archived?(rec) when is_map(rec), do: Map.has_key?(rec, "archived_at")

  @doc """
  The record's archive epoch: how many times the agent has been archived.
  Records from before the field existed read as 1 when archived (one
  archive happened, whose epoch nothing has yet stamped) and 0 when live.
  """
  @spec archive_epoch(map()) :: non_neg_integer()
  def archive_epoch(rec) when is_map(rec) do
    case rec["archive_epoch"] do
      n when is_integer(n) and n > 0 -> n
      _ -> if archived?(rec), do: 1, else: 0
    end
  end

  @doc """
  The epoch an archive of `rec` is for: the next one for a live record, the
  current one for a record that is already archived (re-archiving an
  archived agent is a no-op for the fence).
  """
  @spec archive_epoch_on_archive(map()) :: pos_integer()
  def archive_epoch_on_archive(rec) when is_map(rec) do
    if archived?(rec), do: archive_epoch(rec), else: archive_epoch(rec) + 1
  end

  @doc """
  Pause the agent's active schedules for `epoch`, then re-validate: if the
  record is no longer archived (an unarchive completed while this pauser
  was acting on its earlier read), resume the rows this pause marked.
  Nothing paused means nothing to re-validate.
  """
  @spec pause(String.t(), pos_integer(), keyword()) :: {:ok, pause_summary()} | {:error, term()}
  def pause(agent_id, epoch, opts \\ []) when is_binary(agent_id) and is_integer(epoch) do
    now_ms = Keyword.get(opts, :now_ms) || System.system_time(:millisecond)

    case Schedules.pause_for_archived_agent(agent_id, epoch, now_ms) do
      {:ok, 0} -> {:ok, %{paused: 0, undone: 0}}
      {:ok, paused} -> revalidate(agent_id, epoch, paused, now_ms)
      {:error, reason} -> {:error, {:pause, reason}}
    end
  end

  defp revalidate(agent_id, epoch, paused, now_ms) do
    case SalixAgent.AgentControl.get_record(agent_id) do
      {:ok, rec} ->
        if archived?(rec) do
          {:ok, %{paused: paused, undone: 0}}
        else
          case Schedules.resume_archive_paused(agent_id, epoch, now_ms) do
            {:ok, undone} -> {:ok, %{paused: paused, undone: undone}}
            {:error, reason} -> {:error, {:revalidate_resume, reason}}
          end
        end

      # No readable record: nothing can be delivered to this agent anyway
      # (the ingress refuses a target without a control record), so the
      # paused rows are not stranding anything.
      {:error, :not_found} ->
        {:ok, %{paused: paused, undone: 0}}

      {:error, reason} ->
        {:error, {:revalidate_read, reason}}
    end
  end

  @doc """
  The unarchive's resume for `epoch`: resume the archive-paused rows and
  stamp every agent-receiver row with the epoch, in one statement. Returns
  the number of rows written.
  """
  @spec resume_for_unarchive(String.t(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def resume_for_unarchive(agent_id, epoch, opts \\ [])
      when is_binary(agent_id) and is_integer(epoch) do
    now_ms = Keyword.get(opts, :now_ms) || System.system_time(:millisecond)
    Schedules.resume_archive_paused(agent_id, epoch, now_ms, stamp: true)
  end

  @doc """
  Reconcile a LIVE record (archive epoch `epoch`): resume any archive-paused
  row marked with that epoch or older — a stale pause whose re-validation
  never ran. Rows marked with a newer epoch belong to an archive this
  observation predates and are left alone. Returns the number resumed.
  """
  @spec reconcile_live(String.t(), non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_live(agent_id, epoch, opts \\ [])
      when is_binary(agent_id) and is_integer(epoch) do
    now_ms = Keyword.get(opts, :now_ms) || System.system_time(:millisecond)
    Schedules.resume_archive_paused(agent_id, epoch, now_ms)
  end
end
