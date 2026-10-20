defmodule BridgeForTeams.Repo.Migrations.DropFeishuAppBindingDomain do
  @moduledoc """
  Retire `feishu_app_bindings.domain`. #3582 added it so that an
  organization's Feishu app could be a Lark app. #3589 removed that choice:
  a Lark app connects to an Agent Swarm as its own provider, and no runtime
  after that release reads or writes the column.

  Only staging ran the migration that added the column; it is withdrawn
  (`historical-ledger-only` in the release manifest), so no other
  environment has the column, and there the step changes nothing.

  Before a contract operation selects this step, the operator confirms two
  facts that the release tooling does not check: every running instance of
  the environment is on a release with #3589, and a backup of the table can
  be restored. `down` adds the column again with its default; it does not
  bring back the values.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:feishu_app_bindings) do
      remove_if_exists(:domain)
    end
  end

  def down do
    alter table(:feishu_app_bindings) do
      add(:domain, :string, null: false, default: "feishu")
    end
  end
end
