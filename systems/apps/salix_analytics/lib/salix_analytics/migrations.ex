defmodule SalixAnalytics.Migrations do
  @moduledoc """
  Versioned ClickHouse migrations for the Salix analytics sink.

  Migrations live under `priv/clickhouse/migrations/*.sql`. The numeric prefix
  is the migration version; applied versions are recorded in the configured
  ClickHouse database's `analytics_schema_migrations` table.
  """

  @migration_table "analytics_schema_migrations"
  @default_table "salix_analytics.events"
  # The agent-telemetry tables appear in both generations while the v1→v2
  # seam is open (20260723000001..3): identity rewrites must touch frozen v1
  # rows (still read behind the seam) and live v2 rows alike. The rewritten
  # columns are not part of either generation's key, so ALTER UPDATE stays
  # legal on both. Drop the v1 entries together with the seam cleanup.
  @hierarchy_tables [
    {"llm_call_events", [:tenant, :group, :agent, :product_group]},
    {"llm_call_events_v2", [:tenant, :group, :agent, :product_group]},
    {"vm_usage_events", [:tenant, :group, :product_group]},
    {"storage_usage_events", [:tenant, :group, :product_group]},
    {"billing_charge_events", [:tenant, :group, :product_group]},
    {"fee_control_checks", [:tenant, :group, :product_group]},
    {"tool_call_events", [:tenant, :group, :agent]},
    {"tool_call_events_v2", [:tenant, :group, :agent]},
    {"agent_run_events", [:tenant, :group, :agent]},
    {"agent_run_events_v2", [:tenant, :group, :agent]},
    {"trajectory_eval_events", [:tenant, :group, :agent, :product_group]},
    {"billing_source_events", [:product_group]}
  ]
  @hierarchy_mapping_batch_size 500
  @session_mapping_batch_size 200
  @session_tables ~w(llm_call_events llm_call_events_v2 tool_call_events tool_call_events_v2 agent_run_events agent_run_events_v2 trajectory_eval_events)

  alias SalixStore.{HierarchyIdMigration, SessionIdMigration}

  @type migration :: %{
          version: non_neg_integer(),
          name: String.t(),
          path: Path.t(),
          checksum: String.t()
        }

  @doc "Run all pending ClickHouse migrations configured for `:salix_analytics`."
  @spec migrate(keyword()) :: {:ok, [non_neg_integer()]} | {:error, term()}
  def migrate(opts \\ []) do
    with {:ok, cfg} <- config(opts),
         {:ok, _} <- Application.ensure_all_started(:req),
         :ok <- ensure_database(cfg),
         :ok <- ensure_migration_table(cfg),
         {:ok, applied} <- applied_migrations(cfg),
         migrations <- migrations(opts),
         :ok <- verify_unique_versions(migrations),
         :ok <- verify_applied_checksums(applied, migrations),
         pending <- Enum.reject(migrations, &Map.has_key?(applied, &1.version)),
         :ok <- run_pending(cfg, pending) do
      {:ok, Enum.map(pending, & &1.version)}
    else
      :disabled -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @doc "Run exactly the authorized pending ClickHouse migration versions."
  @spec migrate_versions([non_neg_integer()], keyword()) ::
          {:ok, [non_neg_integer()]} | {:error, term()}
  def migrate_versions(versions, opts \\ []) when is_list(versions) do
    allowed = versions |> Enum.uniq() |> Enum.sort()

    with {:ok, cfg} <- config(opts),
         {:ok, _} <- Application.ensure_all_started(:req),
         :ok <- ensure_database(cfg),
         :ok <- ensure_migration_table(cfg),
         {:ok, applied} <- applied_migrations(cfg),
         migrations <- migrations(opts),
         :ok <- verify_unique_versions(migrations),
         :ok <- verify_applied_checksums(applied, migrations),
         pending <- Enum.reject(migrations, &Map.has_key?(applied, &1.version)),
         actual <-
           pending |> Enum.map(& &1.version) |> Enum.filter(&(&1 in allowed)) |> Enum.sort(),
         true <- actual == allowed,
         selected <- Enum.filter(pending, &(&1.version in allowed)),
         :ok <- run_pending(cfg, selected) do
      {:ok, allowed}
    else
      :disabled when allowed == [] -> {:ok, []}
      :disabled -> {:error, :analytics_disabled_with_authorized_migrations}
      false -> {:error, :authorized_clickhouse_pending_drift}
      {:error, _} = error -> error
    end
  end

  @doc "Rewrite typed analytics tenant/group/agent dimensions after the S3 identity cutover."
  @spec rewrite_hierarchy_dimensions(map(), keyword()) ::
          {:ok, [String.t()] | :disabled} | {:error, term()}
  def rewrite_hierarchy_dimensions(identity, opts \\ [])

  def rewrite_hierarchy_dimensions(identity, opts) when is_map(identity) do
    with {:ok, mappings} <- normalize_hierarchy_identity(identity),
         {:ok, cfg} <- config(opts),
         {:ok, _} <- Application.ensure_all_started(:req),
         :ok <- rewrite_hierarchy_tables(cfg, mappings) do
      {:ok, Enum.map(@hierarchy_tables, &elem(&1, 0))}
    else
      :disabled -> {:ok, :disabled}
      {:error, _} = error -> error
    end
  end

  def rewrite_hierarchy_dimensions(_identity, _opts),
    do: {:error, :invalid_hierarchy_identity_map}

  @doc "Rewrite typed analytics session dimensions after the S3 session cutover."
  @spec rewrite_session_dimensions(map(), keyword()) ::
          {:ok, [String.t()] | :disabled} | {:error, term()}
  def rewrite_session_dimensions(maps, opts \\ [])

  def rewrite_session_dimensions(maps, opts) when is_map(maps) do
    with {:ok, maps} <- SessionIdMigration.normalize_all(maps),
         {:ok, cfg} <- config(opts),
         {:ok, _} <- Application.ensure_all_started(:req),
         replacements <- changed_session_mappings(maps),
         :ok <- validate_session_rows(cfg, replacements),
         :ok <- rewrite_session_tables(cfg, replacements),
         :ok <- verify_session_rows(cfg, replacements) do
      {:ok, @session_tables}
    else
      :disabled -> {:ok, :disabled}
      {:error, _} = error -> error
    end
  end

  def rewrite_session_dimensions(_maps, _opts),
    do: {:error, :invalid_session_identity_maps}

  @doc "Inventory typed analytics session dimensions before the S3 session cutover."
  @spec inventory_session_refs(keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def inventory_session_refs(opts \\ []) do
    with {:ok, cfg} <- config(opts),
         {:ok, _} <- Application.ensure_all_started(:req) do
      @session_tables
      |> Enum.reduce_while({:ok, []}, fn table, {:ok, refs} ->
        case inventory_session_table(cfg, table) do
          {:ok, table_refs} -> {:cont, {:ok, table_refs ++ refs}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, refs} -> {:ok, refs |> Enum.uniq() |> Enum.sort()}
        {:error, _} = error -> error
      end
    else
      :disabled -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @doc "Return all migration metadata in application order."
  @spec migrations(keyword()) :: [migration()]
  def migrations(opts \\ []) do
    opts
    |> migration_dir()
    |> Path.join("*.sql")
    |> Path.wildcard()
    |> Enum.map(&load_migration/1)
    |> Enum.sort_by(& &1.version)
  end

  @doc "Read and validate the ClickHouse migration manifest without applying it."
  def plan(opts \\ []) do
    with {:ok, cfg} <- config(opts),
         {:ok, _} <- Application.ensure_all_started(:req),
         migrations <- migrations(opts),
         :ok <- verify_unique_versions(migrations),
         {:ok, applied} <- read_applied_migrations(cfg),
         :ok <- verify_applied_checksums(applied, migrations) do
      {:ok,
       %{
         manifest: Map.new(migrations, &{&1.version, &1.checksum}),
         pending:
           migrations |> Enum.reject(&Map.has_key?(applied, &1.version)) |> Enum.map(& &1.version)
       }}
    else
      :disabled -> {:ok, %{manifest: %{}, pending: []}}
      {:error, _} = error -> error
    end
  end

  defp read_applied_migrations(cfg) do
    with {:ok, database_exists?} <- database_exists?(cfg),
         {:ok, ledger_exists?} <- migration_table_exists?(cfg, database_exists?) do
      if ledger_exists?, do: applied_migrations(cfg), else: {:ok, %{}}
    end
  end

  defp database_exists?(cfg) do
    case query(cfg, "SELECT count() FROM system.databases WHERE name = {name:String}", "",
           sql_in_body: true,
           query_params: [param_name: cfg.database]
         ) do
      {:ok, body} -> {:ok, String.trim(to_string(body)) == "1"}
      {:error, reason} -> {:error, {:database_inventory_failed, reason}}
    end
  end

  defp migration_table_exists?(_cfg, false), do: {:ok, false}

  defp migration_table_exists?(cfg, true) do
    case query(
           cfg,
           "SELECT count() FROM system.tables WHERE database = {database:String} AND name = {name:String}",
           "",
           sql_in_body: true,
           query_params: [param_database: cfg.database, param_name: @migration_table]
         ) do
      {:ok, body} -> {:ok, String.trim(to_string(body)) == "1"}
      {:error, reason} -> {:error, {:migration_table_inventory_failed, reason}}
    end
  end

  defp run_pending(_cfg, []), do: :ok

  defp run_pending(cfg, [migration | rest]) do
    with :ok <- run_migration(cfg, migration),
         :ok <- record_migration(cfg, migration) do
      run_pending(cfg, rest)
    end
  end

  defp run_migration(cfg, migration) do
    migration.path
    |> File.read!()
    |> render_sql(cfg)
    |> statements()
    |> Enum.reduce_while(:ok, fn statement, :ok ->
      case query(cfg, statement) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:migration_failed, migration.name, reason}}}
      end
    end)
  end

  defp ensure_database(cfg) do
    query(cfg, "CREATE DATABASE IF NOT EXISTS #{cfg.database}")
    |> ok()
  end

  defp ensure_migration_table(cfg) do
    query(cfg, """
    CREATE TABLE IF NOT EXISTS #{cfg.migration_table} (
      version UInt64,
      name String,
      checksum String,
      applied_at DateTime64(3) DEFAULT now64(3)
    ) ENGINE = ReplacingMergeTree(applied_at)
    ORDER BY version
    """)
    |> ok()
  end

  # Two files sharing a version prefix would both run and record ledger rows
  # under the same version, leaving the surviving checksum up to ClickHouse
  # part-merge order (see the 20260708000001 collision).
  defp verify_unique_versions(migrations) do
    migrations
    |> Enum.group_by(& &1.version)
    |> Enum.filter(fn {_version, files} -> length(files) > 1 end)
    |> case do
      [] ->
        :ok

      duplicates ->
        {:error,
         {:duplicate_migration_versions,
          Enum.map(duplicates, fn {version, files} ->
            {version, Enum.map(files, & &1.name)}
          end)}}
    end
  end

  defp applied_migrations(cfg) do
    # The ledger is a ReplacingMergeTree keyed by version: until parts merge, a
    # re-recorded version has multiple rows, and a plain SELECT would leave the
    # winning checksum to result order. argMax pins it to the newest applied_at.
    case query(
           cfg,
           "SELECT version, argMax(checksum, applied_at) FROM #{cfg.migration_table} GROUP BY version FORMAT TSV"
         ) do
      {:ok, body} ->
        applied =
          body
          |> to_string()
          |> String.split("\n", trim: true)
          |> Map.new(fn line ->
            [version, checksum] = String.split(line, "\t", parts: 2)
            {String.to_integer(version), checksum}
          end)

        {:ok, applied}

      {:error, reason} ->
        {:error, {:applied_migrations_failed, reason}}
    end
  end

  defp verify_applied_checksums(applied, migrations) do
    migrations
    |> Enum.find(fn migration ->
      checksum = applied[migration.version]
      is_binary(checksum) and checksum != migration.checksum
    end)
    |> case do
      nil ->
        :ok

      migration ->
        {:error, {:checksum_mismatch, migration.version, migration.name}}
    end
  end

  defp record_migration(cfg, migration) do
    row =
      %{
        version: migration.version,
        name: migration.name,
        checksum: migration.checksum
      }
      |> Jason.encode!()

    query(
      cfg,
      "INSERT INTO #{cfg.migration_table} (version, name, checksum) FORMAT JSONEachRow",
      row
    )
    |> ok()
  end

  defp query(cfg, sql, body \\ "", opts \\ []) do
    query_params = Keyword.get(opts, :query_params, [])

    {params, request_body} =
      if Keyword.get(opts, :sql_in_body, false) do
        {query_params, sql}
      else
        {[query: sql] ++ query_params, body}
      end

    case Req.post(cfg.base_url,
           params: params,
           headers: headers(cfg),
           body: request_body,
           receive_timeout: Keyword.get(opts, :receive_timeout, 30_000),
           retry: :transient
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp headers(%{user: user, password: pass}) when is_binary(user) and user != "" do
    [{"x-clickhouse-user", user}, {"x-clickhouse-key", pass || ""}]
  end

  defp headers(_), do: []

  defp ok({:ok, _}), do: :ok
  defp ok({:error, reason}), do: {:error, reason}

  defp normalize_hierarchy_identity(identity) do
    with {:ok, identity} <- HierarchyIdMigration.normalize(identity) do
      {:ok,
       %{
         tenants: changed_mappings(identity.tenants),
         groups: changed_mappings(identity.groups),
         agents: changed_mappings(identity.agents)
       }}
    end
  end

  defp changed_mappings(mappings),
    do: Map.reject(mappings, fn {source, target} -> source == target end)

  defp rewrite_hierarchy_tables(cfg, mappings) do
    Enum.reduce_while(@hierarchy_tables, :ok, fn {table, dimensions}, :ok ->
      case rewrite_hierarchy_table(cfg, table, dimensions, mappings) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:hierarchy_dimension_migration_failed, table, reason}}}
      end
    end)
  end

  defp rewrite_hierarchy_table(cfg, table, dimensions, mappings) do
    [
      {mappings.tenants, Enum.filter(dimensions, &(&1 == :tenant))},
      {mappings.groups, Enum.filter(dimensions, &(&1 in [:group, :product_group]))},
      {mappings.agents, Enum.filter(dimensions, &(&1 == :agent))}
    ]
    |> Enum.reduce_while(:ok, fn {type_mappings, type_dimensions}, :ok ->
      result =
        type_mappings
        |> Enum.sort()
        |> Enum.chunk_every(@hierarchy_mapping_batch_size)
        |> Enum.reduce_while(:ok, fn chunk, :ok ->
          case rewrite_hierarchy_batch(cfg, table, type_dimensions, Map.new(chunk)) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp rewrite_hierarchy_batch(_cfg, _table, [], _mappings), do: :ok

  defp rewrite_hierarchy_batch(_cfg, _table, _dimensions, mappings)
       when map_size(mappings) == 0,
       do: :ok

  defp rewrite_hierarchy_batch(cfg, table, dimensions, mappings) do
    assignments = Enum.flat_map(dimensions, &hierarchy_assignment(&1, mappings))

    sql = """
    ALTER TABLE #{cfg.database}.#{table}
    UPDATE #{Enum.map_join(assignments, ", ", &elem(&1, 1))}
    WHERE #{Enum.map_join(assignments, " OR ", &elem(&1, 0))}
    SETTINGS mutations_sync = 2
    """

    query(cfg, sql, "", receive_timeout: 1_800_000, sql_in_body: true) |> ok()
  end

  defp changed_session_mappings(maps) do
    maps
    |> Enum.flat_map(fn {agent_id, session_ids} ->
      Enum.map(session_ids, fn {source, target} -> {agent_id, source, target} end)
    end)
    |> Enum.reject(fn {_agent_id, source, target} -> source == target end)
    |> Enum.sort()
  end

  defp inventory_session_table(cfg, table) do
    sql = """
    SELECT DISTINCT ifNull(salix_agent_id, ''), assumeNotNull(session_id)
    FROM #{cfg.database}.#{table}
    WHERE isNotNull(session_id)
    FORMAT TSV
    """

    case query(cfg, sql) do
      {:ok, body} -> parse_session_inventory(table, body)
      {:error, reason} -> {:error, {:session_row_inventory_failed, table, reason}}
    end
  end

  defp parse_session_inventory(table, body) do
    body
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, refs} ->
      case String.split(line, "\t", parts: 2) do
        [agent_id, session_id]
        when agent_id != "" and session_id != "" ->
          if SalixStore.Ids.valid_agent_id?(agent_id) do
            {:cont, {:ok, [{agent_id, session_id} | refs]}}
          else
            {:halt, {:error, {:invalid_session_row_owner, table, agent_id, session_id}}}
          end

        _ ->
          {:halt, {:error, {:unowned_session_row, table, line}}}
      end
    end)
  end

  defp validate_session_rows(_cfg, []), do: :ok

  defp validate_session_rows(cfg, replacements) do
    known =
      replacements
      |> Enum.map(fn {agent_id, source, _target} -> {agent_id, source} end)
      |> MapSet.new()

    Enum.reduce_while(@session_tables, :ok, fn table, :ok ->
      result =
        replacements
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()
        |> Enum.chunk_every(@hierarchy_mapping_batch_size)
        |> Enum.reduce_while(:ok, fn sources, :ok ->
          sql = """
          SELECT ifNull(salix_agent_id, ''), assumeNotNull(session_id)
          FROM #{cfg.database}.#{table}
          WHERE isNotNull(session_id) AND assumeNotNull(session_id) IN #{sql_array(sources)}
          FORMAT TSV
          """

          case query(cfg, sql) do
            {:ok, body} ->
              unknown =
                body
                |> to_string()
                |> String.split("\n", trim: true)
                |> Enum.map(fn line ->
                  case String.split(line, "\t", parts: 2) do
                    [agent_id, session_id] -> {agent_id, session_id}
                    _ -> {:invalid, line}
                  end
                end)
                |> Enum.reject(&MapSet.member?(known, &1))

              if unknown == [],
                do: {:cont, :ok},
                else: {:halt, {:error, {:unowned_legacy_session_rows, table, unknown}}}

            {:error, reason} ->
              {:halt, {:error, {:session_row_inventory_failed, table, reason}}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp rewrite_session_tables(_cfg, []), do: :ok

  defp rewrite_session_tables(cfg, replacements) do
    Enum.reduce_while(@session_tables, :ok, fn table, :ok ->
      result =
        replacements
        |> Enum.chunk_every(@session_mapping_batch_size)
        |> Enum.reduce_while(:ok, fn batch, :ok ->
          clauses =
            Enum.map(batch, fn {agent_id, source, target} ->
              condition =
                "assumeNotNull(salix_agent_id) = #{sql_string(agent_id)} AND " <>
                  "assumeNotNull(session_id) = #{sql_string(source)}"

              {condition, sql_string(target)}
            end)

          expression =
            clauses
            |> Enum.flat_map(fn {condition, target} -> [condition, target] end)
            |> then(fn args ->
              "multiIf(" <> Enum.join(args ++ ["assumeNotNull(session_id)"], ", ") <> ")"
            end)

          predicate = Enum.map_join(clauses, " OR ", &elem(&1, 0))

          sql = """
          ALTER TABLE #{cfg.database}.#{table}
          UPDATE session_id = if(isNull(session_id), session_id, #{expression})
          WHERE isNotNull(salix_agent_id) AND isNotNull(session_id) AND (#{predicate})
          SETTINGS mutations_sync = 2
          """

          case query(cfg, sql, "", receive_timeout: 1_800_000, sql_in_body: true) |> ok() do
            :ok ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, {:session_dimension_migration_failed, table, reason}}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp verify_session_rows(_cfg, []), do: :ok

  defp verify_session_rows(cfg, replacements) do
    Enum.reduce_while(@session_tables, :ok, fn table, :ok ->
      result =
        replacements
        |> Enum.chunk_every(@session_mapping_batch_size)
        |> Enum.reduce_while(:ok, fn batch, :ok ->
          predicate =
            Enum.map_join(batch, " OR ", fn {agent_id, source, _target} ->
              "(assumeNotNull(salix_agent_id) = #{sql_string(agent_id)} AND " <>
                "assumeNotNull(session_id) = #{sql_string(source)})"
            end)

          sql = """
          SELECT count()
          FROM #{cfg.database}.#{table}
          WHERE isNotNull(salix_agent_id) AND isNotNull(session_id) AND (#{predicate})
          FORMAT TSV
          """

          case query(cfg, sql) do
            {:ok, body} ->
              case Integer.parse(String.trim(to_string(body))) do
                {0, ""} -> {:cont, :ok}
                {count, ""} -> {:halt, {:error, {:legacy_session_rows_remain, table, count}}}
                _ -> {:halt, {:error, {:invalid_session_verify_response, table, body}}}
              end

            {:error, reason} ->
              {:halt, {:error, {:session_row_verify_failed, table, reason}}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp hierarchy_assignment(:tenant, mappings),
    do: transform_assignment("tenant_id", mappings)

  defp hierarchy_assignment(:group, mappings),
    do: transform_assignment("group_id", mappings)

  defp hierarchy_assignment(:agent, mappings),
    do: nullable_transform_assignment("salix_agent_id", mappings)

  defp hierarchy_assignment(:product_group, mappings) do
    case transform_expression("product_owner_id", mappings) do
      nil ->
        []

      expression ->
        condition =
          "product_owner_type = 'group' AND product_owner_id IN #{sql_source_set(mappings)}"

        [
          {condition,
           "product_owner_id = if(product_owner_type = 'group', #{expression}, product_owner_id)"}
        ]
    end
  end

  defp transform_assignment(column, mappings) do
    case transform_expression(column, mappings) do
      nil -> []
      expression -> [{"#{column} IN #{sql_source_set(mappings)}", "#{column} = #{expression}"}]
    end
  end

  defp nullable_transform_assignment(column, mappings) do
    source = "assumeNotNull(#{column})"

    case transform_expression(source, mappings) do
      nil ->
        []

      expression ->
        condition = "isNotNull(#{column}) AND #{source} IN #{sql_source_set(mappings)}"
        assignment = "#{column} = if(isNull(#{column}), #{column}, #{expression})"
        [{condition, assignment}]
    end
  end

  defp transform_expression(_column, mappings) when map_size(mappings) == 0, do: nil

  defp transform_expression(column, mappings) do
    {sources, targets} = mappings |> Enum.sort() |> Enum.unzip()
    "transform(#{column}, #{sql_array(sources)}, #{sql_array(targets)}, #{column})"
  end

  defp sql_source_set(mappings), do: mappings |> Map.keys() |> Enum.sort() |> sql_array()
  defp sql_array(values), do: "[" <> Enum.map_join(values, ",", &sql_string/1) <> "]"

  defp sql_string(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")
    "'" <> escaped <> "'"
  end

  defp config(opts) do
    cfg = Keyword.merge(Application.get_env(:salix_analytics, :clickhouse, []), opts)
    base_url = cfg[:base_url]
    table = cfg[:table] || @default_table

    cond do
      not is_binary(base_url) or String.trim(base_url) == "" ->
        :disabled

      true ->
        with :ok <- validate_table(table) do
          database = table |> String.split(".", parts: 2) |> hd()

          {:ok,
           %{
             base_url: base_url,
             table: table,
             database: database,
             migration_table: "#{database}.#{@migration_table}",
             user: cfg[:user],
             password: cfg[:password]
           }}
        end
    end
  end

  defp migration_dir(opts) do
    cond do
      dir = opts[:migration_dir] ->
        dir

      true ->
        case :code.priv_dir(:salix_analytics) do
          priv when is_list(priv) -> Path.join(to_string(priv), "clickhouse/migrations")
          {:error, _} -> Path.expand("../../priv/clickhouse/migrations", __DIR__)
        end
    end
  end

  defp validate_table(table) when is_binary(table) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$/, table) do
      :ok
    else
      {:error, {:invalid_table, table}}
    end
  end

  defp validate_table(table), do: {:error, {:invalid_table, table}}

  defp load_migration(path) do
    name = Path.basename(path)
    [version | _] = String.split(name, "_", parts: 2)

    %{
      version: String.to_integer(version),
      name: name,
      path: path,
      checksum:
        path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    }
  end

  defp render_sql(sql, cfg) do
    sql
    |> String.replace("{{table}}", cfg.table)
    |> String.replace("{{database}}", cfg.database)
    |> String.replace("{{migration_table}}", cfg.migration_table)
  end

  defp statements(sql) do
    sql
    |> strip_comments()
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_comments(sql) do
    sql
    |> String.split("\n")
    |> Enum.reject(&(String.trim_leading(&1) |> String.starts_with?("--")))
    |> Enum.join("\n")
  end
end
