defmodule BridgeForTeams.MeetingPreparation do
  @moduledoc "Organization-admin boundary for Group-owned meeting preparation settings."
  import Ecto.Query
  alias BridgeForTeams.{Memberships, Projects, Repo}
  alias BridgeForTeams.Schema.Project
  alias BridgeForTeams.Salix.Client

  def projects(org, user) do
    with :ok <- authorize(org, user) do
      projects =
        Repo.all(
          from p in Project,
            where: p.org_id == ^org.id and is_nil(p.archived_at),
            order_by: [asc: p.name, asc: p.id],
            limit: 51
        )

      {:ok, %{projects: Enum.take(projects, 50), truncated: length(projects) > 50}}
    end
  end

  def run(org, user, project_id, action, attrs \\ %{}) do
    with :ok <- authorize(org, user),
         {:ok, id} <- Ecto.UUID.cast(project_id),
         {:ok, project} <- Projects.get_project(id),
         true <- project.org_id == org.id and is_nil(project.archived_at),
         true <- is_binary(project.salix_group_id),
         true <-
           Code.ensure_loaded?(Client.impl()) and
             function_exported?(Client.impl(), :meeting_preparation, 1) do
      Client.impl().meeting_preparation(%{
        "tenant_id" => org.salix_tenant_id,
        "group_id" => project.salix_group_id,
        "action" => action,
        "attrs" => attrs
      })
    else
      :error -> {:error, :project_not_found}
      false -> {:error, :project_not_found}
      {:error, _} = error -> error
    end
  end

  defp authorize(org, user) do
    case Memberships.org_role(org.id, user.id) do
      {:ok, role} when role in ["owner", "admin"] -> :ok
      _ -> {:error, :forbidden}
    end
  end
end
