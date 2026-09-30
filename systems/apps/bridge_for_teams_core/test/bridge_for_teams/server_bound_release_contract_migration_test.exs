defmodule BridgeForTeams.ServerBoundReleaseContractMigrationTest do
  use ExUnit.Case, async: false

  alias BridgeForTeams.Repo

  @contract_version 20_260_827_000_002

  Code.require_file(
    "../../priv/release_migrations/20260827000002_contract_server_bound_release_refs.exs",
    __DIR__
  )

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    :ok
  end

  test "install codes and provisioners retain only server-bound release state" do
    on_exit(&restore_expand_schema!/0)
    restore_expand_schema!()

    apply_contract!()

    assert column_names("mac_mini_install_codes")
           |> MapSet.disjoint?(
             MapSet.new([
               "release_catalog_id",
               "release_snapshot"
             ])
           )

    assert MapSet.subset?(
             MapSet.new(["release_id", "runner_stable_id"]),
             column_names("mac_mini_install_codes")
           )

    assert column_names("mac_mini_provisioners")
           |> MapSet.disjoint?(
             MapSet.new([
               "target_release_id",
               "component_targets",
               "salix_connect_target_id",
               "agent_vmm_host_target_id"
             ])
           )

    refute MapSet.member?(
             index_names("mac_mini_install_codes"),
             "mac_mini_install_codes_release_catalog_id_index"
           )

    assert index_names("mac_mini_provisioners")
           |> MapSet.disjoint?(
             MapSet.new([
               "mac_mini_provisioners_salix_connect_target_id_index",
               "mac_mini_provisioners_agent_vmm_host_target_id_index"
             ])
           )
  end

  defp apply_contract! do
    assert :ok =
             Ecto.Migrator.up(
               Repo,
               @contract_version,
               BridgeForTeams.Repo.Migrations.ContractServerBoundReleaseRefs,
               strict_version_order: false,
               log: false
             )
  end

  defp restore_expand_schema! do
    Repo.query!("""
    ALTER TABLE mac_mini_install_codes
      ADD COLUMN IF NOT EXISTS release_catalog_id text,
      ADD COLUMN IF NOT EXISTS release_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb
    """)

    Repo.query!("""
    ALTER TABLE mac_mini_provisioners
      ADD COLUMN IF NOT EXISTS target_release_id text,
      ADD COLUMN IF NOT EXISTS component_targets jsonb NOT NULL DEFAULT '{}'::jsonb,
      ADD COLUMN IF NOT EXISTS salix_connect_target_id text,
      ADD COLUMN IF NOT EXISTS agent_vmm_host_target_id text
    """)

    Repo.query!("""
    CREATE INDEX IF NOT EXISTS mac_mini_install_codes_release_catalog_id_index
      ON mac_mini_install_codes (release_catalog_id)
    """)

    Repo.query!("""
    CREATE INDEX IF NOT EXISTS mac_mini_provisioners_salix_connect_target_id_index
      ON mac_mini_provisioners (salix_connect_target_id)
    """)

    Repo.query!("""
    CREATE INDEX IF NOT EXISTS mac_mini_provisioners_agent_vmm_host_target_id_index
      ON mac_mini_provisioners (agent_vmm_host_target_id)
    """)

    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@contract_version])
  end

  defp column_names(table) do
    Repo.query!(
      """
      SELECT column_name
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = $1
      """,
      [table]
    ).rows
    |> Enum.map(fn [name] -> name end)
    |> MapSet.new()
  end

  defp index_names(table) do
    Repo.query!(
      """
      SELECT indexname
      FROM pg_indexes
      WHERE schemaname = current_schema()
        AND tablename = $1
      """,
      [table]
    ).rows
    |> Enum.map(fn [name] -> name end)
    |> MapSet.new()
  end
end
