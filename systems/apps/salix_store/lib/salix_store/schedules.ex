defmodule SalixStore.Schedules do
  @moduledoc """
  Postgres data access for schedule definitions
  (docs/storage-search.md).

  One row per retired `ctl/schedules/{id}.json` object. Records cross this
  boundary as string-keyed maps with the exact legacy top-level shape —
  known fields live in flat columns, every other historical body key
  round-trips through the `attrs` jsonb — so `SalixCluster.Schedules` and
  `SalixAgent.Schedules` keep all their domain logic and never see Ecto.
  Timestamps stay the unix-ms integers the legacy bodies carried.

  ## `next_fire_at` is a lower bound, not an authority

  The recurrence math (interval / cron / one-shot) lives in the domain
  modules; this store only persists `next_fire_at` as an *index column* whose
  contract is `next_fire_at <= true next fire time`. `due_candidates/1`
  therefore returns a superset: the sweep re-derives the exact next fire and
  skips (and `recompute_next_fire/2`s) rows that are not actually due. Bound
  writes never trust a caller snapshot: `advance/3` and
  `recompute_next_fire/2` take a derivation closure evaluated against the
  CURRENT locked row, and the cutover imports the anchor
  (`last_run || created_at`) — always a valid lower bound — so no cron
  evaluation happens inside salix_store.

  `status` gates the due scan (`status <> 'paused'`): only an explicit
  `"paused"` suppresses firing, so historical odd values keep today's
  behaviour while pause — dead in the S3 scanner — becomes real.

  Store faults surface as `{:error, :unavailable}` on every entry point.
  """

  import Ecto.Query

  alias SalixStore.Repo

  @known_keys ~w(id receiver agent_id session_id prompt payload interval_minutes cron timezone run_at status kind name created_at updated_at last_run)

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "schedules" do
      field(:id, :string, primary_key: true)
      field(:receiver, :string)
      field(:agent_id, :string)
      field(:session_id, :string)
      field(:prompt, :string)
      field(:payload, :map)
      field(:interval_minutes, :integer)
      field(:cron, :string)
      field(:timezone, :string)
      field(:run_at, :integer)
      field(:status, :string)
      field(:kind, :string)
      field(:name, :string)
      field(:attrs, :map)
      field(:created_at, :integer)
      field(:updated_at, :integer)
      field(:last_run, :integer)
      field(:next_fire_at, :integer)
    end
  end

  @type sched_record :: %{optional(String.t()) => term()}

  @spec get(String.t()) :: {:ok, sched_record()} | {:error, :not_found} | {:error, :unavailable}
  def get(id) when is_binary(id) do
    case Repo.get(Row, id) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Create-once insert (the PG image of the legacy `If-None-Match: *` PUT).
  `next_fire_at` is the exact next fire computed by the caller.
  """
  @spec create(sched_record(), integer()) ::
          {:ok, sched_record()} | {:error, :already_exists} | {:error, :unavailable}
  def create(%{"id" => id} = record, next_fire_at)
      when is_binary(id) and is_integer(next_fire_at) do
    case Repo.insert_all(Row, [row_map(record, next_fire_at)],
           on_conflict: :nothing,
           conflict_target: [:id]
         ) do
      {1, _} -> {:ok, canonical(record)}
      {0, _} -> {:error, :already_exists}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Serialized read-modify-write (the PG image of the legacy CAS loop). `fun`
  receives the current record under a row lock and returns
  `{:ok, record, next_fire_at}` to write or `{:error, reason}` to abort.
  """
  @spec update(String.t(), (sched_record() -> {:ok, sched_record(), integer()} | {:error, term()})) ::
          {:ok, sched_record()} | {:error, :not_found} | {:error, term()}
  def update(id, fun) when is_binary(id) and is_function(fun, 1) do
    Repo.transaction(fn ->
      case Repo.one(from(r in Row, where: r.id == ^id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:not_found)

        %Row{} = row ->
          case fun.(to_record(row)) do
            {:ok, record, next_fire_at} when is_integer(next_fire_at) ->
              updates =
                record
                |> row_map(next_fire_at)
                |> Map.drop([:id])
                |> Map.to_list()

              {1, _} =
                Repo.update_all(from(r in Row, where: r.id == ^id), set: updates)

              canonical(record)

            {:error, reason} ->
              Repo.rollback(reason)
          end
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Unscoped point delete. Callers that have an owner MUST use
  `delete_agent_owned/2` or `delete_task_owned/2` instead — an owner surface
  that reads then deletes globally is both unfenced (a row bound to another
  owner class is deletable) and non-atomic (the row can change between the
  read and the delete).
  """
  @spec delete(String.t()) :: :ok | {:error, :unavailable}
  def delete(id) when is_binary(id) do
    Row |> where([r], r.id == ^id) |> Repo.delete_all()
    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Point read scoped to an Agent owner: the row must be an Agent-receiver row
  (`receiver <> 'task'` — a Task's owner is its group binding, never an agent,
  even for a pre-validation/imported row carrying both) owned by `agent_id`.
  Anything else is indistinguishable from missing.
  """
  @spec get_agent_owned(String.t(), String.t()) ::
          {:ok, sched_record()} | {:error, :not_found} | {:error, :unavailable}
  def get_agent_owned(id, agent_id) when is_binary(id) and is_binary(agent_id) do
    case Repo.one(agent_owned_query(id, agent_id)) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Atomic owner-scoped delete for the Agent-owner surfaces: the ownership
  predicate is part of the DELETE, so there is no read→delete window and no
  way to delete a row the caller does not own.
  """
  @spec delete_agent_owned(String.t(), String.t()) ::
          :ok | {:error, :not_found} | {:error, :unavailable}
  def delete_agent_owned(id, agent_id) when is_binary(id) and is_binary(agent_id) do
    case Repo.delete_all(agent_owned_query(id, agent_id)) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Atomic owner-scoped delete for the Task-owner surface: the row must be a
  Task-receiver row bound to `group_id`.
  """
  @spec delete_task_owned(String.t(), String.t()) ::
          :ok | {:error, :not_found} | {:error, :unavailable}
  def delete_task_owned(id, group_id) when is_binary(id) and is_binary(group_id) do
    query =
      Row
      |> where(
        [r],
        r.id == ^id and r.receiver == "task" and
          fragment("? ->> 'agent_group_id' = ?", r.payload, ^group_id)
      )

    case Repo.delete_all(query) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp agent_owned_query(id, agent_id),
    do: Row |> where([r], r.id == ^id and r.receiver != "task" and r.agent_id == ^agent_id)

  @spec list() :: {:ok, [sched_record()]} | {:error, :unavailable}
  def list do
    {:ok, Row |> Repo.all() |> Enum.map(&to_record/1)}
  rescue
    _ -> {:error, :unavailable}
  end

  @spec list_by_agent(String.t()) :: {:ok, [sched_record()]} | {:error, :unavailable}
  def list_by_agent(agent_id) when is_binary(agent_id), do: list_by_agents([agent_id])

  @doc """
  Owner-filtered listing for a bounded set of agents (the request-path shape:
  unrelated rows are neither queried nor transferred).
  """
  @spec list_by_agents([String.t()]) :: {:ok, [sched_record()]} | {:error, :unavailable}
  def list_by_agents(agent_ids) when is_list(agent_ids) do
    {:ok, agents_query(agent_ids) |> Repo.all() |> Enum.map(&to_record/1)}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Owner-filtered listing across both receiver shapes: rows owned by any of
  `agent_ids` (agent receiver) plus **Task** rows whose payload binds
  `agent_group_id` to `group_id` (the disjunct is constrained to
  `receiver = 'task'`, so a foreign Agent row carrying a look-alike payload is
  never selected). The dashboard/project surface — unrelated rows are neither
  queried nor transferred, and both disjuncts are index-backed
  (`schedules_agent_id_index` + the partial expression index
  `schedules_task_group_idx`), so the access plan never falls back to a scan
  proportional to the global table (see the EXPLAIN regression).
  """
  @spec list_for_owners([String.t()], String.t() | nil) ::
          {:ok, [sched_record()]} | {:error, :unavailable}
  def list_for_owners(agent_ids, group_id) when is_list(agent_ids) do
    {:ok, owners_query(agent_ids, group_id) |> Repo.all() |> Enum.map(&to_record/1)}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc false
  # Access-plan probe for the regression suite: the EXPLAIN of exactly the
  # query `list_for_owners/2` executes.
  def explain_list_for_owners(agent_ids, group_id) when is_list(agent_ids) do
    Ecto.Adapters.SQL.explain(Repo, :all, owners_query(agent_ids, group_id))
  end

  defp owners_query(agent_ids, nil), do: agents_query(agent_ids)

  defp owners_query(agent_ids, group_id) when is_binary(group_id) do
    Row
    |> where(
      [r],
      (r.receiver != "task" and r.agent_id in ^agent_ids) or
        (r.receiver == "task" and
           fragment("? ->> 'agent_group_id' = ?", r.payload, ^group_id))
    )
  end

  # Owner branches are mutually receiver-fenced: an Agent-owner lookup never
  # selects a Task row (a Task's owner is its group binding — validation
  # rejects an agent_id on a Task, and this fence keeps any pre-existing or
  # imported row with both from being selectable/mutable through the agent
  # branch), and the Task branch never selects an Agent row.
  defp agents_query(agent_ids),
    do: Row |> where([r], r.receiver != "task" and r.agent_id in ^agent_ids)

  @doc """
  Superset of the due set: rows whose lower-bound `next_fire_at` has passed and
  that are not explicitly paused. The sweep re-derives the exact next fire.
  """
  @spec due_candidates(integer()) :: {:ok, [sched_record()]} | {:error, :unavailable}
  def due_candidates(now_ms) when is_integer(now_ms) do
    {:ok,
     Row
     |> where([r], r.next_fire_at <= ^now_ms and r.status != "paused")
     |> Repo.all()
     |> Enum.map(&to_record/1)}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Status-only update (pause/resume). Recurrence fields are untouched, so the
  stored `next_fire_at` bound stays valid and no recurrence math is needed —
  callers without the cron evaluator (salix_agent) stay correct.
  """
  @spec set_status(String.t(), String.t(), integer() | nil) ::
          {:ok, sched_record()} | {:error, :not_found} | {:error, :unavailable}
  def set_status(id, status, updated_at \\ nil)
      when is_binary(id) and is_binary(status) do
    updates =
      case updated_at do
        nil -> [status: status]
        ms when is_integer(ms) -> [status: status, updated_at: ms]
      end

    {count, _} =
      Row
      |> where([r], r.id == ^id)
      |> Repo.update_all(set: updates)

    case count do
      1 -> get(id)
      0 -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @archive_pause_marker "archive"

  @doc """
  Pause every ACTIVE agent-receiver schedule of `agent_id` for archive epoch
  `archive_epoch` (the counter the agent's control record bumps on every
  archive). Each paused row is marked `paused_by: "archive"` and
  `archive_epoch` (`attrs` keys, so they read back as `record["paused_by"]` /
  `record["archive_epoch"]`); a user-paused row carries no marker and is not
  touched, which is what lets the resume tell the two apart.

  The fence: a row whose `unarchived_epoch` is already `>= archive_epoch`
  was released by an unarchive of this very epoch, so the pause is a stale
  observation and refuses it. One statement — Postgres row locks order it
  against the unarchive's own `UPDATE`, and READ COMMITTED re-checks this
  predicate after waiting on a lock. Returns the number of rows paused.

  Modeled in tla/salix/SchedulePauseOnArchive.tla (`Paused`).
  """
  @spec pause_for_archived_agent(String.t(), pos_integer(), integer()) ::
          {:ok, non_neg_integer()} | {:error, :unavailable}
  def pause_for_archived_agent(agent_id, archive_epoch, updated_at)
      when is_binary(agent_id) and is_integer(archive_epoch) and archive_epoch > 0 and
             is_integer(updated_at) do
    marker = %{"paused_by" => @archive_pause_marker, "archive_epoch" => archive_epoch}

    {count, _} =
      from(r in Row,
        where:
          r.agent_id == ^agent_id and r.receiver == "agent" and r.status == "active" and
            fragment(
              "coalesce((? ->> 'unarchived_epoch')::bigint, 0) < ?",
              r.attrs,
              ^archive_epoch
            ),
        update: [
          set: [
            status: "paused",
            updated_at: ^updated_at,
            attrs: fragment("coalesce(?, '{}'::jsonb) || ?", r.attrs, type(^marker, :map))
          ]
        ]
      )
      |> Repo.update_all([])

    {:ok, count}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Resume the archive-paused agent-receiver rows of `agent_id` whose pause
  epoch is at most `archive_epoch`, clearing their markers. A user-paused
  row (no marker) stays paused.

  Two callers, two shapes:

    * `stamp: false` (default) — a pauser undoing its own stale pause, or the
      sweep reconciling a live record. Only marked rows are written. Returns
      the number of rows resumed.
    * `stamp: true` — the unarchive. EVERY agent-receiver row whose
      `unarchived_epoch` is below `archive_epoch` is written: marked rows are
      resumed, and all of them record `unarchived_epoch: archive_epoch`, the
      fence a later `pause_for_archived_agent/3` for this epoch refuses to
      cross. One statement, so a pause that raced ahead is resumed and a
      pause that arrives later is fenced. Returns the number of rows written.

  Modeled in tla/salix/SchedulePauseOnArchive.tla (`Undone` / `Resumed`).
  """
  @spec resume_archive_paused(String.t(), non_neg_integer(), integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :unavailable}
  def resume_archive_paused(agent_id, archive_epoch, updated_at, opts \\ [])
      when is_binary(agent_id) and is_integer(archive_epoch) and archive_epoch >= 0 and
             is_integer(updated_at) do
    if Keyword.get(opts, :stamp, false),
      do: resume_and_stamp(agent_id, archive_epoch, updated_at),
      else: resume_marked(agent_id, archive_epoch, updated_at)
  end

  defp resume_marked(agent_id, archive_epoch, updated_at) do
    {count, _} =
      from(r in Row,
        where:
          r.agent_id == ^agent_id and r.receiver == "agent" and r.status == "paused" and
            fragment("? ->> 'paused_by' = ?", r.attrs, ^@archive_pause_marker) and
            fragment("coalesce((? ->> 'archive_epoch')::bigint, 0) <= ?", r.attrs, ^archive_epoch),
        update: [
          set: [
            status: "active",
            updated_at: ^updated_at,
            attrs: fragment("(? - 'paused_by') - 'archive_epoch'", r.attrs)
          ]
        ]
      )
      |> Repo.update_all([])

    {:ok, count}
  rescue
    _ -> {:error, :unavailable}
  end

  defp resume_and_stamp(agent_id, archive_epoch, updated_at) do
    stamp = %{"unarchived_epoch" => archive_epoch}

    {count, _} =
      from(r in Row,
        where:
          r.agent_id == ^agent_id and r.receiver == "agent" and
            fragment(
              "coalesce((? ->> 'unarchived_epoch')::bigint, 0) < ?",
              r.attrs,
              ^archive_epoch
            ),
        update: [
          set: [
            status:
              fragment(
                "case when ? ->> 'paused_by' = ? then 'active' else ? end",
                r.attrs,
                ^@archive_pause_marker,
                r.status
              ),
            updated_at: ^updated_at,
            attrs:
              fragment(
                "((coalesce(?, '{}'::jsonb) - 'paused_by') - 'archive_epoch') || ?",
                r.attrs,
                type(^stamp, :map)
              )
          ]
        ]
      )
      |> Repo.update_all([])

    {:ok, count}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Recompute the `next_fire_at` bound from the CURRENT locked row. The exact
  value is derived by `next_fire_fun` from the row as it exists inside the
  transaction — never from a caller snapshot — so a concurrent recurrence
  update can never be overwritten with a stale derivation. Best-effort — the
  sweep already skipped the row either way.
  """
  @spec recompute_next_fire(String.t(), (sched_record() -> integer())) :: :ok
  def recompute_next_fire(id, next_fire_fun)
      when is_binary(id) and is_function(next_fire_fun, 1) do
    {:ok, _} =
      Repo.transaction(fn ->
        case Repo.one(from(r in Row, where: r.id == ^id, lock: "FOR UPDATE")) do
          nil ->
            :ok

          %Row{} = row ->
            next = next_fire_fun.(to_record(row))

            {1, _} =
              Repo.update_all(from(r in Row, where: r.id == ^id),
                set: [next_fire_at: next]
              )

            :ok
        end
      end)

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Monotonic anchor advance (the PG image of the legacy `advance_last_run` CAS):
  sets `last_run` only if it moves forward. The new `next_fire_at` is derived
  by `next_fire_fun` from the CURRENT locked row (with the advanced anchor
  applied) — never from a caller snapshot — so an advance resumed after a
  concurrent recurrence update derives the bound from the updated recurrence
  and the `next_fire_at <= true next fire` invariant holds.
  """
  @spec advance(String.t(), integer(), (sched_record() -> integer())) ::
          :ok | :unchanged | {:error, :not_found} | {:error, :unavailable}
  def advance(id, scheduled_for_ms, next_fire_fun)
      when is_binary(id) and is_integer(scheduled_for_ms) and is_function(next_fire_fun, 1) do
    Repo.transaction(fn ->
      case Repo.one(from(r in Row, where: r.id == ^id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:not_found)

        %Row{last_run: last_run} when is_integer(last_run) and last_run >= scheduled_for_ms ->
          :unchanged

        %Row{} = row ->
          advanced = row |> to_record() |> Map.put("last_run", scheduled_for_ms)
          next = next_fire_fun.(advanced)

          {1, _} =
            Repo.update_all(from(r in Row, where: r.id == ^id),
              set: [last_run: scheduled_for_ms, next_fire_at: next]
            )

          :ok
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, :not_found} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Idempotent import for the cutover step. A pre-existing identical row is fine;
  a pre-existing divergent row is a hard error (the equality gate must abort).
  `next_fire_at` is the caller-computed lower bound (the anchor).
  """
  @spec import_record(sched_record(), integer()) ::
          :ok | {:error, {:divergent_row, String.t()}}
  def import_record(%{"id" => id} = record, next_fire_at)
      when is_binary(id) and is_integer(next_fire_at) do
    Repo.insert_all(Row, [row_map(record, next_fire_at)],
      on_conflict: :nothing,
      conflict_target: [:id]
    )

    case Repo.get(Row, id) do
      %Row{} = landed ->
        if canonical(to_record(landed)) == canonical(record),
          do: :ok,
          else: {:error, {:divergent_row, id}}

      nil ->
        {:error, {:divergent_row, id}}
    end
  end

  @doc "Every row as a canonical record, for the cutover equality gate."
  @spec all_records() :: [sched_record()]
  def all_records do
    Row |> Repo.all() |> Enum.map(&to_record/1)
  end

  @doc """
  Canonical comparable shape of an S3-or-PG record: nil values dropped (an
  absent legacy key and a NULL column read back identically), DB-defaulted
  fields normalized in.
  """
  @spec canonical(sched_record()) :: sched_record()
  def canonical(record) when is_map(record) do
    record
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.put_new("receiver", "agent")
    |> Map.put_new("status", "active")
  end

  defp to_record(%Row{} = row) do
    core =
      %{
        "id" => row.id,
        "receiver" => row.receiver,
        "agent_id" => row.agent_id,
        "session_id" => row.session_id,
        "prompt" => row.prompt,
        "payload" => row.payload,
        "interval_minutes" => row.interval_minutes,
        "cron" => row.cron,
        "timezone" => row.timezone,
        "run_at" => row.run_at,
        "status" => row.status,
        "kind" => row.kind,
        "name" => row.name,
        "created_at" => row.created_at,
        "updated_at" => row.updated_at,
        "last_run" => row.last_run
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    Map.merge(attrs_map(row.attrs), core)
  end

  defp row_map(record, next_fire_at) do
    %{
      id: record["id"],
      receiver: record["receiver"] || "agent",
      agent_id: record["agent_id"],
      session_id: record["session_id"],
      prompt: record["prompt"],
      payload: record["payload"],
      interval_minutes: record["interval_minutes"],
      cron: record["cron"],
      timezone: record["timezone"],
      run_at: record["run_at"],
      status: record["status"] || "active",
      kind: record["kind"],
      name: record["name"],
      attrs: Map.drop(record, @known_keys),
      created_at: record["created_at"],
      updated_at: record["updated_at"],
      last_run: record["last_run"],
      next_fire_at: next_fire_at
    }
  end

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(_), do: %{}
end
