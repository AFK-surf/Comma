defmodule SalixStore.AgentPGStore do
  @moduledoc """
  PostgreSQL authority for Agent configuration, root state and ownership.

  Configuration and root revisions are independent. Ownership columns supply
  the Head's epoch, owner and lease; the root payload holds the remaining Head
  fields, state machine and state. All lease decisions use the database clock.
  """

  alias SalixStore.{Codec, Head, Repo, StateMachine}
  alias SalixStore.Agent.Owned

  # tla/salix/HeadCommit.tla maps root_revision to its conditional-value version.
  # Epoch and root writes share the same Agent row; creation is outside that model.
  @ttl_ms 60_000
  @claim_retries 5
  @cleanup_page_size 128
  @root_columns "agent_id, owner_node, owner_epoch, lease_until, root_revision, root_payload, config_revision"

  defmodule Pending do
    @moduledoc "A frozen Agent mutation whose database result is not yet known."
    @derive {Inspect, only: [:kind, :agent_id, :expected_revision, :epoch]}
    defstruct [
      :kind,
      :agent_id,
      :sql,
      :params,
      :expected_revision,
      :epoch,
      :node_id,
      :payload,
      :previous_payload,
      :owned,
      :record,
      :ttl_ms,
      :lease_until,
      :prev_owner_node
    ]
  end

  @doc "Create the complete configuration and initial claimed root together."
  def create(agent_id, node_id, sm, record, opts \\ []),
    do: create_row(agent_id, node_id, sm, record, opts, 1)

  @doc "Reserve creation with complete configuration before external materialization."
  def begin_create(agent_id, node_id, sm, record, opts \\ []),
    do: create_row(agent_id, node_id, sm, record, opts, 0)

  defp create_row(agent_id, node_id, sm, record, opts, config_revision) do
    state = sm.init(agent_id)
    ttl_ms = Keyword.get(opts, :ttl_ms, @ttl_ms)

    head = %Head{
      epoch: 1,
      owner_node: node_id,
      commit_uuid: uuid(),
      journal_tail: %{epoch: 1, seq: 0},
      snapshot_seq: 0,
      format_version: 2,
      hot: StateMachine.hot(sm, state)
    }

    payload = encode_root(head, sm, state)

    pending = %Pending{
      kind: if(config_revision == 0, do: :begin_create, else: :create),
      agent_id: agent_id,
      expected_revision: 0,
      epoch: 1,
      node_id: node_id,
      payload: payload,
      ttl_ms: ttl_ms,
      owned: %Owned{agent_id: agent_id, node_id: node_id, sm: sm, ttl_ms: ttl_ms},
      sql: """
      INSERT INTO salix_agents
        (agent_id, tenant_id, group_id, role, archived_at, config_revision,
         config_payload, owner_node, owner_epoch, lease_until, root_revision, root_payload, router_session_id)
      VALUES ($1, $2, $3, $4, $5, $10, $6, $7, 1,
              clock_timestamp() + $8 * interval '1 millisecond', 1, $9, $11)
      ON CONFLICT (agent_id) DO NOTHING
      RETURNING #{@root_columns}
      """,
      params: [
        agent_id,
        Map.fetch!(record, "tenant_id"),
        Map.fetch!(record, "group_id"),
        Map.fetch!(record, "role"),
        archived_at(record),
        encode_config(agent_id, record),
        node_id,
        ttl_ms,
        payload,
        config_revision,
        record["router_session_id"]
      ]
    }

    execute(pending)
  end

  @doc "Import a complete Agent without granting execution authority."
  def seed(agent_id, state, sm, record, opts \\ []) do
    seq = Keyword.get(opts, :seq, 0)
    epoch = Keyword.get(opts, :epoch, 0)

    head = %Head{
      epoch: epoch,
      journal_tail: %{epoch: 0, seq: seq},
      snapshot_seq: seq,
      message_id_hwm: max(Keyword.get(opts, :hwm, 0), 0),
      format_version: 2,
      hot: StateMachine.hot(sm, state)
    }

    payload = encode_root(head, sm, state)

    pending = %Pending{
      kind: :seed,
      agent_id: agent_id,
      expected_revision: 0,
      epoch: epoch,
      node_id: nil,
      payload: payload,
      owned: %Owned{agent_id: agent_id, sm: sm},
      sql: """
      INSERT INTO salix_agents
        (agent_id, tenant_id, group_id, role, archived_at, config_revision,
         config_payload, owner_node, owner_epoch, lease_until, root_revision, root_payload, router_session_id)
      VALUES ($1, $2, $3, $4, $5, 1, $6, NULL, $7, NULL, 1, $8, $9)
      ON CONFLICT (agent_id) DO NOTHING
      RETURNING #{@root_columns}
      """,
      params: [
        agent_id,
        Map.fetch!(record, "tenant_id"),
        Map.fetch!(record, "group_id"),
        Map.fetch!(record, "role"),
        archived_at(record),
        encode_config(agent_id, record),
        epoch,
        payload,
        record["router_session_id"]
      ]
    }

    case execute(pending) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc "Import the complete old root on the release transaction's connection."
  def import_root!(agent_id, %Head{} = head, sm, state, record),
    do: import_roots!([{agent_id, head, sm, state, record}])

  @doc "Import bounded complete roots with the same owner encoding."
  def import_roots!(roots) do
    rows =
      Enum.map(roots, fn {agent_id, head, sm, state, record} ->
        import_root_row(agent_id, head, sm, state, record)
      end)

    SalixStore.PGAuthorityImport.insert_exact_many!("salix_agents", ["agent_id"], rows)
  end

  defp import_root_row(agent_id, %Head{} = head, sm, state, record) do
    head = %{head | owner_node: nil, lease_until: nil}

    %{
      "agent_id" => agent_id,
      "tenant_id" => Map.fetch!(record, "tenant_id"),
      "group_id" => Map.fetch!(record, "group_id"),
      "role" => Map.fetch!(record, "role"),
      "archived_at" => archived_at(record),
      "config_revision" => 1,
      "config_payload" => encode_config(agent_id, record),
      "owner_node" => nil,
      "owner_epoch" => head.epoch,
      "lease_until" => nil,
      "root_revision" => 1,
      "root_payload" => encode_root(head, sm, state),
      "router_session_id" => record["router_session_id"]
    }
  end

  @doc "Read configuration with the revision required by put_config/3."
  def read_config(agent_id) do
    case query(
           "SELECT config_revision, config_payload FROM salix_agents WHERE agent_id = $1 AND config_revision > 0",
           [
             agent_id
           ]
         ) do
      {:ok, %{rows: [[revision, payload]]}} ->
        {:ok, %{revision: revision, record: Codec.decode_snapshot(payload)}}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  @doc "Update configuration at its own revision without changing the root."
  def put_config(agent_id, record, expected_revision) do
    agent_id |> prepare_config(record, expected_revision) |> execute()
  end

  @doc "Freeze one configuration replacement at its observed revision."
  def prepare_config(agent_id, record, expected_revision) do
    payload = encode_config(agent_id, record)

    %Pending{
      kind: :config,
      agent_id: agent_id,
      expected_revision: expected_revision,
      payload: payload,
      record: record,
      sql: """
      UPDATE salix_agents
      SET config_revision = config_revision + 1, config_payload = $3, archived_at = $4, router_session_id = $8
      WHERE agent_id = $1 AND config_revision = $2 AND config_revision > 0
        AND tenant_id = $5 AND group_id = $6 AND role = $7
      RETURNING config_revision, config_payload
      """,
      params: [
        agent_id,
        expected_revision,
        payload,
        archived_at(record),
        Map.fetch!(record, "tenant_id"),
        Map.fetch!(record, "group_id"),
        Map.fetch!(record, "role"),
        record["router_session_id"]
      ]
    }
  end

  @doc "Read one bounded Agent-id keyset page in an already-authorized scope."
  def page_configs(scope, opts \\ []) when is_map(scope) do
    limit = Keyword.get(opts, :limit, 100)

    if is_integer(limit) and limit in 1..500 do
      {conditions, params} =
        Enum.reduce([:tenant_id, :group_id, :owner_node], {[], []}, fn key,
                                                                       {conditions, params} ->
          case Map.fetch(scope, key) do
            {:ok, value} -> {["#{key} = $#{length(params) + 1}" | conditions], params ++ [value]}
            :error -> {conditions, params}
          end
        end)

      cursor = Keyword.get(opts, :cursor)
      params = params ++ [cursor, limit]
      cursor_pos = length(params) - 1

      conditions = [
        "config_revision > 0",
        "($#{cursor_pos}::text IS NULL OR agent_id > $#{cursor_pos})" | conditions
      ]

      case query(
             "SELECT agent_id, config_payload FROM salix_agents WHERE " <>
               Enum.join(conditions, " AND ") <> " ORDER BY agent_id LIMIT $#{length(params)}",
             params
           ) do
        {:ok, %{rows: rows}} ->
          next = if length(rows) == limit, do: rows |> List.last() |> hd(), else: nil

          {:ok,
           %{
             items: Enum.map(rows, fn [_id, payload] -> Codec.decode_snapshot(payload) end),
             next: next
           }}

        error ->
          error
      end
    else
      {:error, :invalid_arguments}
    end
  end

  def peek(agent_id) do
    with {:ok, root} <- read_root(agent_id), do: {:ok, root.head}
  end

  def read_state(agent_id, _sm) do
    with {:ok, root} <- read_root(agent_id), do: {:ok, root.state}
  end

  @doc "Revoke the creation handle before removing its unpublished Session copies."
  def discard_created(%Owned{} = owned, delete_session \\ &missing_session_cleanup/2) do
    case begin_cleanup(owned) do
      {:ok, cleanup} -> cleanup_created(cleanup, delete_session)
      result -> result
    end
  end

  @doc "Agent authority check at the start of one creation-seed transaction."
  def lock_creation!(%Owned{} = owned), do: lock_created!(owned, "FOR SHARE")

  def begin_cleanup(%Owned{} = owned), do: owned |> prepare_cleanup() |> execute()

  @doc "Freeze the revocation identity before attempting creation cleanup."
  def prepare_cleanup(%Owned{} = owned) do
    previous_payload = encode_root(owned.head, owned.sm, owned.state)
    %Head{} = old_head = owned.head
    payload = encode_root(%Head{old_head | commit_uuid: uuid()}, owned.sm, owned.state)

    %Pending{
      kind: :begin_cleanup,
      agent_id: owned.agent_id,
      owned: owned,
      expected_revision: owned.root_revision,
      epoch: owned.epoch,
      node_id: owned.node_id,
      previous_payload: previous_payload,
      payload: payload,
      sql: """
      UPDATE salix_agents
      SET root_revision = root_revision + 1, root_payload = $6
      WHERE agent_id = $1 AND root_revision = $2 AND owner_epoch = $3
        AND owner_node = $4 AND config_revision = 0 AND root_payload = $5
      RETURNING #{@root_columns}
      """,
      params: [
        owned.agent_id,
        owned.root_revision,
        owned.epoch,
        owned.node_id,
        previous_payload,
        payload
      ]
    }
  end

  @doc "Continue bounded cleanup with the already-frozen cleanup identity."
  def cleanup_created(%Owned{} = cleanup, delete_session) do
    case cleanup_page(cleanup, delete_session) do
      {:ok, %{done: true}} -> :ok
      {:ok, %{done: false}} -> cleanup_created(cleanup, delete_session)
      error -> error
    end
  end

  @doc false
  def cleanup_page(%Owned{} = cleanup, delete_session, limit \\ @cleanup_page_size)
      when is_function(delete_session, 2) and limit in 1..@cleanup_page_size do
    case Repo.transaction(fn ->
           case lock_created!(cleanup, "FOR UPDATE", :missing_ok) do
             :gone ->
               %{done: true, deleted: 0}

             :ok ->
               %{rows: rows} =
                 Repo.query!(
                   """
                   SELECT session_id FROM salix_sessions WHERE agent_id = $1
                   ORDER BY session_id LIMIT $2 FOR UPDATE
                   """,
                   [cleanup.agent_id, limit]
                 )

               for [session_id] <- rows, do: :ok = delete_session.(cleanup.agent_id, session_id)

               %{num_rows: removed} =
                 Repo.query!(
                   """
                   DELETE FROM salix_agents WHERE agent_id = $1
                     AND NOT EXISTS (SELECT 1 FROM salix_sessions WHERE agent_id = $1)
                   """,
                   [cleanup.agent_id]
                 )

               %{done: removed == 1, deleted: length(rows)}
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in Postgrex.Error -> {:error, {:rolled_back, error}}
    _error in DBConnection.ConnectionError -> {:error, :commit_indeterminate, cleanup}
  catch
    :exit, _reason -> {:error, :commit_indeterminate, cleanup}
  end

  defp lock_created!(owned, lock, missing \\ :fenced) do
    case Repo.query!(
           """
           SELECT owner_node, owner_epoch, root_revision, root_payload, config_revision
           FROM salix_agents WHERE agent_id = $1 #{lock}
           """,
           [owned.agent_id]
         ).rows do
      [[node_id, epoch, revision, payload, 0]] ->
        if node_id == owned.node_id and epoch == owned.epoch and revision == owned.root_revision and
             payload == encode_root(owned.head, owned.sm, owned.state),
           do: :ok,
           else: Repo.rollback(:fenced)

      [] when missing == :missing_ok ->
        :gone

      _ ->
        Repo.rollback(:fenced)
    end
  end

  defp missing_session_cleanup(_agent_id, _session_id),
    do: Repo.rollback(:session_cleanup_required)

  def verify_owner(%Owned{} = owned) do
    case query(
           "SELECT owner_epoch, owner_node FROM salix_agents WHERE agent_id = $1 AND config_revision > 0",
           [
             owned.agent_id
           ]
         ) do
      {:ok, %{rows: [[epoch, node_id]]}} when epoch == owned.epoch and node_id == owned.node_id ->
        :ok

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:ok, _} ->
        {:error, :fenced}

      error ->
        error
    end
  end

  def verify_work_owner(%Owned{} = owned, opts \\ []) do
    case query(
           """
           SELECT owner_epoch, owner_node,
                  lease_until > clock_timestamp() + $2 * interval '1 millisecond'
           FROM salix_agents WHERE agent_id = $1 AND config_revision > 0
           """,
           [owned.agent_id, max(Keyword.get(opts, :guard_ms, 0), 0)]
         ) do
      {:ok, %{rows: [[epoch, node_id, enough]]}} ->
        cond do
          epoch != owned.epoch or node_id != owned.node_id -> {:error, :fenced}
          enough != true -> {:error, :lease_expiring}
          true -> :ok
        end

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  def read_root(agent_id), do: load_root(agent_id, true)

  defp load_root(agent_id, published?) do
    publication = if published?, do: " AND config_revision > 0", else: ""

    case query("SELECT #{@root_columns} FROM salix_agents WHERE agent_id = $1" <> publication, [
           agent_id
         ]) do
      {:ok, %{rows: [row]}} -> {:ok, decode_root(row)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Publish this creation and release its initial ownership in one update."
  def publish_created(%Owned{} = owned) do
    owned |> prepare_publish() |> execute()
  end

  @doc "Freeze the publication update before its transaction attempt."
  def prepare_publish(%Owned{} = owned) do
    %Pending{
      kind: :publish,
      agent_id: owned.agent_id,
      expected_revision: owned.root_revision,
      epoch: owned.epoch,
      node_id: owned.node_id,
      owned: owned,
      payload: encode_root(owned.head, owned.sm, owned.state),
      sql: """
      UPDATE salix_agents
      SET config_revision = 1, root_revision = root_revision + 1,
          owner_node = NULL, lease_until = NULL
      WHERE agent_id = $1 AND root_revision = $2 AND owner_epoch = $3
        AND owner_node = $4 AND config_revision = 0 AND root_payload = $5
      RETURNING #{@root_columns}
      """,
      params: [
        owned.agent_id,
        owned.root_revision,
        owned.epoch,
        owned.node_id,
        encode_root(owned.head, owned.sm, owned.state)
      ]
    }
  end

  def claim(agent_id, node_id, sm, opts \\ []),
    do: do_claim(agent_id, node_id, sm, opts, @claim_retries)

  defp do_claim(_agent_id, _node_id, _sm, _opts, 0), do: {:error, :claim_exhausted}

  defp do_claim(agent_id, node_id, sm, opts, attempts) do
    with {:ok, root} <- read_root(agent_id) do
      ttl_ms = Keyword.get(opts, :ttl_ms, @ttl_ms)
      payload = encode_root(%{root.head | commit_uuid: uuid()}, root.sm, root.state)

      pending = %Pending{
        kind: :claim,
        agent_id: agent_id,
        expected_revision: root.revision,
        epoch: root.head.epoch + 1,
        node_id: node_id,
        payload: payload,
        ttl_ms: ttl_ms,
        prev_owner_node: root.head.owner_node,
        owned: %Owned{agent_id: agent_id, node_id: node_id, sm: sm, ttl_ms: ttl_ms},
        sql: """
        WITH locked AS MATERIALIZED (
          SELECT agent_id AS locked_agent_id FROM salix_agents WHERE agent_id = $1 FOR UPDATE
        )
        UPDATE salix_agents
        SET owner_node = $3, owner_epoch = owner_epoch + 1,
            lease_until = clock_timestamp() + $4 * interval '1 millisecond',
            root_revision = root_revision + 1, root_payload = $6
        FROM locked
        WHERE agent_id = locked_agent_id AND root_revision = $2 AND config_revision > 0
          AND ($5 OR owner_node IS NULL OR owner_node = $3
               OR lease_until IS NULL OR lease_until <= clock_timestamp())
        RETURNING #{@root_columns}
        """,
        params: [agent_id, root.revision, node_id, ttl_ms, opts[:steal] == true, payload]
      }

      case execute(pending) do
        {:error, :precondition_failed} ->
          case query(
                 "SELECT owner_node, lease_until, root_revision, clock_timestamp() FROM salix_agents WHERE agent_id = $1",
                 [agent_id]
               ) do
            {:ok, %{rows: [[owner, lease, revision, now]]}} ->
              if revision != root.revision or is_nil(owner) or owner == node_id or is_nil(lease) or
                   DateTime.compare(lease, now) != :gt do
                do_claim(agent_id, node_id, sm, opts, attempts - 1)
              else
                {:error, {:held_by, owner, to_ms(lease)}}
              end

            {:ok, %{rows: []}} ->
              {:error, :not_found}

            error ->
              error
          end

        {:ok, owned} = result ->
          if is_function(opts[:on_claimed], 1), do: opts[:on_claimed].(owned)
          result

        error ->
          error
      end
    end
  end

  def commit(%Owned{} = owned, events, opts \\ []) when is_list(events) do
    owned |> prepare_commit(events, opts) |> execute()
  end

  @doc "Freeze the root mutation before any database attempt."
  def prepare_commit(%Owned{} = owned, events, opts \\ []) when is_list(events) do
    canonical = events |> Codec.encode_segment() |> Codec.decode_segment()
    state = StateMachine.apply_events(owned.sm, owned.state, canonical)
    seq = owned.next_seq
    %Head{} = old_head = owned.head

    head = %Head{
      old_head
      | commit_uuid: uuid(),
        journal_tail: %{epoch: owned.epoch, seq: seq},
        snapshot_seq: seq,
        message_id_hwm: Keyword.get(opts, :hwm, owned.head.message_id_hwm),
        hot: Keyword.get_lazy(opts, :hot, fn -> StateMachine.hot(owned.sm, state) end),
        format_version: 2,
        spill: []
    }

    payload = encode_root(head, owned.sm, state)

    %Pending{
      kind: :commit,
      agent_id: owned.agent_id,
      expected_revision: owned.root_revision,
      epoch: owned.epoch,
      node_id: owned.node_id,
      payload: payload,
      owned: owned,
      sql: """
      WITH locked AS MATERIALIZED (
        SELECT agent_id AS locked_agent_id FROM salix_agents WHERE agent_id = $1 FOR UPDATE
      )
      UPDATE salix_agents
      SET root_revision = root_revision + 1, root_payload = $5,
          lease_until = clock_timestamp() + $6 * interval '1 millisecond'
      FROM locked
      WHERE agent_id = locked_agent_id AND root_revision = $2 AND owner_epoch = $3 AND owner_node = $4
      RETURNING #{@root_columns}
      """,
      params: [
        owned.agent_id,
        owned.root_revision,
        owned.epoch,
        owned.node_id,
        payload,
        owned.ttl_ms
      ]
    }
  end

  def renew(%Owned{} = owned) do
    with {:ok, pending} <- prepare_renew(owned), do: execute(pending)
  end

  @doc "Freeze the minimum renewal deadline in the database clock domain."
  def prepare_renew(%Owned{} = owned) do
    with {:ok, %{rows: [[now]]}} <- query("SELECT clock_timestamp()", []) do
      lease_until = DateTime.add(now, owned.ttl_ms, :millisecond)

      {:ok,
       %Pending{
         kind: :renew,
         agent_id: owned.agent_id,
         expected_revision: owned.root_revision,
         epoch: owned.epoch,
         node_id: owned.node_id,
         payload: encode_root(owned.head, owned.sm, owned.state),
         lease_until: lease_until,
         owned: owned,
         sql: """
         WITH locked AS MATERIALIZED (
           SELECT agent_id AS locked_agent_id FROM salix_agents WHERE agent_id = $1 FOR UPDATE
         )
         UPDATE salix_agents
         SET root_revision = root_revision + 1,
             lease_until = GREATEST(clock_timestamp() + $5 * interval '1 millisecond', $6)
         FROM locked
         WHERE agent_id = locked_agent_id AND root_revision = $2 AND owner_epoch = $3 AND owner_node = $4
         RETURNING root_revision, owner_node, owner_epoch, lease_until
         """,
         params: [
           owned.agent_id,
           owned.root_revision,
           owned.epoch,
           owned.node_id,
           owned.ttl_ms,
           lease_until
         ]
       }}
    end
  end

  def release(%Owned{} = owned) do
    execute(%Pending{
      kind: :release,
      agent_id: owned.agent_id,
      expected_revision: owned.root_revision,
      epoch: owned.epoch,
      node_id: owned.node_id,
      owned: owned,
      sql: """
      WITH locked AS MATERIALIZED (
        SELECT agent_id AS locked_agent_id FROM salix_agents WHERE agent_id = $1 FOR UPDATE
      )
      UPDATE salix_agents
      SET root_revision = root_revision + 1, owner_node = NULL, lease_until = NULL
      FROM locked
      WHERE agent_id = locked_agent_id AND root_revision = $2 AND owner_epoch = $3 AND owner_node = $4
      RETURNING #{@root_columns}
      """,
      params: [owned.agent_id, owned.root_revision, owned.epoch, owned.node_id]
    })
  end

  @doc "Resolve or retry the same frozen operation without running its reducer."
  def settle_result(result, attempts \\ 5)

  def settle_result({:error, {:commit_indeterminate, _pending}}, 0),
    do: {:error, :commit_indeterminate}

  def settle_result({:error, {:commit_indeterminate, pending}}, attempts),
    do: settle_result(settle(pending), attempts - 1)

  def settle_result(result, _attempts), do: result

  def settle(%Pending{kind: :config} = pending) do
    case query(
           "SELECT config_revision, config_payload FROM salix_agents WHERE agent_id = $1 AND config_revision > 0",
           [
             pending.agent_id
           ]
         ) do
      {:ok, %{rows: [[revision, payload]]}} ->
        cond do
          revision == pending.expected_revision + 1 and payload == pending.payload ->
            {:ok, %{revision: revision, record: Codec.decode_snapshot(payload)}}

          revision == pending.expected_revision ->
            execute(pending)

          true ->
            {:error, :precondition_failed}
        end

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _} ->
        indeterminate(pending)
    end
  end

  def settle(%Pending{} = pending) do
    case load_root(pending.agent_id, false) do
      {:ok, root} ->
        cond do
          pending.kind == :publish and root.config_revision == 0 and
            root.revision == pending.expected_revision and root.head.epoch == pending.epoch and
            root.head.owner_node == pending.node_id and root.payload == pending.payload ->
            execute(pending)

          pending.kind == :publish and root.config_revision > 0 and
            root.revision == pending.expected_revision + 1 and root.head.epoch == pending.epoch and
            is_nil(root.head.owner_node) and root.payload == pending.payload ->
            :ok

          pending.kind == :publish ->
            {:error, :fenced}

          pending.kind == :begin_cleanup and root.config_revision == 0 and
            root.revision == pending.expected_revision + 1 and root.head.epoch == pending.epoch and
            root.head.owner_node == pending.node_id and root.payload == pending.payload ->
            finish(pending, root)

          pending.kind == :begin_cleanup and root.config_revision == 0 and
            root.revision == pending.expected_revision and root.head.epoch == pending.epoch and
            root.head.owner_node == pending.node_id and root.payload == pending.previous_payload ->
            execute(pending)

          pending.kind == :begin_cleanup ->
            {:error, :fenced}

          pending.kind in [:create, :begin_create, :seed] and root.payload != pending.payload ->
            {:error, :exists}

          pending.kind == :claim and root.revision == pending.expected_revision and
              root.head.epoch == pending.epoch - 1 ->
            execute(pending)

          root.head.epoch != pending.epoch or
              (pending.kind != :release and root.head.owner_node != pending.node_id) ->
            {:error, :fenced}

          root.revision == pending.expected_revision + 1 and landed?(pending, root) ->
            finish(pending, root)

          pending.kind == :renew and root.revision == pending.expected_revision + 1 ->
            {:error, :renew_unconfirmed}

          root.revision == pending.expected_revision ->
            execute(pending)

          pending.kind in [:create, :begin_create, :seed] ->
            {:error, :exists}

          true ->
            {:error, :precondition_failed}
        end

      {:error, :not_found} when pending.kind in [:create, :begin_create, :seed] ->
        execute(pending)

      {:error, :not_found} when pending.kind == :begin_cleanup ->
        :ok

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _} ->
        indeterminate(pending)
    end
  end

  defp landed?(%Pending{kind: :release}, root), do: is_nil(root.head.owner_node)

  defp landed?(%Pending{kind: :renew} = pending, root) do
    root.payload == pending.payload and is_integer(root.head.lease_until) and
      root.head.lease_until >= to_ms(pending.lease_until)
  end

  defp landed?(pending, root), do: root.payload == pending.payload

  defp execute(pending) do
    case query(pending.sql, pending.params) do
      {:ok, %{rows: [[revision, owner_node, epoch, lease_until]]}} when pending.kind == :renew ->
        %Head{} = head = pending.owned.head

        finish(pending, %{
          revision: revision,
          head: %Head{
            head
            | owner_node: owner_node,
              epoch: epoch,
              lease_until: to_ms(lease_until)
          },
          state: pending.owned.state
        })

      {:ok, %{rows: [[revision, payload]]}} when pending.kind == :config ->
        {:ok, %{revision: revision, record: Codec.decode_snapshot(payload)}}

      {:ok, %{rows: [row]}} ->
        finish(pending, decode_root(row))

      {:ok, %{rows: []}} when pending.kind in [:create, :begin_create, :seed] ->
        {:error, :exists}

      {:ok, %{rows: []}} when pending.kind in [:commit, :renew, :release, :publish] ->
        owner_conflict(pending)

      {:ok, %{rows: []}} when pending.kind == :begin_cleanup ->
        case load_root(pending.agent_id, false) do
          {:error, :not_found} -> :ok
          {:ok, _} -> {:error, :fenced}
          error -> error
        end

      {:ok, %{rows: []}} ->
        {:error, :precondition_failed}

      {:error, %Postgrex.Error{} = error} ->
        {:error, error}

      {:error, _reason} ->
        indeterminate(pending)
    end
  end

  defp owner_conflict(pending) do
    case load_root(pending.agent_id, false) do
      {:ok, _root} when pending.kind == :publish ->
        {:error, :fenced}

      {:ok, root}
      when root.head.epoch != pending.epoch or root.head.owner_node != pending.node_id ->
        {:error, :fenced}

      {:ok, _root} ->
        {:error, :stale_revision}

      error ->
        error
    end
  end

  defp finish(%Pending{kind: kind}, _root) when kind in [:release, :publish], do: :ok

  defp finish(pending, root) do
    %Owned{} = owned = pending.owned

    {:ok,
     %Owned{
       owned
       | root_revision: root.revision,
         epoch: root.head.epoch,
         head: root.head,
         state: root.state,
         next_seq: root.head.journal_tail.seq + 1,
         since_snapshot_bytes: 0,
         prev_owner_node: pending.prev_owner_node
     }}
  end

  defp encode_root(head, sm, state) do
    fields = head |> Map.from_struct() |> Map.drop([:epoch, :owner_node, :lease_until])
    Codec.encode_snapshot(%{head: fields, sm: sm, state: state})
  end

  defp decode_root([agent_id, owner, epoch, lease, revision, payload, config_revision]) do
    %{head: fields, sm: sm, state: state} = Codec.decode_snapshot(payload)

    head =
      struct!(
        Head,
        Map.merge(fields, %{owner_node: owner, epoch: epoch, lease_until: to_ms(lease)})
      )

    %{
      agent_id: agent_id,
      revision: revision,
      config_revision: config_revision,
      head: head,
      sm: sm,
      state: state,
      payload: payload
    }
  end

  defp encode_config(agent_id, %{"agent_id" => agent_id} = record),
    do: Codec.encode_snapshot(record)

  defp archived_at(%{"archived_at" => value}) when is_integer(value),
    do: DateTime.from_unix!(value, :second)

  defp archived_at(_), do: nil
  defp to_ms(nil), do: nil
  defp to_ms(time), do: DateTime.to_unix(time, :millisecond)
  defp uuid, do: Base.encode16(SystemsRuntime.Proc.random_bytes(16), case: :lower)
  defp indeterminate(pending), do: {:error, {:commit_indeterminate, pending}}

  defp query(sql, params) do
    Repo.query(sql, params)
  rescue
    error in DBConnection.ConnectionError -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end
end
