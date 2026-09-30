defmodule BridgeForTeams.DataCase do
  @moduledoc """
  Test case for tests that touch the database. Uses
  `Ecto.Adapters.SQL.Sandbox` (manual mode); each test checks out a connection
  and runs in a rolled-back transaction. The Salix client is the real erpc
  boundary against the in-process Salix apps; OIDC remains injected in tests.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias BridgeForTeams.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import BridgeForTeams.DataCase
    end
  end

  setup tags do
    owner_opts =
      [shared: not tags[:async]]
      |> then(fn opts ->
        case tags[:sandbox_ownership_timeout] do
          :infinity ->
            Keyword.put(opts, :ownership_timeout, :infinity)

          timeout when is_integer(timeout) and timeout > 0 ->
            Keyword.put(opts, :ownership_timeout, timeout)

          _default ->
            opts
        end
      end)

    bridge_owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(BridgeForTeams.Repo, owner_opts)

    billing_owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, owner_opts)

    on_exit(fn ->
      _ = BridgeForTeams.EnvironmentRuntimeObserver.drain(30_000)
      Ecto.Adapters.SQL.Sandbox.stop_owner(bridge_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    :ok
  end

  @doc "Convert changeset errors into a `%{field => [messages]}` map for assertions."
  @spec errors_on(Ecto.Changeset.t()) :: %{atom() => [String.t()]}
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc "Persist an archived agent fixture without exercising current archive policy."
  def archive_agent_fixture!(%{configuration_authority: "salix"} = agent) do
    project = BridgeForTeams.Repo.get!(BridgeForTeams.Schema.Project, agent.project_id)
    org = BridgeForTeams.Repo.get!(BridgeForTeams.Schema.Organization, project.org_id)

    {:ok, _} =
      BridgeForTeams.Salix.Erpc.archive_agent_configuration(
        agent.salix_agent_id,
        org.salix_tenant_id
      )

    {:ok, archived} = BridgeForTeams.Agents.get_agent(agent.id)
    archived
  end

  def archive_agent_fixture!(agent) do
    {:ok, id} = Ecto.UUID.dump(agent.id)
    at = DateTime.utc_now()

    BridgeForTeams.Repo.query!(
      "UPDATE agents SET archived_at = $1, status = 'archived' WHERE id = $2",
      [at, id]
    )

    %{agent | salix: Map.put(agent.salix, "archived_at", DateTime.to_unix(at))}
  end
end
