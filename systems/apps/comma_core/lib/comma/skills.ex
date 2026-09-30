defmodule Comma.Skills do
  @moduledoc """
  Public skill catalog projection for Comma chat mentions and the Skills list.
  """

  @description_max 280
  # Skill files are prompt-sized text; the page never needs more than this.
  @file_max_bytes 1_000_000
  @public_keys ["skill_id", "name", "description", "location", "source", "activation"]

  alias Comma.Workspaces

  def list(user, session, workspace_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      list_for_workspace(workspace)
    end
  end

  @doc """
  One skill for the Skills detail page: the public projection plus the
  `SKILL.md` `"content"` and the sorted `"files"` paths inside the skill. The
  list omits both to keep mention payloads small.
  """
  def get(user, session, workspace_id, skill_id) when is_binary(skill_id) do
    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id) do
      get_for_workspace(workspace, skill_id)
    end
  end

  defp get_for_workspace(workspace, skill_id) do
    case Comma.Salix.Client.impl().list_agent_skills(workspace) do
      {:ok, %{"skills" => skills}} when is_list(skills) ->
        case Enum.find(skills, &(is_map(&1) and &1["skill_id"] == skill_id)) do
          nil ->
            {:error, :not_found}

          skill ->
            {:ok,
             skill
             |> public_skill()
             |> Map.put("content", content(skill))
             |> Map.put("files", files(skill))}
        end

      {:ok, _other} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :skills_unavailable}
    end
  end

  @doc """
  One text file of a skill by its path inside the skill, as
  `%{"path" => path, "content" => text}`.
  """
  def read_file(user, session, workspace_id, skill_id, path)
      when is_binary(skill_id) and is_binary(path) do
    client = Comma.Salix.Client.impl()

    with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
         true <- function_exported?(client, :read_agent_skill_file, 4),
         {:ok, body} <- client.read_agent_skill_file(workspace, skill_id, path, @file_max_bytes),
         true <- String.valid?(body) do
      {:ok, %{"path" => path, "content" => body}}
    else
      false -> {:error, :unsupported_file_type}
      {:error, :too_large} -> {:error, :file_too_large}
      {:error, reason} when reason in [:not_found, :forbidden] -> {:error, reason}
      {:error, _reason} -> {:error, :skills_unavailable}
    end
  end

  def list_for_workspace(workspace) when is_map(workspace) do
    case Comma.Salix.Client.impl().list_agent_skills(workspace) do
      {:ok, %{"skills" => skills}} when is_list(skills) ->
        {:ok, skills |> Enum.filter(&is_map/1) |> Enum.map(&public_skill/1)}

      {:ok, _other} ->
        {:ok, []}

      {:error, :not_found} ->
        {:ok, []}

      {:error, _reason} ->
        {:error, :skills_unavailable}
    end
  end

  defp public_skill(skill) do
    skill
    |> Map.take(@public_keys)
    |> Map.update("description", "", &truncate_description/1)
  end

  defp content(%{"content" => content}) when is_binary(content), do: content
  defp content(_skill), do: ""

  defp files(%{"files" => files}) when is_list(files), do: Enum.filter(files, &is_binary/1)
  defp files(_skill), do: []

  defp truncate_description(value) when is_binary(value),
    do: String.slice(value, 0, @description_max)

  defp truncate_description(_value), do: ""
end
