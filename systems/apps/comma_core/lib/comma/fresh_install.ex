defmodule Comma.FreshInstall do
  @moduledoc "Offline initialization of empty Comma stores. Existing data uses the release handoff."

  @cutover_id "comma-20260723000003"
  @release_identity "comma-product-state-final-import-v1"
  @empty_digest String.duplicate("0", 64)
  @product_relations [
    "comma_users",
    "comma_workspaces",
    "comma_workspace_memberships",
    "comma_conversation_bindings",
    "comma_salix_conversation_projections",
    "comma_assistant_chat_bindings",
    "comma_conversation_adoption_suppressions",
    "comma_external_operations",
    "comma_conversation_adoption_attempts",
    "comma_reconciliation_cursors",
    "comma_sessions",
    "comma_session_budget_consumptions",
    "comma_workspace_conversation_items",
    "comma_import_checkpoints"
  ]

  def run do
    unless Application.get_env(:comma_core, :selfhost, false) or
             System.get_env("COMMA_ENVIRONMENT") == "local" do
      raise "Fresh installation is restricted to selfhost and local environments. Use the release handoff for hosted environments."
    end

    # Keep the repository alive while migrations start the storage application.
    # Its supervisor must not lose a repository owned by a shorter migration scope.
    {:ok, :ok, _} = Ecto.Migrator.with_repo(SalixStore.Repo, fn _ -> initialize() end)
    :ok
  end

  defp initialize do
    case SalixAnalytics.Migrations.migrate() do
      {:ok, _versions} -> apply(Module.concat([Comma, Release]), :migrate, [])
      {:error, reason} -> raise "ClickHouse migration failed: #{inspect(reason)}"
    end

    unless schema_ready?() do
      seed_empty_import_ledger_if_safe!()
      apply(Module.concat([Comma, Release]), :execute_cutover_steps, [[@cutover_id]])
    end

    unless schema_ready?(), do: raise("Comma product schema is not ready after initialization")
    initialize_agent_configuration!()
    initialize_group_compute!()
    initialize_owner!()
    :ok
  end

  # Offline local/selfhost initialization may admit an empty source only.
  defp initialize_group_compute! do
    case SalixStore.ComputeMigration.ensure_open() do
      :ok ->
        :ok

      _ ->
        case SalixStore.S3.list(SalixStore.Keys.ctl_vms_prefix(), max_keys: 1) do
          {:ok, %{objects: [], next: nil}} ->
            {:ok, %{next_cursor: nil}} = SalixStore.ComputeMigration.transfer_page()

          _ ->
            raise "Existing CloudVM data requires the Group Compute release handoff"
        end
    end
  end

  defp initialize_owner! do
    case Application.get_env(:comma_core, :selfhost_owner_email) do
      email when is_binary(email) and email != "" ->
        {:ok, {:ok, _}, _} =
          Ecto.Migrator.with_repo(Comma.Repo, fn _ ->
            with {:ok, user} <- Comma.Accounts.get_or_create_user_by_email(email) do
              case Comma.Repo.get(Comma.Admin.AccessOverride, user["id"]) do
                nil ->
                  Comma.Admin.set_admin_access(
                    user["id"],
                    "allow",
                    :ops,
                    "Self-hosted instance owner"
                  )

                _existing ->
                  {:ok, user}
              end
            end
          end)

      _ ->
        :ok
    end
  end

  # This offline Comma stack has no Bridge configuration writers to transfer.
  # Stop serving containers before this initializer runs.
  defp initialize_agent_configuration! do
    {:ok, :ok, _started} =
      Ecto.Migrator.with_repo(SalixStore.Repo, fn repo ->
        case SalixStore.AgentConfigurationRollout.state() do
          {:ok, :complete} ->
            :ok

          _ ->
            {:ok, %{rows: [[agents, projects]]}} =
              repo.query("SELECT to_regclass('public.agents'), to_regclass('public.projects')")

            unless agents == nil and projects == nil do
              raise "Bridge data requires the Agent configuration release handoff before Comma startup"
            end

            :ok = SalixStore.AgentConfigurationRollout.open()
            SalixStore.AgentConfigurationRollout.complete()
        end
      end)
  end

  defp schema_ready? do
    {:ok, ready?, _started} =
      Ecto.Migrator.with_repo(Comma.Repo, fn repo -> Comma.Schema.ready?(repo) end)

    ready?
  end

  defp seed_empty_import_ledger_if_safe! do
    {:ok, _result, _started} =
      Ecto.Migrator.with_repo(Comma.Repo, fn repo ->
        case repo.get(Comma.Data.ImportRun, @release_identity) do
          nil -> insert_empty_import_ledger!(repo)
          _existing -> :already_present
        end
      end)
  end

  defp insert_empty_import_ledger!(repo) do
    counts =
      Enum.map(@product_relations, fn relation ->
        {:ok, %{rows: [[count]]}} =
          Ecto.Adapters.SQL.query(
            repo,
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM #{relation} LIMIT 1) THEN 1 ELSE 0 END"
          )

        {relation, count}
      end)

    nonempty = Enum.reject(counts, fn {_relation, count} -> count == 0 end)

    if nonempty != [] do
      raise "fresh installation requires empty Comma product tables; found #{inspect(nonempty)}"
    end

    completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    evidence = %{
      "schema_version" => 1,
      "release_identity" => @release_identity,
      "mode" => "import",
      "status" => "pass",
      "source_count" => 0,
      "source_object_count" => 0,
      "target_count" => 0,
      "checkpoint_count" => 0,
      "membership_index_count" => 0,
      "excluded_counts" => %{},
      "relation_counts" => %{},
      "source_digest" => @empty_digest,
      "target_digest" => @empty_digest,
      "checkpoint_digest" => @empty_digest,
      "checkpoint_target_digest" => @empty_digest,
      "secret_posture" => "redacted"
    }

    envelope = %{
      "release_identity" => @release_identity,
      "status" => "complete",
      "evidence" => evidence,
      "completed_at" => DateTime.to_iso8601(completed_at)
    }

    evidence_digest =
      envelope
      |> canonical()
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    repo.insert!(%Comma.Data.ImportRun{
      release_identity: @release_identity,
      status: "complete",
      evidence: evidence,
      evidence_digest: evidence_digest,
      completed_at: completed_at
    })
  end

  defp canonical(%DateTime{} = value),
    do: {:utc_microsecond, DateTime.to_unix(value, :microsecond)}

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value), do: value
end
