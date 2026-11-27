defmodule SalixWeb.TaskLinks do
  @moduledoc """
  Where a person opens a Task in the product (Comma), for a station that
  takes part in it (`SalixWeb.StationTasks`). Salix cannot depend on the
  product, so the product sets the module that implements this behaviour at
  start (`config :salix_web, :task_links`). Without it, `links/2` answers
  `nil` and stations are given no links.

    * `links/2`: the links of Task `conversation_id` of Group `group_id`:
      `"web"`, its page in the web app, and `"app"`, the deep link that
      opens it in the desktop and mobile apps. `nil` when the Group is no
      Workspace's.
  """

  @type links :: %{String.t() => String.t()}

  @callback links(group_id :: String.t(), conversation_id :: String.t()) :: links() | nil

  @spec links(String.t(), String.t()) :: links() | nil
  def links(group_id, conversation_id) do
    case SystemsRuntime.get_env(:salix_web, :task_links) do
      nil -> nil
      module -> module.links(group_id, conversation_id)
    end
  end
end
