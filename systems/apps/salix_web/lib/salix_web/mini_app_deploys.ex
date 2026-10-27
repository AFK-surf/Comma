defmodule SalixWeb.MiniAppDeploys do
  @moduledoc """
  The Mini App owner as a coding sandbox's deploy reaches it (`Comma.MiniApps`,
  in the product). Salix cannot depend on the product, so the product sets the
  module that implements this behaviour at start
  (`config :salix_web, :mini_app_deploys`). Without it, every call answers
  `{:error, :mini_apps_unavailable}`.

  `SalixWeb.StationTasks` checks who deploys (the Task's current sandbox, a
  Task of that app) and appends the `mini_app` Message; the owner checks the
  commit, admission and the files, stores the Version and uploads its backend.

    * `deploy/2`: `files` are temp files on this node (`%{path: path}`), and
      `:manifest` the manifest's bytes. A repeated `key` of the same app
      answers the same Version.
    * `logs/2`: recent backend log lines of the app (or of one Version).
  """

  @type blob_file :: %{path: String.t()}

  @callback deploy(ctx :: map(), files :: %{required(atom()) => blob_file() | binary()}) ::
              {:ok, %{String.t() => term()}}
              | {:error, {:invalid, [String.t()]}}
              | {:error, term()}
  @callback logs(ctx :: %{group_id: String.t(), app_id: String.t()}, pos_integer() | nil) ::
              {:ok, [String.t()]} | {:error, term()}

  @spec deploy(map(), map()) :: {:ok, map()} | {:error, term()}
  def deploy(ctx, files) do
    case port() do
      nil -> {:error, :mini_apps_unavailable}
      module -> module.deploy(ctx, files)
    end
  end

  @spec logs(map(), pos_integer() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def logs(ctx, version) do
    case port() do
      nil -> {:error, :mini_apps_unavailable}
      module -> module.logs(ctx, version)
    end
  end

  defp port, do: SystemsRuntime.get_env(:salix_web, :mini_app_deploys)
end
