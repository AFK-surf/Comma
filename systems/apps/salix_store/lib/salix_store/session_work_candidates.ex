defmodule SalixStore.SessionWorkCandidates do
  @moduledoc """
  Token-addressed Postgres projection used to cold-discover unfinished Session work.

  Session state remains authoritative in S3. A row only identifies one
  mark-before-CAS candidate; callers must reread the exact Session and compare
  its candidate token and non-reusable storage revision before waking or
  deleting anything. Runtime writers are insert-only; the exclusive release
  backfill reconciles every visited Session address from one freshly reread
  authoritative Session. Stable authority removes every candidate at that
  address, while unfinished authority keeps only its exact token. Admission,
  exact revision-fenced retirement, and authoritative address reconciliation
  are modeled in `tla/salix/SessionWorkProjection.tla`.
  """

  import Ecto.Query

  alias SalixStore.{Repo, SessionWorkNotifications}

  @runtime_kinds ~w(internal)

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "session_work_candidates" do
      field(:candidate_token, :string, primary_key: true)
      field(:agent_id, :string)
      field(:runtime_kind, :string)
      field(:session_id, :string)
      field(:base_revision, :string)
      field(:due_at_ms, :integer)
      field(:reasons, {:array, :string})

      # Seconds, despite the physical column name. The value is the work
      # marker's own `updated_at`, minted by
      # `SalixAgent.SessionWorkIndex.mark/5` as `SystemsClock.system_time(:second)`,
      # and it is projected straight back out as `"updated_at"` — it is never
      # compared against a clock here. Contrast `due_at_ms` above, which really
      # is milliseconds and IS compared against `now_ms` in `due_page/2`: two
      # columns, one `_ms` suffix, two different units was the trap this name
      # closes.
      #
      # The Postgres column keeps its original name. Renaming it would need an
      # exclusive-phase release step (writer quiesce, per
      # docs/release-operations.md), which is
      # not a price worth paying for a naming defect on a rebuildable
      # projection — so the mapping lives here instead.
      field(:updated_at_seconds, :integer, source: :inserted_at_ms)
    end
  end

  @type cursor :: %{
          required(:agent_id) => String.t(),
          required(:runtime_kind) => String.t(),
          required(:session_id) => String.t(),
          required(:candidate_token) => String.t(),
          optional(:due_at_ms) => integer()
        }
  @type address_cursor :: %{
          required(:agent_id) => String.t(),
          required(:runtime_kind) => String.t(),
          required(:session_id) => String.t()
        }
  @type candidate_record :: %{optional(String.t()) => term()}

  @spec insert(candidate_record()) :: :ok | {:error, :invalid | :unavailable}
  def insert(%{} = record) do
    row = row_from_record(record)

    with true <- valid_row?(row),
         {:ok, notification} <- SessionWorkNotifications.encode(record) do
      Repo.transaction(fn ->
        Repo.insert_all(Row, [row],
          on_conflict: :nothing,
          conflict_target: [:candidate_token]
        )

        case Repo.query(
               "SELECT pg_notify($1, $2)",
               [SessionWorkNotifications.channel(), notification]
             ) do
          {:ok, _result} -> :ok
          {:error, reason} -> Repo.rollback({:notification_failed, reason})
        end
      end)
      |> case do
        {:ok, :ok} ->
          # The listener hears this after the commit, over its own
          # connection: a test clock counts it as work still under way.
          SessionWorkNotifications.expect_delivery(notification)
          :ok

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      _ -> {:error, :invalid}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Upsert authority and remove every other token at its exact Session address."
  @spec reconcile_address_from_authority(candidate_record()) ::
          :ok | {:error, :invalid | :unavailable}
  def reconcile_address_from_authority(%{} = record) do
    row = row_from_record(record)

    if valid_row?(row) do
      Repo.insert_all(Row, [row],
        on_conflict:
          {:replace,
           [
             :agent_id,
             :runtime_kind,
             :session_id,
             :base_revision,
             :due_at_ms,
             :reasons,
             :updated_at_seconds
           ]},
        conflict_target: [:candidate_token]
      )

      Row
      |> where(
        [r],
        r.agent_id == ^row.agent_id and r.runtime_kind == ^row.runtime_kind and
          r.session_id == ^row.session_id and r.candidate_token != ^row.candidate_token
      )
      |> Repo.delete_all()

      :ok
    else
      {:error, :invalid}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Delete every candidate at one exact authoritative Session address."
  @spec delete_address(map()) :: :ok | {:error, :invalid | :unavailable}
  def delete_address(%{
        agent_id: agent_id,
        runtime_kind: runtime_kind,
        session_id: session_id
      })
      when is_binary(agent_id) and agent_id != "" and
             runtime_kind in ["internal", "external", :internal, :external] and
             is_binary(session_id) and session_id != "" do
    Row
    |> where(
      [r],
      r.agent_id == ^agent_id and r.runtime_kind == ^to_string(runtime_kind) and
        r.session_id == ^session_id
    )
    |> Repo.delete_all()

    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  def delete_address(_address), do: {:error, :invalid}

  @spec delete_exact(String.t()) :: :ok | {:error, :unavailable}
  def delete_exact(candidate_token) when is_binary(candidate_token) and candidate_token != "" do
    Row
    |> where([r], r.candidate_token == ^candidate_token)
    |> Repo.delete_all()

    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  def delete_exact(_candidate_token), do: :ok

  @doc "Delete only when the token and authoritative Session address all match."
  @spec delete_scoped(String.t(), map()) :: :ok | {:error, :unavailable}
  def delete_scoped(
        candidate_token,
        %{agent_id: agent_id, runtime_kind: runtime_kind, session_id: session_id}
      )
      when is_binary(candidate_token) and candidate_token != "" do
    Row
    |> where(
      [r],
      r.candidate_token == ^candidate_token and r.agent_id == ^agent_id and
        r.runtime_kind == ^to_string(runtime_kind) and r.session_id == ^session_id
    )
    |> Repo.delete_all()

    :ok
  rescue
    _ -> {:error, :unavailable}
  end

  def delete_scoped(_candidate_token, _address), do: :ok

  @spec fetch_exact(String.t()) ::
          {:ok, candidate_record()} | {:error, :not_found | :unavailable}
  def fetch_exact(candidate_token) when is_binary(candidate_token) and candidate_token != "" do
    case Repo.get(Row, candidate_token) do
      %Row{} = row -> {:ok, to_record(row)}
      nil -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  def fetch_exact(_candidate_token), do: {:error, :not_found}

  @doc "Return the physical candidate-row count for rollout/drain audits."
  @spec count() :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def count do
    {:ok, Repo.aggregate(Row, :count)}
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "List distinct candidate Session addresses in a bounded immutable keyset order."
  @spec list_addresses(keyword()) ::
          {:ok, %{addresses: [address_cursor()], eof: boolean()}} | {:error, :unavailable}
  def list_addresses(opts \\ []) do
    limit = bounded_limit(opts[:limit])

    query =
      from(r in Row,
        group_by: [r.agent_id, r.runtime_kind, r.session_id],
        order_by: [asc: r.agent_id, asc: r.runtime_kind, asc: r.session_id],
        select: %{
          agent_id: r.agent_id,
          runtime_kind: r.runtime_kind,
          session_id: r.session_id
        },
        limit: ^(limit + 1)
      )
      |> after_address(opts[:after])

    addresses = Repo.all(query)

    {:ok, %{addresses: Enum.take(addresses, limit), eof: length(addresses) <= limit}}
  rescue
    _ -> {:error, :unavailable}
  end

  @spec list_eager(keyword()) ::
          {:ok, %{records: [candidate_record()], eof: boolean()}} | {:error, :unavailable}
  def list_eager(opts \\ []) do
    limit = bounded_limit(opts[:limit])

    Row
    |> after_eager(opts[:after])
    |> eager_ready()
    |> eager_page(limit)
    |> page(limit)
  rescue
    _ -> {:error, :unavailable}
  end

  @spec list_due(integer(), keyword()) ::
          {:ok, %{records: [candidate_record()], eof: boolean()}} | {:error, :unavailable}
  def list_due(now_ms, opts \\ []) when is_integer(now_ms) do
    limit = bounded_limit(opts[:limit])

    query =
      from(r in Row,
        where: not is_nil(r.due_at_ms) and r.due_at_ms <= ^now_ms,
        order_by: [
          asc: r.due_at_ms,
          asc: r.agent_id,
          asc: r.runtime_kind,
          asc: r.session_id,
          asc: r.candidate_token
        ],
        limit: ^(limit + 1)
      )
      |> after_deferred(opts[:after])

    page(query, limit)
  rescue
    _ -> {:error, :unavailable}
  end

  @spec list_all(keyword()) :: {:ok, [candidate_record()]} | {:error, :unavailable}
  def list_all(opts \\ []) do
    query =
      from(r in Row,
        order_by: [
          asc: r.agent_id,
          asc: r.runtime_kind,
          asc: r.session_id,
          asc: r.candidate_token
        ]
      )

    records =
      query
      |> Repo.all()
      |> Enum.map(&to_record/1)

    records =
      case opts[:lane] do
        :eager -> Enum.filter(records, &is_nil(&1["recover_after_ms"]))
        :deferred -> Enum.filter(records, &is_integer(&1["recover_after_ms"]))
        _ -> records
      end

    {:ok, records}
  rescue
    _ -> {:error, :unavailable}
  end

  defp after_address(query, nil), do: query

  defp after_address(query, %{agent_id: a, runtime_kind: r, session_id: s}) do
    from(row in query,
      where:
        fragment(
          "(?, ?, ?) > (?, ?, ?)",
          row.agent_id,
          row.runtime_kind,
          row.session_id,
          ^a,
          ^r,
          ^s
        )
    )
  end

  defp after_address(query, _invalid), do: from(row in query, where: false)

  defp after_eager(query, nil), do: query

  defp after_eager(query, %{agent_id: a, runtime_kind: r, session_id: s, candidate_token: t}) do
    from(row in query,
      where:
        fragment(
          "(?, ?, ?, ?) > (?, ?, ?, ?)",
          row.agent_id,
          row.runtime_kind,
          row.session_id,
          row.candidate_token,
          ^a,
          ^r,
          ^s,
          ^t
        )
    )
  end

  defp after_eager(query, _invalid), do: from(row in query, where: false)

  defp after_deferred(query, nil), do: query

  defp after_deferred(query, %{
         due_at_ms: due,
         agent_id: a,
         runtime_kind: r,
         session_id: s,
         candidate_token: t
       }) do
    from(row in query,
      where:
        fragment(
          "(?, ?, ?, ?, ?) > (?, ?, ?, ?, ?)",
          row.due_at_ms,
          row.agent_id,
          row.runtime_kind,
          row.session_id,
          row.candidate_token,
          ^due,
          ^a,
          ^r,
          ^s,
          ^t
        )
    )
  end

  defp after_deferred(query, _invalid), do: from(row in query, where: false)

  defp page(query, limit) do
    rows = Repo.all(query)
    eof = length(rows) <= limit
    {:ok, %{records: rows |> Enum.take(limit) |> Enum.map(&to_record/1), eof: eof}}
  end

  @doc false
  def to_record(%Row{} = row) do
    %{
      "agent_id" => row.agent_id,
      "runtime_kind" => row.runtime_kind,
      "session_id" => row.session_id,
      "token" => row.candidate_token,
      "base_revision" => row.base_revision,
      "reasons" => row.reasons,
      "updated_at" => row.updated_at_seconds
    }
    |> maybe_put("recover_after_ms", row.due_at_ms)
  end

  @doc false
  def valid_row?(row) do
    is_binary(row.candidate_token) and row.candidate_token != "" and
      is_binary(row.agent_id) and row.agent_id != "" and
      row.runtime_kind in @runtime_kinds and is_binary(row.session_id) and
      (is_nil(row.base_revision) or
         (is_binary(row.base_revision) and row.base_revision != "")) and
      (is_nil(row.due_at_ms) or is_integer(row.due_at_ms)) and
      is_list(row.reasons) and Enum.all?(row.reasons, &is_binary/1) and
      is_integer(row.updated_at_seconds)
  end

  @doc false
  def row_from_record(record) do
    %{
      candidate_token: record["token"],
      agent_id: record["agent_id"],
      runtime_kind: record["runtime_kind"],
      session_id: record["session_id"],
      base_revision: record["base_revision"],
      due_at_ms: record["recover_after_ms"],
      reasons: record["reasons"],
      updated_at_seconds: record["updated_at"]
    }
  end

  @doc false
  def bounded_limit(value) when is_integer(value) and value > 0, do: min(value, 128)
  def bounded_limit(_value), do: 100

  defp eager_page(query, limit) do
    from(r in query,
      order_by: [asc: r.agent_id, asc: r.runtime_kind, asc: r.session_id, asc: r.candidate_token],
      limit: ^(limit + 1)
    )
  end

  # Matches the partial index session_work_candidates_ready_eager_cursor_idx.
  defp eager_ready(query) do
    from(r in query,
      where:
        is_nil(r.due_at_ms) and
          (not fragment("? @> ARRAY['runtime_wait']::text[]", r.reasons) or
             not fragment(
               "? <@ ARRAY['external_callback_tool_call','capability_deadline','wait_deadline','llm_retry','runtime_wait','provider_cutover_parked']::text[]",
               r.reasons
             ))
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
