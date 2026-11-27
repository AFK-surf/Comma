defmodule CommaWeb.TaskLinkPort do
  @moduledoc """
  Where a member opens a Task of a Workspace (`SalixWeb.TaskLinks`), which
  Salix gives each station that takes part in the Task
  (`SalixWeb.StationTasks`). `CommaWeb.Application` configures it as
  `:salix_web, :task_links`.

    * `"web"`: the Task in the web app, `<origin>/#/tasks/<ws>/<group>/<task>`;
    * `"app"`: the deep link the desktop and mobile apps open,
      `<scheme>://task?workspace=<ws>&group=<group>&task=<task>`, in the
      scheme the environment's apps register (`:comma_web, :app_url_scheme`).

  A Group that is no Workspace's has no links.
  """

  @behaviour SalixWeb.TaskLinks

  import Ecto.Query, only: [from: 2]

  alias Comma.Data.Workspace
  alias Comma.Repo

  @impl true
  def links(group_id, conversation_id)
      when is_binary(group_id) and group_id != "" and is_binary(conversation_id) and
             conversation_id != "" do
    case Repo.one(from(w in Workspace, where: w.salix_group_id == ^group_id, select: w.id)) do
      workspace_id when is_binary(workspace_id) and workspace_id != "" ->
        %{
          "web" => web_url(workspace_id, group_id, conversation_id),
          "app" => app_url(workspace_id, group_id, conversation_id)
        }

      _ ->
        nil
    end
  end

  def links(_group_id, _conversation_id), do: nil

  defp web_url(workspace_id, group_id, conversation_id) do
    origin =
      SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin) |> String.trim_trailing("/")

    origin <>
      "/#/tasks/" <>
      Enum.map_join(
        [workspace_id, group_id, conversation_id],
        "/",
        &URI.encode(&1, fn c -> URI.char_unreserved?(c) end)
      )
  end

  defp app_url(workspace_id, group_id, conversation_id) do
    query =
      URI.encode_query([
        {"workspace", workspace_id},
        {"group", group_id},
        {"task", conversation_id}
      ])

    SystemsRuntime.fetch_env!(:comma_web, :app_url_scheme) <> "://task?" <> query
  end
end
