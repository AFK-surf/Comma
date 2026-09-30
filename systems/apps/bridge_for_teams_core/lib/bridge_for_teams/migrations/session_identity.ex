defmodule BridgeForTeams.Migrations.SessionIdentity do
  @moduledoc """
  Rewrites BFT-owned structured references to Salix agent sessions.

  Before the S3 cutover, `inventory_refs/0` contributes BFT-owned references to
  the single canonical map. `run/1` then consumes that frozen map and updates
  every configured BFT repo transactionally. BFT authentication sessions are
  separate identities and are never inspected.
  """

  alias SalixStore.SessionIdMigration

  # These are the BFT-owned projections that persist Salix session references.
  # The recursive walk is scoped to these columns and only interprets the
  # structured session/agent field names owned by SessionIdMigration.
  @jsonb_columns [
    {"workspace_items", "source_refs", :project_router},
    {"user_onboardings", "capabilities", nil}
  ]

  @spec inventory_refs() :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def inventory_refs do
    Application.load(:bridge_for_teams_core)

    :bridge_for_teams_core
    |> Application.fetch_env!(:ecto_repos)
    |> Enum.reduce_while({:ok, []}, fn repo, {:ok, refs} ->
      case Ecto.Migrator.with_repo(repo, &inventory_repo/1) do
        {:ok, {:ok, repo_refs}, _started} -> {:cont, {:ok, repo_refs ++ refs}}
        {:ok, {:error, reason}, _started} -> {:halt, {:error, reason}}
        {:error, reason} -> {:halt, {:error, {:bft_session_identity_repo_failed, repo, reason}}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, refs |> Enum.uniq() |> Enum.sort()}
      {:error, _} = error -> error
    end
  end

  @spec run(map()) :: {:ok, map()} | {:error, term()}
  def run(maps) when is_map(maps) do
    Application.load(:bridge_for_teams_core)

    with {:ok, maps} <- SessionIdMigration.normalize_all(maps),
         {:ok, true} <- SessionIdMigration.phase_complete?(:s3, maps),
         {:ok, summaries} <- rewrite_repos(maps),
         :ok <- SessionIdMigration.mark_phase_complete(:bft, maps) do
      {:ok, %{repos: summaries}}
    else
      {:ok, false} -> {:error, :session_identity_s3_phase_incomplete}
      {:error, _} = error -> error
    end
  end

  defp inventory_repo(repo) do
    repo.transaction(
      fn ->
        case inventory_columns(repo) do
          {:ok, refs} -> refs
          {:error, reason} -> repo.rollback(reason)
        end
      end,
      timeout: :infinity
    )
  end

  defp inventory_columns(repo) do
    Enum.reduce_while(@jsonb_columns, {:ok, []}, fn {table, column, owner_column}, {:ok, refs} ->
      result =
        Enum.reduce_while(select_rows(repo, table, column, owner_column), {:ok, refs}, fn
          [id, value, owner_agent_id], {:ok, acc} ->
            context = "#{table}.#{column}:#{id}"

            case SessionIdMigration.collect_refs(value, owner_agent_id,
                   context: context,
                   missing_owner: :error,
                   recursive: true
                 ) do
              {:ok, row_refs} ->
                {:cont, {:ok, row_refs ++ acc}}

              {:error, reason} ->
                {:halt, {:error, {:bft_session_identity_inventory_failed, context, reason}}}
            end
        end)

      case result do
        {:ok, refs} -> {:cont, {:ok, refs}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp rewrite_repos(maps) do
    :bridge_for_teams_core
    |> Application.fetch_env!(:ecto_repos)
    |> Enum.reduce_while({:ok, []}, fn repo, {:ok, summaries} ->
      case Ecto.Migrator.with_repo(repo, &rewrite_repo(&1, maps)) do
        {:ok, {:ok, summary}, _started} ->
          {:cont, {:ok, [summary | summaries]}}

        {:ok, {:error, reason}, _started} ->
          {:halt, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, {:bft_session_identity_repo_failed, repo, reason}}}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      {:error, _} = error -> error
    end
  end

  defp rewrite_repo(repo, maps) do
    repo.transaction(
      fn ->
        with {:ok, stats} <- rewrite_columns(repo, maps),
             :ok <- verify_columns(repo, maps) do
          stats
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end,
      timeout: :infinity
    )
  end

  defp rewrite_columns(repo, maps) do
    Enum.reduce_while(@jsonb_columns, {:ok, %{migrated: 0, unchanged: 0}}, fn column,
                                                                              {:ok, stats} ->
      case rewrite_column(repo, maps, column) do
        {:ok, column_stats} -> {:cont, {:ok, merge_stats(stats, column_stats)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rewrite_column(repo, maps, {table, column, owner_column}) do
    rows = select_rows(repo, table, column, owner_column)

    Enum.reduce_while(rows, {:ok, %{migrated: 0, unchanged: 0}}, fn
      [id, value, owner_agent_id], {:ok, stats} ->
        context = "#{table}.#{column}:#{id}"

        case SessionIdMigration.rewrite_refs(value, maps, owner_agent_id,
               context: context,
               missing_owner: :error,
               recursive: true
             ) do
          {:ok, ^value} ->
            {:cont, {:ok, Map.update!(stats, :unchanged, &(&1 + 1))}}

          {:ok, rewritten} ->
            case repo.query("UPDATE #{table} SET #{column} = $1 WHERE id::text = $2", [
                   rewritten,
                   id
                 ]) do
              {:ok, _} ->
                {:cont, {:ok, Map.update!(stats, :migrated, &(&1 + 1))}}

              {:error, reason} ->
                {:halt, {:error, {:bft_session_identity_update_failed, context, reason}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:bft_session_identity_rewrite_failed, context, reason}}}
        end
    end)
  end

  defp verify_columns(repo, maps) do
    Enum.reduce_while(@jsonb_columns, :ok, fn {table, column, owner_column}, :ok ->
      result =
        Enum.reduce_while(select_rows(repo, table, column, owner_column), :ok, fn
          [id, value, owner_agent_id], :ok ->
            context = "#{table}.#{column}:#{id}"

            case SessionIdMigration.rewrite_refs(value, maps, owner_agent_id,
                   context: context,
                   missing_owner: :error,
                   recursive: true
                 ) do
              {:ok, ^value} ->
                {:cont, :ok}

              {:ok, _rewritten} ->
                {:halt, {:error, {:bft_legacy_session_reference_remains, context}}}

              {:error, reason} ->
                {:halt, {:error, {:bft_session_identity_verify_failed, context, reason}}}
            end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp select_rows(repo, table, column, nil) do
    repo.query!("SELECT id::text, #{column}, NULL::text FROM #{table}").rows
  end

  defp select_rows(repo, "workspace_items", "source_refs", :project_router) do
    repo.query!("""
    SELECT
      item.id::text,
      item.source_refs,
      CASE
        WHEN NULLIF(item.source_refs ->> 'origin_session_id', '') IS NOT NULL THEN (
          SELECT agent.salix_agent_id
          FROM agents AS agent
          WHERE agent.project_id = item.project_id
            AND agent.role = 'router'
            AND agent.archived_at IS NULL
        )
        ELSE NULL::text
      END
    FROM workspace_items AS item
    """).rows
  end

  defp select_rows(repo, table, column, owner_column) do
    repo.query!("SELECT id::text, #{column}, #{owner_column} FROM #{table}").rows
  end

  defp merge_stats(left, right) do
    %{migrated: left.migrated + right.migrated, unchanged: left.unchanged + right.unchanged}
  end
end
