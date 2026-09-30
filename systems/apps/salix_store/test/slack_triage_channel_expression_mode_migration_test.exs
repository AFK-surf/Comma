defmodule SalixStore.SlackTriageChannelExpressionModeMigrationTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Repo, SlackTriageChannels, ULID}

  @migration_version 20_260_831_000_104

  Code.require_file(
    "../priv/repo/migrations/20260831000104_add_slack_triage_channel_expression_mode.exs",
    __DIR__
  )

  setup do
    ensure_migration!()
    Repo.query!("TRUNCATE slack_triage_channels")

    on_exit(fn ->
      ensure_migration!()
      Repo.query!("TRUNCATE slack_triage_channels")
    end)

    :ok
  end

  test "rollback preserves non-project policy and succeeds after the data is project-only" do
    installation_generation = ULID.generate()

    assert {:ok, %{"expression_mode" => "social"}} =
             SlackTriageChannels.provision(%{
               "tenant_id" => "tenant-expression-rollback",
               "group_id" => "group-expression-rollback",
               "connect_id" => "connect-expression-rollback",
               "channel_id" => "C_EXPRESSION_ROLLBACK",
               "installation_generation" => installation_generation,
               "workspace_id" => "T_EXPRESSION_ROLLBACK",
               "channel_name" => "watercooler",
               "expression_mode" => "social"
             })

    assert_raise Postgrex.Error,
                 ~r/cannot drop slack triage expression policy while non-project values exist/,
                 fn -> rollback!() end

    assert %{rows: [["social", true]]} =
             Repo.query!("""
             SELECT expression_mode,
                    EXISTS (
                      SELECT 1
                      FROM pg_constraint
                      WHERE conname = 'slack_triage_channels_valid_expression_mode'
                        AND conrelid = 'slack_triage_channels'::regclass
                        AND convalidated
                    )
             FROM slack_triage_channels
             WHERE tenant_id = 'tenant-expression-rollback'
             """)

    Repo.query!("UPDATE slack_triage_channels SET expression_mode = 'project'")

    assert :ok = rollback!()

    assert %{rows: [[false]]} =
             Repo.query!("""
             SELECT EXISTS (
               SELECT 1
               FROM information_schema.columns
               WHERE table_schema = current_schema()
                 AND table_name = 'slack_triage_channels'
                 AND column_name = 'expression_mode'
             )
             """)

    assert :ok = ensure_migration!()

    assert %{rows: [["project", true]]} =
             Repo.query!("""
             SELECT expression_mode,
                    EXISTS (
                      SELECT 1
                      FROM pg_constraint
                      WHERE conname = 'slack_triage_channels_valid_expression_mode'
                        AND conrelid = 'slack_triage_channels'::regclass
                        AND convalidated
                    )
             FROM slack_triage_channels
             WHERE tenant_id = 'tenant-expression-rollback'
             """)
  end

  defp rollback! do
    Ecto.Migrator.down(
      Repo,
      @migration_version,
      SalixStore.Repo.Migrations.AddSlackTriageChannelExpressionMode,
      log: false
    )
  end

  defp ensure_migration! do
    case Ecto.Migrator.up(
           Repo,
           @migration_version,
           SalixStore.Repo.Migrations.AddSlackTriageChannelExpressionMode,
           log: false
         ) do
      :ok -> :ok
      :already_up -> :ok
    end
  end
end
