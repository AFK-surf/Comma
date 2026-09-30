defmodule CommaWeb.TestRepoSandbox do
  @moduledoc false

  @cleanup_schemas [
    Comma.Data.ExternalOperation,
    Comma.Accounts.AuthSession,
    Comma.Accounts.Identity,
    Comma.Data.SessionBudgetConsumption,
    Comma.Data.Session,
    Comma.Data.WorkspaceMembership,
    Comma.Data.Workspace,
    Comma.Data.User
  ]

  def start_owner!(:transaction) do
    {:owner, Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)}
  end

  def start_owner!(:multi_connection) do
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :auto)
    cleanup!()
    :multi_connection
  end

  def stop_owner({:owner, owner}) do
    Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
  end

  def stop_owner(:multi_connection) do
    cleanup!()
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Comma.Repo, :manual)
  end

  defp cleanup! do
    Enum.each(@cleanup_schemas, &Comma.Repo.delete_all/1)
  end
end
