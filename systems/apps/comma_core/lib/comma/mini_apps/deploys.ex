defmodule Comma.MiniApps.Deploys do
  @moduledoc """
  Steps 2–6 of a deploy (design §5.4) for `task.app_deploy`. Salix checked the
  sandbox's connection authority and the Task's `mini_app` first (step 1),
  and appends the `mini_app` Message after (step 7).

    2. `commit_check` proves the commit is on the pushed session branch;
    3. paid-work admission of the owner Workspace;
    4. the manifest and files pass `Comma.MiniApps.Manifest` / `Bundle`;
    5. the bundle, source archive, backend module, icon and cover become objects, and
       the Version row is `uploading`;
    6. a backend becomes script `app-<slug>-v<n>` (with the app's storage
       script uploaded once before);
    7. the Version is `ready`.

  A repeated `key` returns the same Version: a ready one as it is, a failed
  one with its failure, an `uploading` one (a deploy cut short) continues
  under its own number. A failure after step 5 marks the Version `failed`;
  its objects stay 7 days.
  """

  import Ecto.Query
  require Logger

  alias Comma.Data.Workspace

  alias Comma.MiniApps.{
    App,
    Billing,
    Blobs,
    Bundle,
    Cloudflare,
    Cover,
    Manifest,
    Secrets,
    Version
  }

  alias Comma.Repo

  @key ~r/\A[A-Za-z0-9_-]{1,128}\z/
  @commit ~r/\A[0-9a-f]{40}\z/

  @doc """
  Deploys. `ctx` is the port's context (`app_id`, `group_id`, `key`,
  `commit`, `notes`, `conversation_id`, `repo`); `files` holds local paths
  (`bundle`, `source`, optional `worker`) and the manifest JSON;
  `commit_check` is `fn app -> :ok | {:error, reason} end`.
  """
  def deploy(ctx, files, commit_check) when is_function(commit_check, 1) do
    with :ok <- valid_input(ctx),
         {:ok, app} <- authorized_app(ctx) do
      case Repo.get_by(Version, app_id: app.id, deploy_key: ctx.key) do
        %Version{state: "ready"} = version ->
          {:ok, result(version)}

        %Version{state: "failed", error: error} ->
          {:error, failed_reason(error)}

        %Version{state: "uploading"} = version ->
          with {:ok, checked} <- check(app, ctx, files, commit_check) do
            store_and_publish(app, version, checked, files)
          end

        nil ->
          with {:ok, checked} <- check(app, ctx, files, commit_check),
               {:ok, version} <- new_version(app, ctx, checked) do
            store_and_publish(app, version, checked, files)
          end
      end
    end
  end

  defp valid_input(ctx) do
    cond do
      not (is_binary(ctx[:key]) and Regex.match?(@key, ctx.key)) ->
        {:error, {:invalid, ["key must be 1 to 128 URL-safe characters"]}}

      not (is_binary(ctx[:commit]) and Regex.match?(@commit, ctx.commit)) ->
        {:error, {:invalid, ["commit must be a full 40-character SHA"]}}

      true ->
        :ok
    end
  end

  # The Task's Group owns the app, and the Task's repository is the app's.
  defp authorized_app(ctx) do
    with %App{status: "active", group_id: group} = app when group == ctx.group_id <-
           Comma.MiniApps.get_app(ctx.app_id),
         true <- same_repo?(app, ctx[:repo]) do
      {:ok, app}
    else
      %App{status: "disabled"} -> {:error, :app_disabled}
      false -> {:error, :repo_mismatch}
      _ -> {:error, :not_found}
    end
  end

  defp same_repo?(app, %{"owner" => owner, "name" => name})
       when is_binary(owner) and is_binary(name),
       do:
         String.downcase(owner) == String.downcase(app.repo_owner) and
           String.downcase(name) == String.downcase(app.repo_name)

  defp same_repo?(_app, _repo), do: false

  defp check(app, ctx, files, commit_check) do
    with :ok <- commit_check.(app),
         :ok <- admitted(app),
         {:ok, manifest} <- Manifest.parse(files[:manifest]),
         {:ok, bundle} <- Bundle.inspect_bundle(path(files[:bundle])),
         :ok <- Bundle.inspect_source(path(files[:source])),
         {:ok, worker} <- worker(manifest, files[:worker]),
         {:ok, icon} <- icon(manifest, bundle, path(files[:bundle])),
         {:ok, cover} <- cover(manifest, bundle, path(files[:bundle])) do
      {:ok,
       %{manifest: manifest, bundle: bundle, worker: worker, icon: icon, cover: cover, ctx: ctx}}
    else
      {:error, [_ | _] = errors} -> {:error, {:invalid, errors}}
      {:error, _} = error -> error
    end
  end

  defp admitted(app) do
    case Repo.get(Workspace, app.workspace_id) do
      %Workspace{billing_owner_id: account} -> Billing.deploy_admitted(account)
      nil -> {:error, :not_found}
    end
  end

  defp path(%{path: path}) when is_binary(path), do: path
  defp path(_file), do: nil

  defp worker(%{"backend" => _}, %{path: path}) when is_binary(path) do
    with {:ok, source} <- Bundle.inspect_backend(path), do: {:ok, source}
  end

  defp worker(%{"backend" => _}, _missing),
    do: {:error, ["the manifest names a backend but worker.js is missing"]}

  defp worker(_manifest, _file), do: {:ok, nil}

  defp icon(%{"icon" => icon}, bundle, path) do
    if Map.has_key?(bundle.files, icon) do
      case Bundle.read_file(path, icon) do
        {:ok, data} -> {:ok, data}
        {:error, :too_large} -> {:error, ["the icon is larger than 256 KiB"]}
        {:error, _} -> {:error, ["the icon could not be read"]}
      end
    else
      {:error, ["the icon #{icon} is not in the bundle"]}
    end
  end

  defp icon(_manifest, _bundle, _path), do: {:ok, nil}

  defp cover(%{"cover" => cover}, bundle, path) do
    # The bundle's table gives the size, so a large file is refused before it is read.
    with size when is_integer(size) <- bundle.files[cover] || {:error, :missing},
         true <- size <= Cover.max_bytes() || {:error, :too_large},
         {:ok, data} <- Bundle.read_file(path, cover, Cover.max_bytes()),
         :ok <- Cover.check(data, Manifest.cover_type(cover)) do
      {:ok, data}
    else
      {:error, :missing} ->
        {:error, ["the cover #{cover} is not in the bundle"]}

      {:error, :too_large} ->
        {:error, ["the cover is larger than 160 KiB; save it as WebP or JPEG"]}

      {:error, [_ | _]} = error ->
        error

      {:error, _} ->
        {:error, ["the cover could not be read"]}
    end
  end

  defp cover(_manifest, _bundle, _path), do: {:ok, nil}

  defp new_version(app, ctx, checked) do
    Repo.transaction(fn ->
      {1, [number]} =
        from(a in App, where: a.id == ^app.id, select: a.next_version - 1)
        |> Repo.update_all(inc: [next_version: 1])

      now = SystemsClock.utc_now()

      %Version{
        id: SystemsRuntime.Proc.uuid(),
        app_id: app.id,
        number: number,
        state: "uploading",
        deploy_key: ctx.key,
        commit: ctx.commit,
        digest: checked.bundle.digest,
        manifest: checked.manifest,
        bundle_size: checked.bundle.size,
        conversation_id: ctx[:conversation_id],
        notes: notes(ctx[:notes]),
        inserted_at: now,
        updated_at: now
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:app_id, :deploy_key],
        name: :comma_mini_app_versions_app_id_deploy_key_index
      )
      |> Repo.insert()
      |> case do
        {:ok, version} -> version
        {:error, _} -> Repo.rollback(:key_conflict)
      end
    end)
    |> case do
      {:ok, version} ->
        {:ok, version}

      # A concurrent deploy with the same key made the Version: continue on it.
      {:error, :key_conflict} ->
        case Repo.get_by(Version, app_id: app.id, deploy_key: ctx.key) do
          %Version{} = version -> {:ok, version}
          nil -> {:error, :temporarily_unavailable}
        end
    end
  end

  defp store_and_publish(app, version, checked, files) do
    number = version.number

    result =
      with :ok <-
             Blobs.put_file(
               Blobs.bundle_key(app.id, number),
               path(files[:bundle]),
               "application/x-tar"
             ),
           :ok <-
             Blobs.put_file(
               Blobs.source_key(app.id, number),
               path(files[:source]),
               "application/gzip"
             ),
           :ok <-
             maybe_put(Blobs.icon_key(app.id, number), checked.icon, "application/octet-stream"),
           :ok <-
             maybe_put(
               Blobs.cover_key(app.id, number),
               checked.cover,
               Manifest.cover_type(checked.manifest["cover"])
             ),
           :ok <-
             maybe_put(
               Blobs.version_prefix(app.id, number) <> "worker.js",
               checked.worker,
               "application/javascript"
             ),
           {:ok, script} <- upload_backend(app, number, checked.worker) do
        version
        |> Ecto.Changeset.change(
          state: "ready",
          script_name: script,
          digest: checked.bundle.digest,
          manifest: checked.manifest
        )
        |> Repo.update()
      end

    case result do
      {:ok, ready} ->
        {:ok, result(ready)}

      {:error, reason} ->
        Logger.warning(
          "mini app deploy failed: app=#{app.id} version=#{number} #{inspect(reason)}"
        )

        version
        |> Ecto.Changeset.change(
          state: "failed",
          error: failure_text(reason),
          failed_at: SystemsClock.utc_now()
        )
        |> Repo.update()

        {:error, reason}
    end
  end

  defp maybe_put(_key, nil, _type), do: :ok
  defp maybe_put(key, body, type), do: Blobs.put(key, body, type)

  defp upload_backend(_app, _number, nil), do: {:ok, nil}

  defp upload_backend(app, number, source) do
    app = Repo.get!(App, app.id)

    with :ok <- ensure_data_script(app),
         {:ok, secrets} <- Secrets.unseal_all(app.id, app.secrets),
         :ok <- Cloudflare.upload_version(app, number, %{source: source, secrets: secrets}) do
      {:ok, Cloudflare.version_script(app.slug, number)}
    end
  end

  defp ensure_data_script(%App{data_script: true}), do: :ok

  defp ensure_data_script(app) do
    with :ok <- Cloudflare.upload_data_script(app) do
      from(a in App, where: a.id == ^app.id) |> Repo.update_all(set: [data_script: true])
      :ok
    end
  end

  defp result(version) do
    name = version.manifest["name"] || "App"

    %{
      "app_id" => version.app_id,
      "version" => version.number,
      "state" => "ready",
      "name" => name,
      "summary" => "#{name} — preview version #{version.number}"
    }
  end

  defp notes(notes) when is_binary(notes), do: String.slice(notes, 0, 2_000)
  defp notes(_notes), do: nil

  defp failure_text({:cloudflare, status, message}), do: "cloudflare #{status}: #{message}"
  defp failure_text(reason), do: inspect(reason) |> String.slice(0, 500)

  defp failed_reason(text) when is_binary(text), do: {:deploy_failed, text}
  defp failed_reason(_text), do: {:deploy_failed, "the deploy failed"}
end
