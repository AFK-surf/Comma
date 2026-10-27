defmodule CommaWeb.MiniAppPort do
  @moduledoc """
  How Salix reaches the Mini App owner (`Comma.MiniApps`), which `salix_im`
  and `salix_web` cannot depend on. `CommaWeb.Application` configures it as
  `:salix_im, :mini_apps` and `:salix_web, :mini_app_deploys`.

    * `create/2`: the Router tool `internal.apps.create`, with the URL that
      runs the app in Comma (`run_url/2`), which a Router gives a user who
      asked from another chat (Signal, Telegram);
    * `list/1`, `get/2`: the Router tools `internal.apps.list` and
      `internal.apps.get`, the Workspace's apps a Router may name to any
      member (`Comma.MiniApps.router_apps/2`), each with its URL;
    * `repo/2`: the app's repository, which a `mini_app` Task must use;
    * `telegram_buttons/2`: a button for each app whose `run_url/2` a message
      to the Workspace's Comma Telegram chat gives, which opens the app inside
      Telegram (`telegram_app_url/3`);
    * `deploy/2`: steps 2–6 of a deploy (`Comma.MiniApps.Deploys`), with the
      commit checked on the pushed session branch on GitHub;
    * `logs/2`: the app's recent backend errors.

  It also holds the GitHub side of making an app (`create_app/3`), shared by
  the Router tool and `POST /v1/comma/workspaces/:ws/apps`, and remix.
  """

  @behaviour SalixIM.MiniApps
  @behaviour SalixWeb.MiniAppDeploys

  alias Comma.Data.Workspace
  alias Comma.MiniApps
  alias Comma.MiniApps.{App, Blobs, Config, Deploys, RateLimit}
  alias Comma.Repo

  @manifest "comma-app.json"
  @router_list_limit 50
  @telegram_buttons_max 3
  @telegram_button_name_max 40

  # --- SalixIM.MiniApps

  @impl true
  def create(%{group_id: group_id}, params) when is_map(params) do
    with %Workspace{status: "active"} = workspace <-
           Repo.get_by(Workspace, salix_group_id: group_id) || {:error, :not_found},
         {:ok, app} <- create_app(workspace, nil, params) do
      {:ok,
       %{
         "app_id" => app.id,
         "repo" => %{"owner" => app.repo_owner, "name" => app.repo_name},
         "url" => run_url(workspace.id, app.id)
       }}
    else
      %Workspace{} -> {:error, :mini_apps_unavailable}
      {:error, {:bad_request, message}} -> {:error, {:invalid, message}}
      {:error, _} = error -> error
    end
  end

  def create(_scope, _params), do: {:error, {:invalid, "params must be an object"}}

  @impl true
  def list(group_id) do
    with {:ok, workspace} <- router_workspace(group_id) do
      {apps, ctx} = MiniApps.router_apps(workspace, @router_list_limit + 1)

      {:ok,
       %{
         "apps" =>
           apps |> Enum.take(@router_list_limit) |> Enum.map(&router_view(&1, ctx, workspace.id)),
         "has_more" => length(apps) > @router_list_limit
       }}
    end
  end

  @impl true
  def get(group_id, app_id) do
    with {:ok, workspace} <- router_workspace(group_id),
         {:ok, _app} <- MiniApps.router_app(workspace, app_id),
         {:ok, user} <- Comma.Accounts.get_user(workspace.owner_user_id),
         {:ok, view} <-
           MiniApps.show(user, {:router, workspace.salix_router_agent_id}, workspace.id, app_id) do
      {:ok, Map.merge(view, %{"app_id" => app_id, "url" => run_url(workspace.id, app_id)})}
    end
  end

  defp router_view(%App{} = app, ctx, workspace_id) do
    MiniApps.view(app, ctx, workspace_id)
    |> Map.merge(%{"app_id" => app.id, "url" => run_url(workspace_id, app.id)})
  end

  defp router_workspace(group_id) do
    case Repo.get_by(Workspace, salix_group_id: group_id) do
      %Workspace{status: "active", kind: "standard"} = workspace -> {:ok, workspace}
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def repo(group_id, app_id) do
    case MiniApps.get_group_app(group_id, app_id) do
      {:ok, app} -> {:ok, %{"owner" => app.repo_owner, "name" => app.repo_name}}
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def telegram_buttons(group_id, text) when is_binary(group_id) and is_binary(text) do
    case router_workspace(group_id) do
      {:ok, workspace} ->
        prefix = Regex.escape(web_origin() <> "/#/apps/" <> workspace.id <> "/")

        Regex.compile!(prefix <> "([0-9A-Za-z-]{1,64})/run")
        |> Regex.scan(text, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.flat_map(fn app_id ->
          case MiniApps.router_app(workspace, app_id) do
            {:ok, app} ->
              [
                %{
                  "text" => "▶️ " <> String.slice(app.name, 0, @telegram_button_name_max),
                  "web_app" => %{"url" => telegram_app_url(workspace.id, group_id, app.id)}
                }
              ]

            _ ->
              []
          end
        end)
        |> Enum.take(@telegram_buttons_max)

      _ ->
        []
    end
  end

  def telegram_buttons(_group_id, _text), do: []

  @doc """
  The page a Telegram `web_app` button opens for app `app_id`: the Telegram
  panel (`task-panel.html`), which signs the member in with the Telegram launch
  (`CommaWeb.TelegramMiniAppAuth`) and runs the app alone.
  """
  def telegram_app_url(workspace_id, group_id, app_id) do
    query =
      URI.encode_query(%{
        "workspace_id" => workspace_id,
        "group_id" => group_id,
        "app_id" => app_id,
        "source" => "telegram"
      })

    web_origin() <> "/task-panel.html?" <> query
  end

  @impl true
  def manage(scope, action, params),
    do: CommaWeb.MiniAppManagement.call(scope, action, params)

  @doc """
  The Comma web page that runs app `app_id` of Workspace `workspace_id` for
  its members (`#/apps/<ws>/<app>/run`): the live Version, or before Publish
  the latest preview. A signed-out member signs in on that page.
  """
  def run_url(workspace_id, app_id),
    do: "#{web_origin()}/#/apps/#{workspace_id}/#{app_id}/run"

  defp web_origin,
    do: SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin) |> String.trim_trailing("/")

  # --- SalixWeb.MiniAppDeploys

  @impl true
  def deploy(ctx, files) when is_map(ctx) and is_map(files) do
    workspace = Repo.get_by(Workspace, salix_group_id: ctx[:group_id])

    commit_check = fn app ->
      with %Workspace{} <- workspace || {:error, :not_found},
           {:ok, %{token: token}} <-
             github().token(workspace.salix_tenant_id, workspace.salix_group_id) do
        github().commit_on_branch(token, app.repo_owner, app.repo_name, ctx.commit, ctx.branch)
      end
    end

    Deploys.deploy(ctx, files, commit_check)
  end

  @impl true
  def logs(%{group_id: group_id, app_id: app_id}, version) do
    with {:ok, app} <- MiniApps.get_group_app(group_id, app_id) do
      RateLimit.errors(app.id, version)
    end
  end

  # --- Making apps

  @doc """
  Makes an app in `workspace` for user `user_id` (nil for the Router):
  from `params["repo"]` when it names an existing repository that has
  `comma-app.json`, else from the template as private repository
  `comma-app-<slug>` of the connected GitHub account.
  """
  def create_app(%Workspace{} = workspace, user_id, params) do
    with {:ok, attrs} <- MiniApps.app_attrs(params),
         {:ok, %{token: token}} <-
           github().token(workspace.salix_tenant_id, workspace.salix_group_id) do
      case params["repo"] do
        %{"owner" => owner, "name" => name} when is_binary(owner) and is_binary(name) ->
          from_repo(workspace, user_id, attrs, token, owner, name)

        nil ->
          from_template(workspace, user_id, attrs, token)

        _ ->
          {:error, {:bad_request, "repo names an owner and a name"}}
      end
    end
  end

  defp from_repo(workspace, user_id, attrs, token, owner, name) do
    case github().file_exists(token, owner, name, @manifest) do
      :ok ->
        MiniApps.insert_app(
          workspace,
          user_id,
          Map.merge(attrs, %{slug: MiniApps.new_slug(), repo_owner: owner, repo_name: name})
        )

      {:error, :not_found} ->
        {:error, {:repo_not_found, owner <> "/" <> name}}

      error ->
        error
    end
  end

  defp from_template(workspace, user_id, attrs, token) do
    slug = MiniApps.new_slug()
    {template_owner, template_name} = Config.template_repo()

    with {:ok, %{login: login}} <- github().user(token),
         {:ok, app} <-
           MiniApps.insert_app(
             workspace,
             user_id,
             Map.merge(attrs, %{slug: slug, repo_owner: login, repo_name: "comma-app-" <> slug})
           ) do
      case github().generate_from_template(
             token,
             template_owner <> "/" <> template_name,
             login,
             app.repo_name
           ) do
        {:ok, _repo} ->
          {:ok, app}

        error ->
          MiniApps.discard_new_app(app)
          error
      end
    end
  end

  @doc """
  Remix: a new app and repository in the viewer's GitHub account from the
  shared live Version's source archive, then a Coding Task on it.
  """
  def remix(user, session, workspace_id, token, opts \\ []) do
    creator = if Keyword.get(opts, :initiator_kind) == "agent", do: nil, else: user["id"]

    with {:ok, workspace, _role} <- MiniApps.member(user, session, workspace_id, :write),
         {:ok, source_app} <- MiniApps.resolve_link(token),
         %Comma.MiniApps.Version{} = version <-
           MiniApps.live_version(source_app) || {:error, :not_found},
         {:ok, archive} <- Blobs.get(Blobs.source_key(source_app.id, version.number)),
         {:ok, files} <- source_files(archive),
         {:ok, %{token: gh}} <-
           github().token(workspace.salix_tenant_id, workspace.salix_group_id),
         {:ok, %{login: login}} <- github().user(gh),
         slug = MiniApps.new_slug(),
         {:ok, app} <-
           MiniApps.insert_app(workspace, creator, %{
             slug: slug,
             name: source_app.name,
             description: source_app.description || "",
             repo_owner: login,
             repo_name: "comma-app-" <> slug
           }),
         {:ok, _repo} <-
           made_or_discarded(
             app,
             github().create_repo_with_files(
               gh,
               app.repo_name,
               files,
               "Remix of #{source_app.name} (version #{version.number})"
             )
           ),
         {:ok, task} <- start_task(workspace, user, app, source_app) do
      {:ok, %{"app" => MiniApps.view_one(app, workspace.id), "task" => task}}
    end
  end

  defp made_or_discarded(_app, {:ok, repo}), do: {:ok, repo}

  defp made_or_discarded(app, error) do
    MiniApps.discard_new_app(app)
    error
  end

  defp start_task(workspace, user, %App{} = app, source_app) do
    group = workspace.salix_group_id
    text = "Remix the app \"#{source_app.name}\" in this repository. Ask me what to change first."

    with {:ok, %{"router_agent_id" => router}} when is_binary(router) <-
           SalixIM.GroupDirectory.get_group(group),
         {:ok, created} <-
           SalixIM.TaskPlacement.create_task_conversation(group, router, %{
             "runs_on" => %{"kind" => "sandbox"},
             "repo" => %{"owner" => app.repo_owner, "name" => app.repo_name, "base_ref" => "main"},
             "mini_app" => %{"app_id" => app.id},
             "content" => text,
             "title" => "Remix #{source_app.name}",
             "client_request_id" => "comma-mini-app-remix:" <> app.id,
             "owner_user_id" => user["id"],
             "initial_author" => "owner",
             "source_refs" => %{"origin_agent_id" => router}
           }) do
      {:ok, %{"group_id" => group, "conversation_id" => created["conversation_id"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :temporarily_unavailable}
    end
  end

  # The regular files of a `git archive --format=tar.gz`, with their executable bit.
  defp source_files(archive) do
    with {:ok, entries} <- :erl_tar.table({:binary, archive}, [:compressed, :verbose]),
         {:ok, contents} <- :erl_tar.extract({:binary, archive}, [:compressed, :memory]) do
      modes =
        for {name, :regular, _size, _mtime, mode, _uid, _gid} <- entries,
            into: %{},
            do: {to_string(name), mode}

      files =
        for {name, data} <- contents,
            name = to_string(name),
            Map.has_key?(modes, name),
            name != "pax_global_header",
            do: {name, data, Bitwise.band(modes[name], 0o111) != 0}

      {:ok, files}
    else
      _ -> {:error, :source_unavailable}
    end
  end

  defp github, do: SalixWeb.CodingSandboxes.github()
end
