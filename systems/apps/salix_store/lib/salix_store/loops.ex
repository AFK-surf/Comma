defmodule SalixStore.Loops do
  @moduledoc """
  Postgres data access for Agent background Loop definitions
  (docs/salix/tasks-background-execution.md, "Background loops").

  Records cross this boundary as string-keyed maps; every timestamp is a unix
  millisecond integer. Domain rules (quotas, capability allowlists, notify
  budgets, incarnation fencing) live in `SalixAgent.Loops`; this module only
  persists rows and applies the owner predicates atomically.

  Every mutating entry point that has an owner takes the owner as part of its
  predicate (`agent_id`), so one Agent's request can never touch another
  Agent's row. Incarnation-fenced writes take the incarnation the caller
  observed and write nothing when the row has moved on.

  Store faults surface as `{:error, :unavailable}` on every entry point.
  """

  import Ecto.Query

  alias SalixStore.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "agent_loops" do
      field(:id, :string, primary_key: true)
      field(:tenant_id, :string)
      field(:group_id, :string)
      field(:agent_id, :string)
      field(:session_id, :string)
      field(:name, :string)
      field(:webhook_secret, :string, redact: true)
      field(:composio_trigger, :map)
      field(:elf_sha256, :string)
      field(:elf_path, :string)
      field(:config, :map)
      field(:status, :string)
      field(:paused_by, :string)
      field(:failure, :string)
      field(:exit_code, :integer)
      field(:checkpoint, :map)
      field(:pending_events, :map)
      field(:incarnation, :integer)
      field(:incarnation_node, :string)
      field(:incarnation_session, :string)
      field(:object_id, :string)
      field(:notify_window_start_ms, :integer)
      field(:notify_window_count, :integer)
      field(:notify_limited_since_ms, :integer)
      field(:restart_window_start_ms, :integer)
      field(:restart_count, :integer)
      field(:ifc, :map)
      field(:created_at, :integer)
      field(:updated_at, :integer)
      field(:last_notified_at, :integer)
    end
  end

  defmodule AckRow do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "agent_loop_acks" do
      field(:loop_id, :string, primary_key: true)
      field(:event_id, :string, primary_key: true)
      field(:acked_at, :integer)
    end
  end

  @summary_fields Row.__schema__(:fields) -- [:pending_events]

  @type loop_record :: %{optional(String.t()) => term()}

  @statuses ~w(active paused failed)

  @doc "Statuses a Loop row can hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec get(String.t()) :: {:ok, loop_record()} | {:error, :not_found} | {:error, :unavailable}
  def get(id) when is_binary(id) do
    case Repo.get(Row, id) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Point read scoped to the owning Agent. Another owner's row reads as missing."
  @spec get_agent_owned(String.t(), String.t()) ::
          {:ok, loop_record()} | {:error, :not_found} | {:error, :unavailable}
  def get_agent_owned(id, agent_id) when is_binary(id) and is_binary(agent_id) do
    case Repo.one(from(r in Row, where: r.id == ^id and r.agent_id == ^agent_id)) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Point read scoped to a Group, for the external event ingress."
  @spec get_group_owned(String.t(), String.t()) ::
          {:ok, loop_record()} | {:error, :not_found} | {:error, :unavailable}
  def get_group_owned(id, group_id) when is_binary(id) and is_binary(group_id) do
    case Repo.one(from(r in Row, where: r.id == ^id and r.group_id == ^group_id)) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Resolve a secret URL to its Loop with an indexed point read."
  def get_by_webhook_secret(secret) when is_binary(secret) and byte_size(secret) == 43 do
    case Repo.one(from(r in Row, where: r.webhook_secret == ^secret), log: false) do
      nil -> {:error, :not_found}
      %Row{} = row -> {:ok, to_record(row)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def get_by_webhook_secret(_secret), do: {:error, :not_found}

  @doc "Bind one provider trigger to its owning Loop. Nil removes the binding."
  def bind_composio_trigger(id, agent_id, binding) do
    __MODULE__.update(id, fn row ->
      if row["agent_id"] == agent_id,
        do: {:ok, Map.put(row, "composio_trigger", binding)},
        else: {:error, :not_found}
    end)
  end

  @doc "Indexed active subscribers. A Group admits at most 100 active Loops."
  def composio_subscribers(group_id, trigger_id) do
    rows =
      Repo.all(
        from(r in Row,
          where:
            r.group_id == ^group_id and r.status == "active" and
              fragment("?->>'trigger_id'", r.composio_trigger) == ^trigger_id,
          select: struct(r, ^@summary_fields),
          limit: 101
        )
      )

    if length(rows) > 100,
      do: {:error, :subscriber_limit},
      else: {:ok, Enum.map(rows, &to_record/1)}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Every Loop owned by `agent_id`, oldest first. ELF bytes are omitted."
  @spec list_by_agent(String.t()) :: {:ok, [loop_record()]} | {:error, :unavailable}
  def list_by_agent(agent_id) when is_binary(agent_id) do
    rows =
      from(r in Row,
        where: r.agent_id == ^agent_id,
        order_by: [asc: r.created_at, asc: r.id],
        select: struct(r, ^@summary_fields)
      )
      |> Repo.all()
      |> Enum.map(&to_record/1)

    {:ok, rows}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "At most 16 product monitors per Router, including accepted mail bindings."
  def proactive_monitors(agent_id) do
    rows =
      from(r in Row,
        where:
          r.agent_id == ^agent_id and
            fragment(
              "(?->'comma_proactive' IS NOT NULL OR ?->'comma_mail' IS NOT NULL)",
              r.config,
              r.config
            ),
        order_by: [desc: r.created_at],
        limit: 17,
        select: struct(r, ^@summary_fields)
      )
      |> Repo.all()
      |> Enum.map(&to_record/1)

    if length(rows) <= 16, do: {:ok, rows}, else: {:error, :mail_monitor_capacity}
  rescue
    _ -> {:error, :unavailable}
  end

  def get_by_agent_path(agent_id, path) do
    case Repo.one(
           from(r in Row,
             where: r.agent_id == ^agent_id and r.elf_path == ^path,
             order_by: [asc: r.created_at],
             limit: 1
           )
         ) do
      nil -> {:error, :not_found}
      row -> {:ok, to_record(row)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Reserve one paused product program through the existing Group admission lock."
  def create_paused_by_path(%{"status" => "paused"} = record) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        "agent_loops:" <> record["group_id"]
      ])

      result =
        case get_by_agent_path(record["agent_id"], record["elf_path"]) do
          {:ok, row} ->
            {:ok, row}

          {:error, :not_found} ->
            with :ok <- mail_binding_capacity(record), do: create(record)

          error ->
            error
        end

      case result do
        {:ok, row} -> row
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Bind mail within the same bounded settings admission as product setup."
  def update_mail_binding(id, fun) do
    with {:ok, row} <- get(id) do
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "agent_loops:" <> row["group_id"]
        ])

        result =
          __MODULE__.update(id, fn current ->
            with :ok <- mail_binding_capacity(current), do: fun.(current)
          end)

        case result do
          {:ok, updated} -> updated
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp mail_binding_capacity(row) do
    case proactive_monitors(row["agent_id"]) do
      {:ok, rows} ->
        if length(rows) < 16 or Enum.any?(rows, &(&1["id"] == row["id"])),
          do: :ok,
          else: {:error, :mail_monitor_capacity}

      error ->
        error
    end
  end

  @doc "The active Loops of `agent_id`, for adoption."
  @spec list_active_by_agent(String.t()) :: {:ok, [loop_record()]} | {:error, :unavailable}
  def list_active_by_agent(agent_id) when is_binary(agent_id) do
    rows =
      from(r in Row,
        where: r.agent_id == ^agent_id and r.status == "active",
        select: struct(r, ^@summary_fields),
        order_by: [asc: r.created_at, asc: r.id]
      )
      |> Repo.all()
      |> Enum.map(&to_record/1)

    {:ok, rows}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "How many active Loops `agent_id` and its Group hold: `{agent_count, group_count}`."
  @spec active_counts(String.t(), String.t()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, :unavailable}
  def active_counts(agent_id, group_id) when is_binary(agent_id) and is_binary(group_id) do
    {:ok, active_counts!(agent_id, group_id)}
  rescue
    _ -> {:error, :unavailable}
  end

  defp active_counts!(agent_id, group_id) do
    agent =
      Repo.one(
        from(r in Row,
          where: r.agent_id == ^agent_id and r.status == "active",
          select: count(r.id)
        )
      )

    group =
      Repo.one(
        from(r in Row,
          where: r.group_id == ^group_id and r.status == "active",
          select: count(r.id)
        )
      )

    {agent, group}
  end

  @doc "Whether `agent_id` holds at least one active Loop."
  @spec any_active?(String.t()) :: boolean()
  def any_active?(agent_id) when is_binary(agent_id) do
    Repo.exists?(from(r in Row, where: r.agent_id == ^agent_id and r.status == "active"))
  rescue
    _ -> false
  end

  @typedoc "Keyset position in the stranded traversal: the last row examined."
  @type stranded_cursor :: {updated_at_ms :: integer(), id :: String.t()} | nil

  @doc """
  Active Loops with no live incarnation: no object attached, or attached on
  a node outside `live_nodes`. Ordered by `(updated_at, id)`, at most
  `limit` rows strictly after `cursor` (`nil` starts from the beginning).
  The Reconciler's recovery pass walks the whole set one
  page per sweep through this keyset, so a page that cannot make progress
  never hides the rows behind it.
  """
  @spec list_active_stranded([String.t()], pos_integer(), stranded_cursor()) ::
          {:ok, [loop_record()]} | {:error, :unavailable}
  def list_active_stranded(live_nodes, limit, cursor \\ nil)
      when is_list(live_nodes) and is_integer(limit) and limit > 0 do
    query =
      from(r in Row,
        where:
          r.status == "active" and
            (is_nil(r.object_id) or r.incarnation_node not in ^live_nodes),
        order_by: [asc: r.updated_at, asc: r.id],
        select: struct(r, ^@summary_fields),
        limit: ^limit
      )

    query =
      case cursor do
        {updated_at, id} when is_integer(updated_at) and is_binary(id) ->
          from(r in query,
            where: r.updated_at > ^updated_at or (r.updated_at == ^updated_at and r.id > ^id)
          )

        _ ->
          query
      end

    rows = query |> Repo.all() |> Enum.map(&to_record/1)
    {:ok, rows}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Create-once insert."
  @spec create(loop_record()) ::
          {:ok, loop_record()} | {:error, :already_exists} | {:error, :unavailable}
  def create(%{"id" => id} = record) when is_binary(id) do
    case Repo.insert_all(Row, [row_map(record)],
           on_conflict: :nothing,
           conflict_target: [:id],
           log: false
         ) do
      {1, _} -> get(id)
      {0, _} -> {:error, :already_exists}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @typedoc "A mutation `admit_active/4` applies once the quota admits it."
  @type admitted_mutation ::
          {:create, loop_record()}
          | {:update, String.t(), (loop_record() -> {:ok, loop_record()} | {:error, term()})}

  @doc """
  Admit one transition into `active` against the quota, atomically.

  Takes the Group's advisory transaction lock, counts the active Loops of
  `agent_id` and `group_id`, and applies `mutation` only while both counts
  are below `{max_agent, max_group}`; concurrent admissions for the same
  Group serialize on the lock, so the count they read is the count they
  commit against. A refused admission is `{:error, {:quota, :agent | :group,
  limit}}`; an error from the mutation rolls the transaction back.
  """
  @spec admit_active(
          String.t(),
          String.t(),
          {pos_integer(), pos_integer()},
          admitted_mutation()
        ) :: {:ok, loop_record()} | {:error, term()}
  def admit_active(agent_id, group_id, {max_agent, max_group}, mutation)
      when is_binary(agent_id) and is_binary(group_id) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["agent_loops:" <> group_id])
      {agent_count, group_count} = active_counts!(agent_id, group_id)

      cond do
        agent_count >= max_agent -> Repo.rollback({:quota, :agent, max_agent})
        group_count >= max_group -> Repo.rollback({:quota, :group, max_group})
        true -> apply_mutation!(mutation)
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  defp apply_mutation!({:create, %{"id" => id} = record}) do
    case Repo.insert_all(Row, [row_map(record)],
           on_conflict: :nothing,
           conflict_target: [:id],
           log: false
         ) do
      {1, _} ->
        case Repo.one(from(r in Row, where: r.id == ^id)) do
          %Row{} = row -> to_record(row)
          nil -> Repo.rollback(:not_found)
        end

      {0, _} ->
        Repo.rollback(:already_exists)
    end
  end

  defp apply_mutation!({:update, id, fun}) when is_binary(id) and is_function(fun, 1),
    do: locked_update!(id, fun)

  @doc """
  Serialized read-modify-write under a row lock. `fun` receives the current
  record and returns `{:ok, record}` to write, `{:unchanged, record}` to
  write nothing, or `{:error, reason}` to abort.
  """
  @spec update(String.t(), (loop_record() ->
                              {:ok, loop_record()}
                              | {:unchanged, loop_record()}
                              | {:error, term()})) ::
          {:ok, loop_record()} | {:error, :not_found} | {:error, term()}
  def update(id, fun) when is_binary(id) and is_function(fun, 1) do
    Repo.transaction(fn -> locked_update!(id, fun) end)
  rescue
    _ -> {:error, :unavailable}
  end

  # Inside a transaction: the row under FOR UPDATE through `fun`, written
  # back when it returns `{:ok, record}`; errors roll the transaction back.
  defp locked_update!(id, fun) do
    case Repo.one(from(r in Row, where: r.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:not_found)

      %Row{} = row ->
        case fun.(to_record(row)) do
          {:ok, record} ->
            updates = record |> row_map() |> Map.drop([:id]) |> Map.to_list()

            {1, _} =
              Repo.update_all(from(r in Row, where: r.id == ^id), [set: updates], log: false)

            record

          {:unchanged, record} ->
            record

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  @doc "Atomic owner-scoped delete."
  @spec delete_agent_owned(String.t(), String.t()) ::
          :ok | {:error, :not_found} | {:error, :unavailable}
  def delete_agent_owned(id, agent_id) when is_binary(id) and is_binary(agent_id) do
    case Repo.delete_all(from(r in Row, where: r.id == ^id and r.agent_id == ^agent_id)) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Bulk status transition for one Agent: every row in `from_status` becomes
  `to_status` with `paused_by`. Returns the number of rows written. Used by
  archive (active -> paused/archive) and unarchive (paused/archive -> active).
  """
  @spec transition_by_agent(
          String.t(),
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil,
          integer()
        ) ::
          {:ok, non_neg_integer()} | {:error, :unavailable}
  def transition_by_agent(agent_id, from_status, from_paused_by, to_status, to_paused_by, now_ms)
      when is_binary(agent_id) and is_binary(from_status) and is_binary(to_status) and
             is_integer(now_ms) do
    query = from(r in Row, where: r.agent_id == ^agent_id and r.status == ^from_status)

    query =
      case from_paused_by do
        nil -> query
        value -> from(r in query, where: r.paused_by == ^value)
      end

    {count, _} =
      Repo.update_all(query,
        set: [status: to_status, paused_by: to_paused_by, updated_at: now_ms]
      )

    {:ok, count}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Persist an admitted event under the Loop lock before replying to its sender."
  def admit_event(observed, event, now_ms, limit, deadline_ms) do
    id = observed["id"]
    event_id = event["event_id"]

    Repo.transaction(fn ->
      case Repo.one(from(r in Row, where: r.id == ^id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:not_found)

        row ->
          current = to_record(row)
          pending = current["pending_events"] || %{}

          cond do
            current["status"] != "active" ->
              Repo.rollback({:not_active, current["status"]})

            Enum.any?(
              ~w(agent_id group_id webhook_secret composio_trigger),
              &(current[&1] != observed[&1])
            ) ->
              Repo.rollback(:binding_changed)

            Map.has_key?(pending, event_id) or
                Repo.exists?(
                  from(a in AckRow, where: a.loop_id == ^id and a.event_id == ^event_id)
                ) ->
              %{"accepted" => true, "duplicate" => true}

            map_size(pending) >= limit ->
              Repo.rollback(:mailbox_full)

            true ->
              entry = Map.put(event, "deadline_ms", now_ms + deadline_ms)
              pending = Map.put(pending, event_id, entry)

              Repo.update_all(
                from(r in Row, where: r.id == ^id),
                [set: [pending_events: pending, updated_at: now_ms]],
                log: false
              )

              %{"accepted" => true, "duplicate" => false}
          end
      end
    end)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Acknowledge and remove pending data atomically, fenced by the current guest."
  def settle_event(loop_id, incarnation, event_id, now_ms) do
    Repo.transaction(fn ->
      case Repo.one(from(r in Row, where: r.id == ^loop_id, lock: "FOR UPDATE")) do
        %Row{incarnation: ^incarnation, status: "active"} = row ->
          Repo.insert_all(AckRow, [%{loop_id: loop_id, event_id: event_id, acked_at: now_ms}],
            on_conflict: :nothing,
            conflict_target: [:loop_id, :event_id]
          )

          pending = Map.delete(row.pending_events || %{}, event_id)

          Repo.update_all(
            from(r in Row, where: r.id == ^loop_id),
            [set: [pending_events: pending, updated_at: now_ms]],
            log: false
          )

          :ok

        _ ->
          Repo.rollback(:stale_incarnation)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  end

  # ---- acknowledgements --------------------------------------------------

  @spec acked?(String.t(), String.t()) :: boolean()
  def acked?(loop_id, event_id) when is_binary(loop_id) and is_binary(event_id) do
    Repo.exists?(from(a in AckRow, where: a.loop_id == ^loop_id and a.event_id == ^event_id))
  rescue
    _ -> false
  end

  @doc "Drop acknowledgements older than `before_ms`. Returns the number removed."
  @spec prune_acks(integer()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def prune_acks(before_ms) when is_integer(before_ms) do
    {count, _} = Repo.delete_all(from(a in AckRow, where: a.acked_at < ^before_ms))
    {:ok, count}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Drop the acknowledgements of one deleted Loop."
  @spec delete_acks(String.t()) :: :ok | {:error, :unavailable}
  def delete_acks(loop_id) when is_binary(loop_id) do
    _ = Repo.delete_all(from(a in AckRow, where: a.loop_id == ^loop_id))
    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  # ---- codecs --------------------------------------------------------------

  @fields ~w(id tenant_id group_id agent_id session_id name webhook_secret composio_trigger elf_sha256 elf_path config status paused_by failure exit_code checkpoint pending_events incarnation incarnation_node incarnation_session object_id notify_window_start_ms notify_window_count notify_limited_since_ms restart_window_start_ms restart_count ifc created_at updated_at last_notified_at)

  @doc false
  def fields, do: @fields

  defp to_record(%Row{} = row) do
    Enum.reduce(@fields, %{}, fn field, acc ->
      Map.put(acc, field, Map.get(row, String.to_existing_atom(field)))
    end)
  end

  defp row_map(record) do
    %{
      id: record["id"],
      tenant_id: record["tenant_id"],
      group_id: record["group_id"],
      agent_id: record["agent_id"],
      session_id: record["session_id"],
      name: record["name"],
      webhook_secret: record["webhook_secret"],
      composio_trigger: record["composio_trigger"],
      elf_sha256: record["elf_sha256"],
      elf_path: record["elf_path"],
      config: record["config"] || %{},
      status: record["status"] || "active",
      paused_by: record["paused_by"],
      failure: record["failure"],
      exit_code: record["exit_code"],
      checkpoint: record["checkpoint"],
      pending_events: record["pending_events"] || %{},
      incarnation: record["incarnation"] || 0,
      incarnation_node: record["incarnation_node"],
      incarnation_session: record["incarnation_session"],
      object_id: record["object_id"],
      notify_window_start_ms: record["notify_window_start_ms"],
      notify_window_count: record["notify_window_count"] || 0,
      notify_limited_since_ms: record["notify_limited_since_ms"],
      restart_window_start_ms: record["restart_window_start_ms"],
      restart_count: record["restart_count"] || 0,
      ifc: record["ifc"] || %{},
      created_at: record["created_at"],
      updated_at: record["updated_at"] || record["created_at"],
      last_notified_at: record["last_notified_at"]
    }
  end
end
