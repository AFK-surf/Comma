defmodule Comma.Workers.SynchronicityProvision do
  @moduledoc "Provisions Drive independently of Workspace readiness."

  use Oban.Worker,
    queue: :comma_drive,
    max_attempts: 12,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  alias Comma.Data.Workspace
  alias Comma.{Repo, Synchronicity}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workspace_id" => workspace_id}}) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{status: "active", kind: "standard"} = workspace ->
        if Synchronicity.configured?(), do: provision(workspace), else: :ok

      _ ->
        :ok
    end
  end

  defp provision(workspace) do
    with {:ok, _} <- Synchronicity.provision_workspace(workspace),
         {:ok, _} <- Synchronicity.ensure_agent_key(workspace) do
      :ok
    else
      {:error, :explicit_link_required} ->
        {:cancel, :synchronicity_link_required}

      {:error, :auth} ->
        {:cancel, :synchronicity_auth}

      {:error, reason} when reason in [:owner_not_found, :workspace_not_found] ->
        {:cancel, reason}

      {:error, {:invalid, _}} ->
        {:cancel, :synchronicity_invalid}

      {:error, _} ->
        {:error, :synchronicity_unavailable}
    end
  rescue
    _exception -> {:error, :synchronicity_unavailable}
  end
end
