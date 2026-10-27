defmodule SalixIM.MiniApps do
  @moduledoc """
  The Mini App owner as Salix IM reaches it (`Comma.MiniApps`, in the product).
  Salix cannot depend on the product, so the product sets the module that
  implements this behaviour at start (`config :salix_im, :mini_apps`).
  Without it, every call answers `{:error, :mini_apps_unavailable}`.

    * `create/2`: the Router tool `internal.apps.create`. The product makes the
      Mini App and its GitHub repository (from the template, or an existing
      repository that has `comma-app.json`), and answers its `app_id`, `repo`
      and `url`: the Comma page that runs the app for the Workspace's members.
    * `list/1`, `get/2`: the Router tools `internal.apps.list` and
      `internal.apps.get`. The Group's apps that its Router may name to any
      member (not a member's own private app), each as `app_id`, `name`,
      `description`, `repo`, `url`, `visibility`, `status`, `live_version`
      and `latest_version`. Includes installed apps. `list/1` answers the 50
      newest and `has_more`. `get/2` includes owner Versions and settings.
    * `manage/3`: Router management actions under the current Workspace
      binding and owner permissions. Uses the user API's product operations.
    * `repo/2`: the repository of a Mini App of the Group, which a Task with
      `mini_app {app_id}` must check out (`SalixIM.TaskPlacement`).
    * `telegram_buttons/2`: the Telegram buttons that open, inside Telegram,
      the Group's apps whose Comma URL (`url`) a message to the Group's own
      Comma-managed Telegram chat gives (`SalixIM.Provider.Telegram`).
  """

  @type scope :: %{tenant_id: String.t(), group_id: String.t(), agent_id: String.t()}
  @type repo :: %{String.t() => String.t()}

  @callback create(scope(), params :: map()) ::
              {:ok, %{String.t() => term()}} | {:error, term()}
  @callback list(group_id :: String.t()) ::
              {:ok, %{String.t() => term()}} | {:error, term()}
  @callback get(group_id :: String.t(), app_id :: String.t()) ::
              {:ok, %{String.t() => term()}} | {:error, term()}
  @callback manage(scope(), action :: String.t(), params :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback repo(group_id :: String.t(), app_id :: String.t()) ::
              {:ok, repo()} | {:error, :not_found}
  @callback telegram_buttons(group_id :: String.t(), text :: String.t()) :: [map()]

  @optional_callbacks telegram_buttons: 2

  @spec create(scope(), map()) :: {:ok, map()} | {:error, term()}
  def create(scope, params) do
    case port() do
      nil -> {:error, :mini_apps_unavailable}
      module -> module.create(scope, params)
    end
  end

  @spec list(String.t()) :: {:ok, map()} | {:error, term()}
  def list(group_id) do
    case port() do
      nil -> {:error, :mini_apps_unavailable}
      module -> module.list(group_id)
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(group_id, app_id) do
    case port() do
      nil -> {:error, :mini_apps_unavailable}
      module -> module.get(group_id, app_id)
    end
  end

  @spec repo(String.t(), String.t()) :: {:ok, repo()} | {:error, term()}
  def repo(group_id, app_id) do
    case port() do
      nil -> {:error, :mini_apps_unavailable}
      module -> module.repo(group_id, app_id)
    end
  end

  @spec manage(scope(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def manage(scope, action, params) do
    case port() do
      nil -> {:error, :mini_apps_unavailable}
      module -> module.manage(scope, action, params)
    end
  end

  @doc """
  Telegram inline keyboard buttons (`web_app`) for the Group's apps whose Comma URL `text` gives, in its order; empty
  without an owner that makes them.
  """
  @spec telegram_buttons(String.t(), String.t()) :: [map()]
  def telegram_buttons(group_id, text) do
    module = port()

    if module && Code.ensure_loaded?(module) && function_exported?(module, :telegram_buttons, 2),
      do: module.telegram_buttons(group_id, text),
      else: []
  end

  defp port, do: SystemsRuntime.get_env(:salix_im, :mini_apps)
end
