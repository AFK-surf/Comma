defmodule Comma.MiniApps do
  @moduledoc """
  Owner of Mini Apps (design: GitHub issue AFK-surf/Cue#4070;
  `docs/architecture/DOMAIN_CONCEPTS.md`): the app row, its Versions, its
  share Link and other Workspaces' Installs, all in Comma PostgreSQL.

  ## Access

  A member of the app's Workspace sees a `workspace` or `link` app; a
  `private` app only its creator sees. A Workspace with an Install sees the
  Install's Version (pinned, or live). A link token lets any Comma session
  (registered or guest) run the live Version while the app's visibility is
  `link`. Owner actions need a member who sees the app and is not a
  read-only member. A `disabled` app serves nothing: no bundle, no backend,
  no storage. Every runtime call also needs the owner Workspace's billing
  availability (`app_paused`, `Comma.MiniApps.Billing`).

  ## Lifecycle

  `active` → `disabled` (by the owner, or by the platform: only the platform
  enables that again, and its Version scripts are deleted) → `deleted`.
  Delete revokes the Link and removes Installs at once; `Comma.Workers.MiniAppCleanup`
  then deletes the Workers for Platforms scripts, every object under the
  app's prefix (bundles, sources, documents) and the rows. The GitHub
  repository stays: it is the user's record.

  Version retention: the live Version, the last 20, and every Version an
  Install pins. A failed Version keeps its objects for 7 days.
  """

  import Ecto.Query
  require Logger

  alias Comma.Accounts.User
  alias Comma.Data.Workspace
  alias Comma.MiniApps.{App, Billing, Blobs, Cloudflare, Config, Install, Link, Manifest}
  alias Comma.MiniApps.{Secrets, Version, Viewer}
  alias Comma.Repo

  @visibilities ~w(private workspace link)
  @token_bytes 32
  @token_pattern ~r/\A[A-Za-z0-9_-]{43}\z/
  @slug_alphabet ~c"abcdefghijklmnopqrstuvwxyz0123456789"
  @slug_length 8
  @list_limit 200
  @versions_listed 50
  @keep_versions 20

  ## Workspace access

  @doc "The Workspace of a member: `{:ok, workspace, role}`; `:write` refuses read-only members."
  def member(user, session, workspace_id, access \\ :read)

  # The product port supplies this internal caller after resolving the Router.
  # It has no browser session; recheck its current Workspace and owner here.
  def member(
        %{"id" => owner, "status" => "active"} = user,
        {:router, router},
        workspace_id,
        _access
      )
      when is_binary(router) do
    with false <- Comma.GuestMode.guest?(user),
         %Workspace{
           status: "active",
           kind: "standard",
           owner_user_id: ^owner,
           salix_router_agent_id: ^router
         } = workspace <- Repo.get(Workspace, workspace_id),
         true <- Comma.Workspaces.active_owner?(workspace, owner) do
      {:ok, workspace, "owner"}
    else
      _ -> {:error, :forbidden}
    end
  end

  # A Telegram panel's session (`CommaWeb.TelegramMiniAppAuth`) is restricted to
  # its own Workspace. There it reads and runs the Workspace's apps as its user
  # does; it never manages them (`:write`).
  def member(
        user,
        %{"session_source" => "channel_task_panel", "workspace_id" => workspace_id} = session,
        workspace_id,
        :read
      ) do
    session = session |> Map.delete("session_source") |> Map.put("restricted", false)
    member(user, session, workspace_id, :read)
  end

  def member(user, session, workspace_id, access) do
    case Comma.Stations.member(user, session, workspace_id) do
      {:ok, workspace, role} ->
        if access == :write and Comma.Stations.Members.read_only_role?(role),
          do: {:error, :forbidden},
          else: {:ok, workspace, role}

      {:error, :forbidden} ->
        {:error, :forbidden}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "An app the member of its own Workspace may act on as its owner."
  def owner_app(user, session, workspace_id, app_id, access \\ :write) do
    with {:ok, workspace, _role} <- member(user, session, workspace_id, access),
         %App{} = app <- get_app(app_id),
         true <- app.workspace_id == workspace.id and owner_visible?(app, user) do
      {:ok, workspace, app}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  # An app the Router made has no creator: its members all see it.
  defp owner_visible?(%App{visibility: "private", created_by: creator}, user),
    do: is_nil(creator) or creator == user["id"]

  defp owner_visible?(_app, _user), do: true

  @doc "A live (not deleted) app by ID."
  def get_app(app_id) do
    with {:ok, id} <- Ecto.UUID.cast(app_id),
         %App{status: status} = app when status != "deleted" <- Repo.get(App, id) do
      app
    else
      _ -> nil
    end
  end

  @doc "An app by its group, for the Salix ports (any status but deleted)."
  def get_group_app(group_id, app_id) do
    case get_app(app_id) do
      %App{group_id: ^group_id} = app -> {:ok, app}
      _ -> {:error, :not_found}
    end
  end

  ## Create

  @doc "A new slug for the next app, which also names its repository."
  def new_slug do
    @slug_length
    |> SystemsRuntime.Proc.random_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(&Enum.at(@slug_alphabet, rem(&1, length(@slug_alphabet))))
    |> to_string()
  end

  @doc "Validates a name and description for create or rename."
  def app_attrs(params) do
    with {:ok, name} <- name(params["name"]),
         {:ok, description} <- description(params["description"]) do
      {:ok, %{name: name, description: description || ""}}
    end
  end

  @doc """
  Inserts the app row of `workspace` for the repository it names. The caller
  made (or checked) the repository first.
  """
  def insert_app(%Workspace{} = workspace, user_id, attrs) do
    now = SystemsClock.utc_now()

    %App{
      id: SystemsRuntime.Proc.uuid(),
      slug: attrs.slug,
      workspace_id: workspace.id,
      group_id: workspace.salix_group_id,
      created_by: user_id,
      name: attrs.name,
      description: attrs.description,
      repo_owner: attrs.repo_owner,
      repo_name: attrs.repo_name,
      visibility: "private",
      status: "active",
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:slug)
    |> Repo.insert()
    |> case do
      {:ok, app} -> {:ok, app}
      {:error, _} -> {:error, :temporarily_unavailable}
    end
  end

  @doc "Removes an app row whose repository could not be made."
  def discard_new_app(%App{} = app), do: Repo.delete(app)

  ## Reads

  @doc "The member's own apps and the apps its Workspace installed."
  def list(user, session, workspace_id) do
    with {:ok, workspace, _role} <- member(user, session, workspace_id) do
      installed_ids =
        from(i in Install, where: i.workspace_id == ^workspace.id, select: i.app_id)

      apps =
        from(app in App,
          where:
            app.status != "deleted" and
              ((app.workspace_id == ^workspace.id and
                  (app.visibility != "private" or is_nil(app.created_by) or
                     app.created_by == ^user["id"])) or
                 app.id in subquery(installed_ids)),
          order_by: [desc: app.updated_at, desc: app.id],
          limit: @list_limit
        )
        |> Repo.all()

      ctx = view_context(apps, workspace.id)
      {:ok, Enum.map(apps, &view(&1, ctx, workspace.id))}
    end
  end

  @doc "The Workspace's shared and installed apps, newest first, bounded by limit."
  def router_apps(%Workspace{} = workspace, limit) when is_integer(limit) and limit > 0 do
    installed_ids = from(i in Install, where: i.workspace_id == ^workspace.id, select: i.app_id)

    apps =
      from(app in App,
        where:
          app.status != "deleted" and
            ((app.workspace_id == ^workspace.id and
                (app.visibility != "private" or is_nil(app.created_by))) or
               app.id in subquery(installed_ids)),
        order_by: [desc: app.updated_at, desc: app.id],
        limit: ^limit
      )
      |> Repo.all()

    {apps, view_context(apps, workspace.id)}
  end

  @doc "One shared or installed app. Member-private apps remain outside the Router's scope."
  def router_app(%Workspace{} = workspace, app_id) do
    case get_app(app_id) do
      %App{workspace_id: id, visibility: visibility, created_by: creator} = app
      when id == workspace.id and (visibility != "private" or is_nil(creator)) ->
        {:ok, app}

      %App{workspace_id: id} = app when id != workspace.id ->
        if Repo.get_by(Install, workspace_id: workspace.id, app_id: app.id),
          do: {:ok, app},
          else: {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "One app the Workspace sees, with its latest 50 Versions when it is the owner."
  def show(user, session, workspace_id, app_id) do
    with {:ok, workspace, _role} <- member(user, session, workspace_id),
         {:ok, app, kind} <- workspace_app(workspace, user, app_id) do
      ctx = view_context([app], workspace.id)
      versions = if kind == :owner, do: versions(app), else: []
      {:ok, app |> view(ctx, workspace.id) |> Map.put("versions", versions)}
    end
  end

  # The app as the Workspace sees it: `:owner` or `:install`.
  defp workspace_app(workspace, user, app_id) do
    case get_app(app_id) do
      %App{workspace_id: id} = app when id == workspace.id ->
        if owner_visible?(app, user), do: {:ok, app, :owner}, else: {:error, :not_found}

      %App{} = app ->
        if Repo.get_by(Install, app_id: app.id, workspace_id: workspace.id),
          do: {:ok, app, :install},
          else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp versions(app) do
    live = app.live_version_id

    from(v in Version,
      where: v.app_id == ^app.id,
      order_by: [desc: v.number],
      limit: @versions_listed
    )
    |> Repo.all()
    |> Enum.map(&version_view(&1, live))
  end

  @doc "The JSON view of one Version."
  def version_view(%Version{} = v, live_version_id) do
    %{
      "number" => v.number,
      "state" => v.state,
      "commit" => v.commit,
      "digest" => v.digest,
      "has_backend" => is_binary(v.script_name),
      "conversation_id" => v.conversation_id,
      "message_seq" => v.message_seq,
      "notes" => v.notes,
      "created_at" => iso(v.inserted_at),
      "live" => v.id == live_version_id
    }
  end

  @doc false
  def view_context(apps, workspace_id) do
    ids = Enum.map(apps, & &1.id)
    live_ids = apps |> Enum.map(& &1.live_version_id) |> Enum.reject(&is_nil/1)

    live =
      if live_ids == [],
        do: %{},
        else:
          from(v in Version, where: v.id in ^live_ids)
          |> Repo.all()
          |> Map.new(&{&1.app_id, &1})

    latest =
      from(v in Version,
        where: v.app_id in ^ids and v.state == "ready",
        distinct: v.app_id,
        order_by: [asc: v.app_id, desc: v.number]
      )
      |> Repo.all()
      |> Map.new(&{&1.app_id, &1})

    installs =
      if is_nil(workspace_id),
        do: %{},
        else:
          from(i in Install, where: i.workspace_id == ^workspace_id and i.app_id in ^ids)
          |> Repo.all()
          |> Map.new(&{&1.app_id, &1})

    creators = apps |> Enum.map(& &1.created_by) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    authors =
      if creators == [],
        do: %{},
        else:
          from(u in User, where: u.id in ^creators, select: {u.id, u.name})
          |> Repo.all()
          |> Map.new()

    # The ready Versions Installs pin: what those Workspaces run.
    pins = for {app_id, %Install{pinned_version: n}} <- installs, is_integer(n), do: {app_id, n}

    pinned =
      Enum.reduce(pins, %{}, fn {app_id, number}, acc ->
        case Repo.get_by(Version, app_id: app_id, number: number) do
          %Version{state: "ready"} = version -> Map.put(acc, app_id, version)
          _ -> acc
        end
      end)

    %{live: live, latest: latest, installs: installs, pinned: pinned, authors: authors}
  end

  @doc """
  The contract's app object as `workspace_id` sees it (nil for a link
  viewer, who sees no grants, secrets or repository).
  """
  def view(%App{} = app, ctx, workspace_id, opts \\ []) do
    live = ctx.live[app.id]
    latest = ctx.latest[app.id]
    # The Version the requester runs: the one asked for, else the Install's
    # pinned one, else live, else the latest.
    shown = Keyword.get(opts, :version) || ctx.pinned[app.id] || live || latest
    manifest = (shown && shown.manifest) || %{}
    install = ctx.installs[app.id]
    owner? = workspace_id == app.workspace_id

    grants =
      cond do
        owner? -> app.grants
        install -> install.grants
        true -> []
      end

    %{
      "id" => app.id,
      "slug" => app.slug,
      "workspace_id" => app.workspace_id,
      "name" => app.name,
      "description" => app.description || "",
      "icon_url" =>
        if(shown && is_binary(manifest["icon"]),
          do: "/v1/comma/apps/#{app.id}/icon?v=#{shown.number}"
        ),
      "cover_url" =>
        if(shown && is_binary(manifest["cover"]),
          do: "/v1/comma/apps/#{app.id}/cover?v=#{shown.number}"
        ),
      "repo" => %{"owner" => app.repo_owner, "name" => app.repo_name},
      "visibility" => app.visibility,
      "status" => app.status,
      "live_version" => live && live.number,
      "latest_version" => latest && latest.number,
      "author" => %{"name" => ctx.authors[app.created_by] || "Comma user"},
      "capabilities" => manifest["capabilities"] || [],
      "egress" => get_in(manifest, ["backend", "egress"]) || [],
      "storage" => manifest["storage"] || [],
      "has_backend" => (shown && is_binary(shown.script_name)) || false,
      "secrets" => if(owner?, do: app.secrets |> Map.keys() |> Enum.sort(), else: []),
      "grants" => grants,
      "installed" => not is_nil(install),
      "install" => install && %{"pinned_version" => install.pinned_version},
      "created_at" => iso(app.inserted_at),
      "updated_at" => iso(app.updated_at)
    }
    |> then(fn view ->
      if Keyword.get(opts, :public, false),
        do: Map.drop(view, ["repo", "secrets"]),
        else: view
    end)
  end

  @doc "One app's view for `workspace_id`."
  def view_one(%App{} = app, workspace_id, opts \\ []),
    do: view(app, view_context([app], workspace_id), workspace_id, opts)

  ## Owner changes

  def update(user, session, workspace_id, app_id, params) do
    with {:ok, workspace, app} <- owner_app(user, session, workspace_id, app_id),
         {:ok, changes} <- update_changes(app, params) do
      Repo.transaction(fn ->
        app = app |> Ecto.Changeset.change(changes) |> Repo.update!()
        if changes[:visibility] && changes[:visibility] != "link", do: revoke_links(app)
        view_one(app, workspace.id)
      end)
    end
  end

  defp update_changes(app, params) do
    Enum.reduce_while(["name", "description", "visibility"], {:ok, %{}}, fn key, {:ok, acc} ->
      case {key, Map.fetch(params, key)} do
        {_key, :error} ->
          {:cont, {:ok, acc}}

        {"name", {:ok, value}} ->
          case name(value) do
            {:ok, name} -> {:cont, {:ok, Map.put(acc, :name, name)}}
            error -> {:halt, error}
          end

        {"description", {:ok, value}} ->
          case description(value) do
            {:ok, text} -> {:cont, {:ok, Map.put(acc, :description, text || "")}}
            error -> {:halt, error}
          end

        {"visibility", {:ok, value}} when value in @visibilities ->
          if value == app.visibility,
            do: {:cont, {:ok, acc}},
            else: {:cont, {:ok, Map.put(acc, :visibility, value)}}

        {"visibility", _} ->
          {:halt, {:error, {:bad_request, "visibility is private, workspace or link"}}}
      end
    end)
  end

  @doc "Marks an app deleted and removes its sharing now; the cleanup worker removes the rest."
  def delete(user, session, workspace_id, app_id) do
    with {:ok, _workspace, app} <- owner_app(user, session, workspace_id, app_id) do
      mark_deleted(app)
    end
  end

  @doc false
  def mark_deleted(%App{} = app) do
    Repo.transaction(fn ->
      revoke_links(app)
      Repo.delete_all(from(i in Install, where: i.app_id == ^app.id))

      app
      |> Ecto.Changeset.change(status: "deleted", live_version_id: nil)
      |> Repo.update!()

      Oban.insert!(Comma.Oban, Comma.Workers.MiniAppCleanup.new(%{"app_id" => app.id}))
      :ok
    end)
  end

  @doc """
  Deletes every app of a Workspace before the Workspace itself goes (mark
  and sweep). In one transaction the apps become `deleted`, their links are
  revoked and their Installs (and the Workspace's own Installs) removed;
  `Comma.Workers.MiniAppCleanup` then deletes their scripts, objects and rows.
  `comma_mini_apps.workspace_id` restricts deletion, so the Workspace row can
  go only once the sweep removed its apps.
  """
  def delete_workspace_apps(workspace_id) when is_binary(workspace_id) do
    Repo.transaction(fn ->
      now = SystemsClock.utc_now()
      ids = from(a in App, where: a.workspace_id == ^workspace_id, select: a.id)

      from(l in Link, where: l.app_id in subquery(ids) and is_nil(l.revoked_at))
      |> Repo.update_all(set: [revoked_at: now, updated_at: now])

      Repo.delete_all(
        from(i in Install, where: i.app_id in subquery(ids) or i.workspace_id == ^workspace_id)
      )

      {count, _} =
        from(a in App, where: a.workspace_id == ^workspace_id and a.status != "deleted")
        |> Repo.update_all(set: [status: "deleted", live_version_id: nil, updated_at: now])

      if count > 0, do: Oban.insert!(Comma.Oban, Comma.Workers.MiniAppCleanup.new(%{}))
      count
    end)
  end

  @doc "Owner disable: the app stops for every viewer; nothing is deleted."
  def disable(user, session, workspace_id, app_id) do
    with {:ok, workspace, app} <- owner_app(user, session, workspace_id, app_id) do
      app =
        if app.status == "active",
          do:
            app
            |> Ecto.Changeset.change(status: "disabled", disabled_by: "owner")
            |> Repo.update!(),
          else: app

      {:ok, view_one(app, workspace.id)}
    end
  end

  @doc "Owner enable; an app the platform took down stays disabled."
  def enable(user, session, workspace_id, app_id) do
    with {:ok, workspace, app} <- owner_app(user, session, workspace_id, app_id) do
      case app do
        %App{status: "disabled", disabled_by: "platform"} ->
          {:error, :forbidden}

        %App{status: "disabled"} ->
          app = app |> Ecto.Changeset.change(status: "active", disabled_by: nil) |> Repo.update!()
          {:ok, view_one(app, workspace.id)}

        app ->
          {:ok, view_one(app, workspace.id)}
      end
    end
  end

  @doc """
  Platform takedown (admin): the app stops at once and its Version scripts
  are deleted. Only `platform_enable/1` starts it again.
  """
  def platform_disable(app_id) do
    case get_app(app_id) do
      %App{} = app ->
        app =
          app
          |> Ecto.Changeset.change(status: "disabled", disabled_by: "platform")
          |> Repo.update!()

        for %Version{script_name: name} when is_binary(name) <-
              Repo.all(from(v in Version, where: v.app_id == ^app.id)) do
          Cloudflare.delete_script(name)
        end

        {:ok, admin_view(app)}

      nil ->
        {:error, :not_found}
    end
  end

  def platform_enable(app_id) do
    case get_app(app_id) do
      %App{status: "disabled"} = app ->
        app = app |> Ecto.Changeset.change(status: "active", disabled_by: nil) |> Repo.update!()

        case live_version(app) do
          %Version{script_name: name} = version when is_binary(name) -> sync_script(app, version)
          _ -> :ok
        end

        {:ok, admin_view(app)}

      %App{} = app ->
        {:ok, admin_view(app)}

      nil ->
        {:error, :not_found}
    end
  end

  defp admin_view(app),
    do: %{
      "id" => app.id,
      "workspace_id" => app.workspace_id,
      "name" => app.name,
      "status" => app.status,
      "disabled_by" => app.disabled_by
    }

  @doc "Moves the live pointer to Version `number` (ready)."
  def rollback(user, session, workspace_id, app_id, number) do
    with {:ok, workspace, app} <- owner_app(user, session, workspace_id, app_id),
         {:ok, number} <- positive(number),
         %Version{state: "ready"} = version <-
           Repo.get_by(Version, app_id: app.id, number: number) do
      set_live(app, version, nil, workspace.id)
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The app's ready Version `number` with the commit it was built from (Publish moves live to it):
  `{:error, :not_found}` for one that is not.
  """
  def ready_version(%App{} = app, number) when is_integer(number) do
    case Repo.get_by(Version, app_id: app.id, number: number, state: "ready") do
      %Version{commit: commit} = version when is_binary(commit) -> {:ok, version}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The ready Version built from `commit`, or `{:error, :deploy_latest_first}`
  when the pull request head has none.
  """
  def version_for_commit(%App{} = app, commit) when is_binary(commit) do
    from(v in Version,
      where: v.app_id == ^app.id and v.commit == ^commit and v.state == "ready",
      order_by: [desc: v.number],
      limit: 1
    )
    |> Repo.one()
    |> case do
      %Version{} = version -> {:ok, version}
      nil -> {:error, :deploy_latest_first}
    end
  end

  def version_for_commit(_app, _commit), do: {:error, :deploy_latest_first}

  @doc "Makes `version` live (and sets `visibility` when given)."
  def set_live(%App{} = app, %Version{} = version, visibility, workspace_id) do
    changes =
      if visibility in @visibilities,
        do: %{live_version_id: version.id, visibility: visibility},
        else: %{live_version_id: version.id}

    with :ok <- if(is_binary(version.script_name), do: sync_script(app, version), else: :ok) do
      app = app |> Ecto.Changeset.change(changes) |> Repo.update!()
      if changes[:visibility] && changes[:visibility] != "link", do: revoke_links(app)
      {:ok, view_one(app, workspace_id)}
    end
  end

  ## Grants and secrets

  @doc "Sets the requesting Workspace's grants (owner: on the app; else on its Install)."
  def put_grants(user, session, workspace_id, app_id, grants) do
    with {:ok, workspace, _role} <- member(user, session, workspace_id, :write),
         {:ok, app, kind} <- workspace_app(workspace, user, app_id),
         {:ok, grants} <- grant_list(grants) do
      case kind do
        :owner ->
          app = app |> Ecto.Changeset.change(grants: grants) |> Repo.update!()
          {:ok, view_one(app, workspace.id)}

        :install ->
          from(i in Install, where: i.app_id == ^app.id and i.workspace_id == ^workspace.id)
          |> Repo.update_all(set: [grants: grants, updated_at: SystemsClock.utc_now()])

          {:ok, view_one(app, workspace.id)}
      end
    end
  end

  defp grant_list(grants) when is_list(grants) do
    if Enum.all?(grants, &(&1 in Manifest.capabilities())),
      do: {:ok, Enum.uniq(grants)},
      else: {:error, {:bad_request, "grants lists unknown capabilities"}}
  end

  defp grant_list(_grants), do: {:error, {:bad_request, "grants must be a list"}}

  def put_secret(user, session, workspace_id, app_id, name, value) do
    with {:ok, _workspace, app} <- owner_app(user, session, workspace_id, app_id),
         true <- Secrets.valid_name?(name) || {:error, {:bad_request, "invalid secret name"}},
         true <- Secrets.valid_value?(value) || {:error, {:bad_request, "invalid secret value"}},
         {:ok, sealed} <- Secrets.seal(app.id, name, value) do
      app =
        app
        |> Ecto.Changeset.change(secrets: Map.put(app.secrets, name, sealed))
        |> Repo.update!()

      resync_live(app)
      {:ok, %{"secrets" => app.secrets |> Map.keys() |> Enum.sort()}}
    end
  end

  def delete_secret(user, session, workspace_id, app_id, name) do
    with {:ok, _workspace, app} <- owner_app(user, session, workspace_id, app_id) do
      app =
        if Map.has_key?(app.secrets, name) do
          app =
            app |> Ecto.Changeset.change(secrets: Map.delete(app.secrets, name)) |> Repo.update!()

          resync_live(app)
          app
        else
          app
        end

      {:ok, %{"secrets" => app.secrets |> Map.keys() |> Enum.sort()}}
    end
  end

  # The live script gets the changed secrets now; another Version gets them
  # when it next goes live.
  defp resync_live(app) do
    case live_version(app) do
      %Version{script_name: name} = version when is_binary(name) ->
        case sync_script(app, version) do
          :ok -> :ok
          error -> Logger.warning("mini app secrets not applied: #{inspect(error)}")
        end

      _ ->
        :ok
    end
  end

  @doc "Uploads a Version's backend script again, with the app's current secrets."
  def sync_script(%App{} = app, %Version{} = version) do
    with {:ok, source} <- Blobs.get(Blobs.version_prefix(app.id, version.number) <> "worker.js"),
         {:ok, secrets} <- Secrets.unseal_all(app.id, app.secrets) do
      Cloudflare.upload_version(app, version.number, %{source: source, secrets: secrets})
    else
      {:error, :not_found} -> {:error, :backend_missing}
      error -> error
    end
  end

  ## Link

  def get_link(user, session, workspace_id, app_id) do
    with {:ok, _workspace, app} <- owner_app(user, session, workspace_id, app_id, :read) do
      {:ok, active_link(app.id)}
    end
  end

  @doc "Creates the app's link (and makes the app `link` visible), or returns the active one."
  def put_link(user, session, workspace_id, app_id) do
    with {:ok, _workspace, app} <- owner_app(user, session, workspace_id, app_id) do
      if app.visibility != "link",
        do: app |> Ecto.Changeset.change(visibility: "link") |> Repo.update!()

      case active_link(app.id) do
        %Link{} = link -> {:ok, link}
        nil -> insert_link(app, user)
      end
    end
  end

  @doc "Revokes the link and issues a new token. Installs made through the old one are removed."
  def reset_link(user, session, workspace_id, app_id) do
    with {:ok, _workspace, app} <- owner_app(user, session, workspace_id, app_id) do
      Repo.transaction(fn ->
        revoke_links(app)

        case insert_link(app, user) do
          {:ok, link} -> link
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def revoke_link(user, session, workspace_id, app_id) do
    with {:ok, _workspace, app} <- owner_app(user, session, workspace_id, app_id) do
      Repo.transaction(fn -> revoke_links(app) end)
      :ok
    end
  end

  # Revocation removes every Install: Installs are the link's sharing.
  defp revoke_links(app) do
    now = SystemsClock.utc_now()

    from(l in Link, where: l.app_id == ^app.id and is_nil(l.revoked_at))
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    Repo.delete_all(from(i in Install, where: i.app_id == ^app.id))
  end

  defp active_link(app_id),
    do: Repo.one(from(l in Link, where: l.app_id == ^app_id and is_nil(l.revoked_at)))

  defp insert_link(app, user) do
    now = SystemsClock.utc_now()

    %Link{
      id: SystemsRuntime.Proc.uuid(),
      app_id: app.id,
      token:
        @token_bytes |> SystemsRuntime.Proc.random_bytes() |> Base.url_encode64(padding: false),
      created_by: user["id"],
      inserted_at: now,
      updated_at: now
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:app_id, name: :comma_mini_app_links_active_app_index)
    |> Repo.insert()
    |> case do
      {:ok, link} ->
        {:ok, link}

      {:error, _} ->
        case active_link(app.id) do
          %Link{} = link -> {:ok, link}
          nil -> {:error, :temporarily_unavailable}
        end
    end
  end

  @doc "The JSON view of a link."
  def link_view(%Link{} = link),
    do: %{
      "token" => link.token,
      "url" => Config.get(:link_base_url) <> link.token,
      "created_at" => iso(link.inserted_at)
    }

  def valid_token?(token), do: is_binary(token) and Regex.match?(@token_pattern, token)

  @doc "The active, shared app of a link token: `{:ok, app}` or `{:error, :not_found}`."
  def resolve_link(token) do
    with true <- valid_token?(token),
         %Link{app_id: app_id} <-
           Repo.one(from(l in Link, where: l.token == ^token and is_nil(l.revoked_at))),
         %App{status: "active", visibility: "link"} = app <- get_app(app_id) do
      {:ok, app}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "A link's app (no repository, no secrets) and its live Version number."
  def link_summary(token) do
    with {:ok, app} <- resolve_link(token),
         %Version{} = live <- live_version(app) do
      {:ok, %{"app" => view_one(app, nil, public: true), "version" => live.number}}
    else
      {:error, _} = error -> error
      nil -> {:error, :not_found}
    end
  end

  ## Installs

  @doc "Adds a shared app to the member's Workspace through its link."
  def install(user, session, workspace_id, token, pinned) do
    with {:ok, workspace, _role} <- member(user, session, workspace_id, :write),
         {:ok, app} <- resolve_link(token),
         false <- app.workspace_id == workspace.id,
         {:ok, pinned} <- pinned_version(app, pinned) do
      now = SystemsClock.utc_now()

      Repo.insert!(
        %Install{
          id: SystemsRuntime.Proc.uuid(),
          app_id: app.id,
          workspace_id: workspace.id,
          installed_by: user["id"],
          pinned_version: pinned,
          grants: [],
          inserted_at: now,
          updated_at: now
        },
        on_conflict: [set: [pinned_version: pinned, updated_at: now]],
        conflict_target: [:app_id, :workspace_id]
      )

      {:ok, view_one(app, workspace.id)}
    else
      true -> {:error, {:conflict, "the app belongs to this Workspace"}}
      {:error, _} = error -> error
    end
  end

  defp pinned_version(_app, nil), do: {:ok, nil}

  defp pinned_version(app, number) do
    with {:ok, number} <- positive(number),
         %Version{state: "ready"} <- Repo.get_by(Version, app_id: app.id, number: number) do
      {:ok, number}
    else
      _ -> {:error, :not_found}
    end
  end

  def uninstall(user, session, workspace_id, app_id) do
    with {:ok, workspace, _role} <- member(user, session, workspace_id, :write),
         {:ok, id} <- Ecto.UUID.cast(app_id) |> ok_or_not_found() do
      Repo.delete_all(
        from(i in Install, where: i.app_id == ^id and i.workspace_id == ^workspace.id)
      )

      :ok
    end
  end

  ## Bundles

  @doc "A Version's bundle for a Workspace that sees it: `{:ok, app, version}`."
  def workspace_bundle(user, session, workspace_id, app_id, number) do
    with {:ok, workspace, _role} <- member(user, session, workspace_id),
         {:ok, %App{status: "active"} = app, kind} <- workspace_app(workspace, user, app_id),
         {:ok, number} <- positive(number),
         %Version{state: "ready"} = version <-
           Repo.get_by(Version, app_id: app.id, number: number),
         true <- kind == :owner or bundle_installed?(app, workspace.id, version) do
      {:ok, app, version}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _ -> {:error, :not_found}
    end
  end

  defp bundle_installed?(app, workspace_id, version) do
    install = Repo.get_by(Install, app_id: app.id, workspace_id: workspace_id)

    install != nil and
      (version.id == app.live_version_id or version.number == install.pinned_version)
  end

  @doc "The live Version's bundle of a link."
  def link_bundle(token) do
    with {:ok, app} <- resolve_link(token),
         %Version{} = version <- live_version(app) do
      {:ok, app, version}
    else
      _ -> {:error, :not_found}
    end
  end

  def live_version(%App{live_version_id: nil}), do: nil

  def live_version(%App{live_version_id: id}) do
    case Repo.get(Version, id) do
      %Version{state: "ready"} = version -> version
      _ -> nil
    end
  end

  defp latest_ready(app) do
    Repo.one(
      from(v in Version,
        where: v.app_id == ^app.id and v.state == "ready",
        order_by: [desc: v.number],
        limit: 1
      )
    )
  end

  ## Runtime access

  @doc """
  Resolves a runtime call: the app, the Version it runs and how the viewer
  reaches it. `via` is the `x-comma-app-via` header (`workspace/<id>` or
  `link/<token>`); `requested` is a Version number an owner Workspace member
  may ask for (a preview). Guests reach apps only by link. A disabled app is
  `not_found`.
  """
  def runtime(user, session, app_id, via, requested \\ nil) do
    with {:ok, access} <- parse_via(via),
         :ok <- guest_via(user, access),
         {:ok, app, kind, workspace, install} <- runtime_access(user, session, app_id, access),
         %Version{} = version <- runtime_version(app, kind, install, requested) do
      {:ok,
       %{
         app: app,
         version: version,
         kind: kind,
         workspace: workspace,
         install: install,
         guest: Comma.GuestMode.guest?(user)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  defp parse_via("workspace/" <> id) when id != "", do: {:ok, {:workspace, id}}
  defp parse_via("link/" <> token) when token != "", do: {:ok, {:link, token}}
  defp parse_via(_via), do: {:error, :not_found}

  defp guest_via(user, {:workspace, _id}) do
    if Comma.GuestMode.guest?(user), do: {:error, :signup_required}, else: :ok
  end

  defp guest_via(_user, _access), do: :ok

  defp runtime_access(user, session, app_id, {:workspace, workspace_id}) do
    with {:ok, workspace, _role} <- member(user, session, workspace_id),
         {:ok, %App{status: "active"} = app, kind} <- workspace_app(workspace, user, app_id) do
      install =
        if kind == :install, do: Repo.get_by(Install, app_id: app.id, workspace_id: workspace.id)

      {:ok, app, kind, workspace, install}
    else
      _ -> {:error, :not_found}
    end
  end

  defp runtime_access(_user, _session, app_id, {:link, token}) do
    case resolve_link(token) do
      {:ok, %App{id: ^app_id} = app} -> {:ok, app, :link, nil, nil}
      _ -> {:error, :not_found}
    end
  end

  defp runtime_version(app, :owner, _install, requested) when is_integer(requested) do
    case Repo.get_by(Version, app_id: app.id, number: requested) do
      %Version{state: "ready"} = version -> version
      _ -> nil
    end
  end

  defp runtime_version(app, :owner, _install, _requested),
    do: live_version(app) || latest_ready(app)

  defp runtime_version(app, :install, %Install{pinned_version: pinned}, _requested)
       when is_integer(pinned) do
    case Repo.get_by(Version, app_id: app.id, number: pinned) do
      %Version{state: "ready"} = version -> version
      _ -> live_version(app)
    end
  end

  defp runtime_version(app, _kind, _install, _requested), do: live_version(app)

  @doc "The owner Workspace's billing availability: `:ok` or `{:error, :app_paused}`."
  def owner_available(%App{} = app, kind) do
    case Repo.get(Workspace, app.workspace_id) do
      %Workspace{billing_owner_id: account} -> Billing.owner_available(account, kind)
      nil -> {:error, :not_found}
    end
  end

  @doc "`POST /v1/comma/apps/:id/open`: the app, its Version and the viewer."
  def open(user, session, app_id, via, requested \\ nil) do
    with {:ok, rt} <- runtime(user, session, app_id, via, requested),
         :ok <- owner_available(rt.app, "open"),
         {:ok, viewer_id} <- Viewer.id(user["id"], rt.app.id) do
      workspace_id = rt.workspace && rt.workspace.id
      view = view_one(rt.app, workspace_id, public: rt.kind != :owner, version: rt.version)

      {:ok,
       %{
         "app" => view,
         "version" => rt.version.number,
         "digest" => rt.version.digest,
         "viewer" => %{
           "id" => viewer_id,
           "name" => if(rt.guest, do: "Guest", else: user["name"] || "Comma user"),
           "avatar_url" =>
             if(not rt.guest and is_binary(user["avatar_id"]),
               do: "/v1/comma/me/avatar/" <> user["avatar_id"]
             )
         },
         "guest" => rt.guest
       }}
    end
  end

  @doc "The icon of Version `number` (a ready Version the viewer reaches)."
  def icon(user, session, app_id, via, number),
    do: version_image(user, session, app_id, via, number, "icon")

  @doc "The cover of Version `number` (a ready Version the viewer reaches)."
  def cover(user, session, app_id, via, number),
    do: version_image(user, session, app_id, via, number, "cover")

  defp version_image(user, session, app_id, via, number, field) do
    {key, type} =
      case field do
        "icon" -> {&Blobs.icon_key/2, &Manifest.icon_type/1}
        "cover" -> {&Blobs.cover_key/2, &Manifest.cover_type/1}
      end

    with {:ok, rt} <- runtime(user, session, app_id, via),
         {:ok, number} <- positive(number),
         true <- number == rt.version.number or rt.kind == :owner,
         %Version{state: "ready", manifest: %{^field => path}} <-
           Repo.get_by(Version, app_id: rt.app.id, number: number),
         {:ok, body} <- Blobs.get(key.(rt.app.id, number)) do
      {:ok, body, type.(path) || "application/octet-stream"}
    else
      {:error, :signup_required} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "The storage scope a runtime call names, if the Version's manifest declares it."
  def storage_scope(rt, scope, user) when scope in ["app", "user"] do
    if scope in (rt.version.manifest["storage"] || []) do
      case scope do
        "app" ->
          {:ok, :app}

        "user" ->
          with {:ok, viewer} <- Viewer.id(user["id"], rt.app.id), do: {:ok, {:user, viewer}}
      end
    else
      {:error, :not_granted}
    end
  end

  def storage_scope(_rt, _scope, _user), do: {:error, :not_found}

  ## Report

  @doc """
  A viewer reports an app. No abuse queue exists in Comma: the report is a
  structured warning log (operators alert on `mini_app_report`) and a
  telemetry count.
  """
  def report(user, session, workspace_id, app_id, reason) do
    reason = if is_binary(reason), do: String.slice(String.trim(reason), 0, 2_000), else: ""

    with {:ok, workspace, _role} <- member(user, session, workspace_id),
         app <- get_app(app_id),
         true <-
           (app && (app.workspace_id == workspace.id or reportable?(app, workspace))) ||
             {:error, :not_found} do
      Logger.warning(
        "mini_app_report app_id=#{app.id} workspace_id=#{app.workspace_id} " <>
          "reporter_user_id=#{user["id"]} reason=#{inspect(reason)}"
      )

      SystemsRuntime.Telemetry.execute([:comma_product, :mini_app, :report], %{count: 1}, %{})
      :ok
    end
  end

  defp reportable?(app, workspace),
    do:
      app.visibility == "link" or
        Repo.get_by(Install, app_id: app.id, workspace_id: workspace.id) != nil

  ## Version retention and cleanup

  @doc """
  One bounded cleanup pass of one app: a deleted app loses its scripts, its
  objects and finally its rows; a live app loses Versions beyond retention and
  the objects of failed Versions older than 7 days. `:done` or `:more`.
  """
  def cleanup(app_id) do
    case Repo.get(App, app_id) do
      nil -> :done
      %App{status: "deleted"} = app -> cleanup_deleted(app)
      %App{} = app -> cleanup_versions(app)
    end
  end

  defp cleanup_deleted(app) do
    versions = Repo.all(from(v in Version, where: v.app_id == ^app.id))

    scripts =
      for(%Version{script_name: name} when is_binary(name) <- versions, do: name) ++
        if(app.data_script, do: [Cloudflare.data_script(app.slug)], else: [])

    with :ok <- delete_scripts(scripts),
         :done <- Blobs.delete_page(Blobs.app_prefix(app.id)) do
      Repo.delete!(app)
      :done
    end
  end

  defp delete_scripts(names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case Cloudflare.delete_script(name) do
        :ok -> {:cont, :ok}
        {:error, :backend_unavailable} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp cleanup_versions(app) do
    pinned =
      from(i in Install,
        where: i.app_id == ^app.id and not is_nil(i.pinned_version),
        select: i.pinned_version
      )
      |> Repo.all()

    recent =
      from(v in Version,
        where: v.app_id == ^app.id,
        order_by: [desc: v.number],
        limit: @keep_versions,
        select: v.number
      )
      |> Repo.all()

    keep = MapSet.new(pinned ++ recent)

    old =
      from(v in Version,
        where: v.app_id == ^app.id and v.state != "uploading",
        order_by: [asc: v.number],
        limit: 100
      )
      |> Repo.all()
      |> Enum.reject(&(MapSet.member?(keep, &1.number) or &1.id == app.live_version_id))

    Enum.each(old, &delete_version(app, &1))

    cutoff = DateTime.add(SystemsClock.utc_now(), -7, :day)

    from(v in Version,
      where:
        v.app_id == ^app.id and v.state == "failed" and is_nil(v.blobs_deleted_at) and
          v.failed_at < ^cutoff,
      limit: 100
    )
    |> Repo.all()
    |> Enum.each(fn version ->
      if Blobs.delete_page(Blobs.version_prefix(app.id, version.number)) == :done do
        version
        |> Ecto.Changeset.change(blobs_deleted_at: SystemsClock.utc_now())
        |> Repo.update!()
      end
    end)

    :done
  end

  defp delete_version(app, version) do
    with :ok <- delete_scripts(List.wrap(version.script_name)),
         :done <- Blobs.delete_page(Blobs.version_prefix(app.id, version.number)) do
      Repo.delete(version)
    end
  end

  @doc "App IDs that need a cleanup pass: deleted apps and apps with old Versions."
  def cleanup_candidates(limit) do
    cutoff = DateTime.add(SystemsClock.utc_now(), -7, :day)

    deleted =
      from(a in App, where: a.status == "deleted", select: a.id, limit: ^limit) |> Repo.all()

    crowded =
      from(v in Version,
        group_by: v.app_id,
        having: count(v.id) > @keep_versions,
        select: v.app_id,
        limit: ^limit
      )
      |> Repo.all()

    failed =
      from(v in Version,
        where: v.state == "failed" and is_nil(v.blobs_deleted_at) and v.failed_at < ^cutoff,
        distinct: true,
        select: v.app_id,
        limit: ^limit
      )
      |> Repo.all()

    Enum.uniq(deleted ++ crowded ++ failed)
  end

  ## Helpers

  defp name(name) when is_binary(name) do
    name = String.trim(name)

    if String.length(name) in 1..60,
      do: {:ok, name},
      else: {:error, {:bad_request, "name must be 1 to 60 characters"}}
  end

  defp name(_name), do: {:error, {:bad_request, "name is required"}}

  defp description(nil), do: {:ok, nil}

  defp description(text) when is_binary(text) do
    if String.length(text) <= 500,
      do: {:ok, String.trim(text)},
      else: {:error, {:bad_request, "description must be at most 500 characters"}}
  end

  defp description(_text), do: {:error, {:bad_request, "description must be a string"}}

  @doc false
  def positive(n) when is_integer(n) and n > 0, do: {:ok, n}

  def positive(n) when is_binary(n) do
    case Integer.parse(n) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :not_found}
    end
  end

  def positive(_n), do: {:error, :not_found}

  defp ok_or_not_found({:ok, value}), do: {:ok, value}
  defp ok_or_not_found(_), do: {:error, :not_found}

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_at), do: nil
end
