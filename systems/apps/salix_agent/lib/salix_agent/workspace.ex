defmodule SalixAgent.Workspace do
  @moduledoc """
  Agent workspace public API.
  """

  alias SalixAgent.{AgentWorkspace, Control, RuntimeFiles, SkillProjection}
  alias SalixStore.Blob

  def list(agent_id, raw_path) do
    path = normalize_path(raw_path)

    with {:ok, vfs} <- AgentWorkspace.manifest(agent_id) do
      resolve_path(vfs, path)
    end
  end

  def open(agent_id, raw_path) do
    path = normalize_path(raw_path)

    with {:ok, vfs} <- AgentWorkspace.manifest(agent_id) do
      case resolve_path(vfs, path) do
        {:file, file} ->
          with {:ok, stream, size} <- Blob.stream(agent_id, Map.fetch!(vfs, path)["ref"]) do
            {:file, file, stream, size}
          end

        result ->
          result
      end
    end
  end

  def read(agent_id, raw_path) do
    path = normalize_path(raw_path)
    AgentWorkspace.read(agent_id, path)
  end

  def stream(agent_id, raw_path) do
    path = normalize_path(raw_path)
    AgentWorkspace.stream(agent_id, path)
  end

  def write(agent_id, raw_path, body, opts \\ []) when is_binary(body) and is_list(opts) do
    path = normalize_path(raw_path)

    with {:ok, _agent} <- Control.get(agent_id),
         :ok <- validate_mutable_path(path),
         {:ok, opts} <-
           authorize_storage_write(
             agent_id,
             [%{"type" => "vfs_write", "path" => path}],
             opts,
             "storage_write"
           ),
         {:ok, event} <- AgentWorkspace.prepare_write(agent_id, path, body),
         file = file_json(path, event),
         {:ok, result} <-
           SalixAgent.AgentActor.commit_workspace_operation(
             agent_id,
             operation_id("vfs:put", agent_id, path, opts, [event["hash"], event["size"]]),
             file,
             [event],
             storage_auth_opts(opts, "storage_write")
           ) do
      {:ok, result}
    end
  end

  @doc """
  Map `path` to an already-stored blob `ref` in the manifest. The bytes are
  uploaded out-of-band (e.g. a backpressured streaming download straight into S3
  multipart), so nothing is buffered here.
  """
  def put_ref(agent_id, raw_path, ref, opts \\ []) do
    path = normalize_path(raw_path)
    ref = normalize_blob_ref(ref)

    with {:ok, _agent} <- Control.get(agent_id),
         :ok <- validate_mutable_path(path),
         {:ok, event} <- AgentWorkspace.prepare_write_ref(path, ref),
         file = file_json(path, event),
         {:ok, opts} <- authorize_storage_write(agent_id, [event], opts, "storage_write"),
         {:ok, result} <-
           SalixAgent.AgentActor.commit_workspace_operation(
             agent_id,
             operation_id("vfs:put_ref", agent_id, path, opts, [event["hash"], event["size"]]),
             file,
             [event],
             storage_auth_opts(opts, "storage_write")
           ) do
      {:ok, result}
    end
  end

  def delete(agent_id, raw_path, opts \\ []) do
    path = normalize_path(raw_path)
    recursive? = Keyword.get(opts, :recursive, false)
    prefix = operation_prefix("vfs:delete", agent_id, path, opts)

    with {:ok, _agent} <- Control.get(agent_id),
         :ok <- validate_mutable_path(path),
         {:ok, vfs} <- AgentWorkspace.manifest(agent_id),
         {:ok, targets} <- vfs_delete_targets(vfs, path, recursive?),
         events = Enum.map(targets, &AgentWorkspace.prepare_delete/1),
         {:ok, opts} <- authorize_storage_write(agent_id, events, opts, "storage_delete") do
      target_fingerprint = delete_target_fingerprint(vfs, targets)
      result = %{"path" => path, "deleted" => length(targets)}

      with {:ok, committed_result} <-
             SalixAgent.AgentActor.commit_workspace_operation(
               agent_id,
               operation_id("vfs:delete", agent_id, path, opts, [target_fingerprint]),
               result,
               events,
               storage_auth_opts(opts, "storage_delete")
             ) do
        {:ok, committed_result}
      end
    else
      {:error, :not_found} ->
        if present?(Keyword.get(opts, :idempotency_key, "")) do
          case AgentWorkspace.latest_operation_result_by_prefix(agent_id, prefix) do
            {:ok, result} -> {:ok, result}
            {:error, :not_found} -> {:error, :not_found}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :not_found}
        end

      {:error, _} = err ->
        err
    end
  end

  def list_sites(agent_or_id) do
    with {:ok, %{"agent_id" => agent_id}} <- resolve_visible_agent(agent_or_id),
         {:ok, vfs} <- AgentWorkspace.manifest(agent_id) do
      {:ok, site_entries(agent_id, vfs)}
    end
  end

  def list_hosted_sites(tenant_id, opts \\ []) do
    with {:ok, limit} <- hosted_sites_limit(Keyword.get(opts, :limit)),
         {:ok, offset} <- hosted_sites_offset(Keyword.get(opts, :offset)) do
      result =
        tenant_id
        |> Control.list()
        |> Enum.reduce_while({[], 0}, fn agent, {acc, seen} ->
          case list_sites(agent) do
            {:ok, agent_sites} ->
              {acc, seen} =
                Enum.reduce_while(agent_sites, {acc, seen}, fn site, {acc, seen} ->
                  cond do
                    seen < offset ->
                      {:cont, {acc, seen + 1}}

                    length(acc) == limit + 1 ->
                      {:halt, {acc, seen}}

                    true ->
                      hosted_site =
                        site
                        |> Map.take(["name", "url"])
                        |> Map.put("agent_id", agent["agent_id"])

                      {:cont, {acc ++ [hosted_site], seen + 1}}
                  end
                end)

              if length(acc) == limit + 1, do: {:halt, {acc, seen}}, else: {:cont, {acc, seen}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case result do
        {:error, reason} ->
          {:error, reason}

        {sites, _seen} ->
          has_more = length(sites) > limit
          page_sites = if has_more, do: Enum.take(sites, limit), else: sites

          {:ok,
           %{
             "sites" => page_sites,
             "limit" => limit,
             "offset" => offset,
             "has_more" => has_more
           }}
      end
    end
  end

  defp file_entries(vfs, path) do
    prefix = dir_prefix(path)
    now = now()

    vfs
    |> Enum.filter(fn {file_path, _meta} -> String.starts_with?(file_path, prefix) end)
    |> Enum.map(fn {file_path, meta} -> file_entry(file_path, meta, prefix, now) end)
    |> Enum.uniq_by(& &1["path"])
    |> Enum.sort_by(&{&1["kind"], &1["path"]})
  end

  defp resolve_path(vfs, path) do
    if Map.has_key?(vfs, path) do
      {:file, file_json(path, Map.fetch!(vfs, path))}
    else
      entries = file_entries(vfs, path)

      if path == "/" or entries != [] do
        {:ok, entries}
      else
        {:error, :not_found}
      end
    end
  end

  defp resolve_visible_agent(%{"agent_id" => agent_id} = agent) when is_binary(agent_id) do
    if Control.visible?(agent), do: {:ok, agent}, else: {:error, :not_found}
  end

  defp resolve_visible_agent(%{}), do: {:error, :not_found}

  defp resolve_visible_agent(agent_id) when is_binary(agent_id) do
    with {:ok, agent} <- Control.get(agent_id),
         true <- Control.visible?(agent) do
      {:ok, agent}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp file_entry(file_path, meta, prefix, now) do
    rest = String.replace_prefix(file_path, prefix, "")

    case String.split(rest, "/", parts: 2) do
      [name] ->
        %{
          "path" => prefix <> name,
          "kind" => "file",
          "size" => meta["size"] || 0,
          "modified_at" => now
        }

      [dir, _] ->
        %{
          "path" => prefix <> dir <> "/",
          "kind" => "dir",
          "size" => 0,
          "modified_at" => now
        }
    end
  end

  defp site_entries(agent_id, vfs) do
    root = "/.salix/websites"

    sites =
      vfs
      |> Map.keys()
      |> Enum.flat_map(&site_name_from_path(&1, root))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.filter(&valid_site_name?/1)
      |> Enum.filter(&site_has_entrypoint?(vfs, root, &1))
      |> Enum.map(&%{"name" => &1})

    Enum.map(sites, &Map.put(&1, "url", site_url(agent_id, &1["name"])))
  end

  defp site_url(agent_id, site_name) do
    SalixAgent.SiteId.site_url(agent_id, site_name) ||
      "/site/" <> URI.encode(agent_id) <> "/" <> URI.encode(site_name) <> "/"
  end

  defp site_name_from_path(path, root) do
    prefix = root <> "/"

    if String.starts_with?(path, prefix) do
      path
      |> String.replace_prefix(prefix, "")
      |> String.split("/", parts: 2)
      |> case do
        [name, _rest] when name != "" -> [name]
        _ -> []
      end
    else
      []
    end
  end

  defp site_has_entrypoint?(vfs, root, name) do
    Map.has_key?(vfs, root <> "/" <> name <> "/index.html") or
      Map.has_key?(vfs, root <> "/" <> name <> "/preview/index.html")
  end

  defp valid_site_name?(name) do
    byte_size(name) <= 63 and SalixAgent.SiteId.valid_site_name?(name)
  end

  defp vfs_delete_targets(_vfs, "/", _recursive?), do: {:error, :bad_path}

  defp vfs_delete_targets(vfs, path, recursive?) do
    cond do
      Map.has_key?(vfs, path) ->
        {:ok, [path]}

      recursive? ->
        targets =
          vfs
          |> Map.keys()
          |> Enum.filter(&String.starts_with?(&1, dir_prefix(path)))
          |> Enum.sort()

        if targets == [], do: {:error, :not_found}, else: {:ok, targets}

      has_vfs_children?(vfs, path) ->
        {:error, :directory_not_empty}

      true ->
        {:error, :not_found}
    end
  end

  defp has_vfs_children?(vfs, path) do
    prefix = dir_prefix(path)
    Enum.any?(Map.keys(vfs), &String.starts_with?(&1, prefix))
  end

  defp file_json(path, meta) do
    %{
      "path" => path,
      "kind" => "file",
      "size" => meta["size"] || 0,
      "modified_at" => now()
    }
  end

  defp dir_prefix("/"), do: "/"

  defp dir_prefix(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"

  defp normalize_path(path),
    do: if(String.starts_with?(path, "/"), do: path, else: "/" <> path)

  defp normalize_blob_ref(ref) do
    %{
      kind: ref[:kind] || ref["kind"],
      uuid: ref[:uuid] || ref["uuid"],
      size: ref[:size] || ref["size"],
      hash: ref[:hash] || ref["hash"]
    }
  end

  defp hosted_sites_limit(nil), do: {:ok, 100}
  defp hosted_sites_limit(""), do: {:ok, 100}

  defp hosted_sites_limit(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 and n <= 500 -> {:ok, n}
      {n, ""} when n > 500 -> {:error, {:bad_request, "limit must be <= 500"}}
      _ -> {:error, {:bad_request, "limit must be a positive integer"}}
    end
  end

  defp hosted_sites_offset(nil), do: {:ok, 0}
  defp hosted_sites_offset(""), do: {:ok, 0}

  defp hosted_sites_offset(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:bad_request, "offset must be a non-negative integer"}}
    end
  end

  defp validate_mutable_path("/") do
    {:error, :bad_path}
  end

  defp validate_mutable_path(path) do
    cond do
      String.contains?(path, "\0") -> {:error, :bad_path}
      path == "/.." -> {:error, :bad_path}
      String.starts_with?(path, "/../") -> {:error, :bad_path}
      String.contains?(path, "/../") -> {:error, :bad_path}
      String.ends_with?(path, "/..") -> {:error, :bad_path}
      RuntimeFiles.matches?(path) -> {:error, :runtime_path}
      SkillProjection.matches?(path) -> {:error, :runtime_path}
      true -> :ok
    end
  end

  defp now, do: System.system_time(:second)

  defp operation_id(kind, agent_id, path, opts, fingerprint_parts) do
    prefix = operation_prefix(kind, agent_id, path, opts)

    if present?(Keyword.get(opts, :idempotency_key, "")) do
      prefix
    else
      prefix <> ":" <> hash_parts(fingerprint_parts)
    end
  end

  defp operation_prefix(kind, agent_id, path, opts) do
    idempotency_key = Keyword.get(opts, :idempotency_key, "")
    path_key = hash_parts([agent_id, path, Keyword.get(opts, :recursive, false)])

    if present?(idempotency_key) do
      kind <> ":key:" <> path_key <> ":" <> hash_parts([idempotency_key])
    else
      kind <> ":request:" <> path_key
    end
  end

  defp storage_auth_opts(opts, entrypoint) do
    [
      billing_context: Keyword.get(opts, :billing_context, %{}),
      entrypoint: Keyword.get(opts, :entrypoint, entrypoint),
      actor_type: Keyword.get(opts, :actor_type, "user"),
      storage_authorized: Keyword.get(opts, :storage_authorized, false)
    ]
  end

  defp authorize_storage_write(agent_id, events, opts, entrypoint) do
    with :ok <-
           SalixAgent.StorageAuthorization.authorize_write(%{
             agent_id: agent_id,
             events: events,
             billing_context: Keyword.get(opts, :billing_context, %{}),
             entrypoint: Keyword.get(opts, :entrypoint, entrypoint),
             actor_type: Keyword.get(opts, :actor_type, "user")
           }) do
      {:ok, Keyword.put(opts, :storage_authorized, true)}
    end
  end

  defp delete_target_fingerprint(vfs, targets) do
    targets
    |> Enum.map(fn path ->
      meta = Map.get(vfs, path, %{})
      hash_parts([path, inspect(meta["ref"]), meta["hash"], meta["size"]])
    end)
    |> hash_parts()
  end

  defp hash_parts(parts) do
    parts
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
