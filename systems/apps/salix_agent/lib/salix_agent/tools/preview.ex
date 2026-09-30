defmodule SalixAgent.Tools.Preview do
  @moduledoc """
  Website publishing exposed to agents as the single `preview.publish_html`
  entrypoint.

  The tool accepts inline `html`, one VFS `source_path`, or a complete VFS
  `source_root`. A new canonical `site_name` creates
  `/.salix/websites/{site}/`; publishing the same canonical name first snapshots
  the current public tree under `/_versions/vNNNN/`, then replaces the public
  content in the same workspace operation. `html` and `source_path` replace only
  `index.html`; `source_root` mirrors the complete public tree.

  All events returned by one call are committed atomically with the tool result
  by the existing AgentWorkspace operation boundary. Reserved root paths whose
  first segment starts with `_` stay outside the public tree, except
  `_api.json`, which is the site's private API configuration and versions with
  the rest of the site.
  """

  alias SalixAgent.{AgentWorkspace, FileBackend, SiteId, StorageAuthorization}

  @max_html_bytes 10 * 1024 * 1024
  @max_versions 20

  @description """
  Publish or update a website through Bridge's canonical verified website path. This is the single publishing entrypoint for an interactive HTML page, web demo, mini-app, or multi-file site. Provide complete inline html, one absolute VFS source_path, or an absolute VFS source_root containing index.html. Reusing the exact canonical site_name updates the same URL and automatically snapshots the previous public version; a different canonical site_name creates a different website. source_root mirrors the public site, while html and source_path replace only index.html. Do not hand-write bridge-sites URLs or send data:text/html links; return the URL produced by this tool.
  """

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @visible_write_opts [safety: "write"]

  @doc """
  Tool defs in stable registration order: `{name, description, fun,
  auto_wait_seconds}` entries where `fun` is a 2-arity capture taking
  `(args, ctx)`.
  """
  @spec defs() ::
          [{String.t(), String.t(), (map(), map() -> term()), pos_integer(), keyword()}]
  def defs do
    [
      {"preview.publish_html", String.trim(@description), &__MODULE__.publish_html_preview/2,
       @normal_auto_wait_seconds, @visible_write_opts}
    ]
  end

  @doc false
  def publish_html_preview(args, ctx) do
    if is_nil(SiteId.sites_domain()),
      do: raise("agent website domain is not configured")

    site_name = resolve_site_name(args, ctx)
    site_root = "/.salix/websites/" <> site_name
    entrypoint_path = site_root <> "/index.html"
    vfs = manifest!(ctx.agent_id)
    source = resolve_source(args, ctx, vfs)
    live_entries = public_site_entries(vfs, site_root)

    {events, backup_version} =
      case source do
        {:document, html} ->
          plan_document_publish(ctx, vfs, site_root, entrypoint_path, live_entries, html)

        {:directory, source_entries} ->
          plan_directory_publish(ctx, vfs, site_root, live_entries, source_entries)
      end

    output =
      %{
        "published_preview" => true,
        "url" => site_url(ctx.agent_id, site_name),
        "site_name" => site_name,
        "entrypoint_path" => "/",
        "vfs_path" => entrypoint_path,
        "mime_type" => "text/html; charset=utf-8",
        "verified_status" => "ok"
      }
      |> maybe_put_backup_version(backup_version)

    {Jason.encode!(output), events}
  end

  defp plan_document_publish(ctx, vfs, site_root, entrypoint_path, live_entries, html) do
    if same_content?(Map.get(live_entries, "index.html"), html) do
      {[], nil}
    else
      {backup_events, backup_version, retention_events} =
        prepare_backup(vfs, site_root, live_entries)

      authorization_events =
        backup_events ++
          [%{"type" => "vfs_write", "path" => entrypoint_path}] ++ retention_events

      authorize_events!(ctx, authorization_events)

      write_event =
        case AgentWorkspace.prepare_managed_write(ctx.agent_id, entrypoint_path, html) do
          {:ok, event} -> event
          {:error, reason} -> raise "publish HTML preview: #{inspect(reason)}"
        end

      {backup_events ++ [write_event] ++ retention_events, backup_version}
    end
  end

  defp plan_directory_publish(ctx, vfs, site_root, live_entries, source_entries) do
    if same_tree?(live_entries, source_entries) do
      {[], nil}
    else
      {backup_events, backup_version, retention_events} =
        prepare_backup(vfs, site_root, live_entries)

      publish_events = directory_publish_events(site_root, live_entries, source_entries)
      events = backup_events ++ publish_events ++ retention_events
      authorize_events!(ctx, events)
      {events, backup_version}
    end
  end

  defp prepare_backup(_vfs, _site_root, live_entries) when map_size(live_entries) == 0,
    do: {[], nil, []}

  defp prepare_backup(vfs, site_root, live_entries) do
    version_numbers = version_numbers(vfs, site_root)
    version_number = Enum.max(version_numbers, fn -> 0 end) + 1
    version = version_name(version_number)
    version_root = site_root <> "/_versions/" <> version

    backup_events =
      live_entries
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {relative, entry} -> copy_entry!(version_root <> "/" <> relative, entry) end)

    retention_events = retention_events(vfs, site_root, version_numbers ++ [version_number])
    {backup_events, version, retention_events}
  end

  defp directory_publish_events(site_root, live_entries, source_entries) do
    delete_events =
      live_entries
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(source_entries, &1))
      |> Enum.sort()
      |> Enum.map(fn relative -> AgentWorkspace.prepare_delete(site_root <> "/" <> relative) end)

    write_events =
      source_entries
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {relative, entry} -> copy_entry!(site_root <> "/" <> relative, entry) end)

    delete_events ++ write_events
  end

  defp retention_events(vfs, site_root, version_numbers) do
    old_prefixes =
      version_numbers
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.drop(-@max_versions)
      |> Enum.map(&(site_root <> "/_versions/" <> version_name(&1) <> "/"))

    vfs
    |> Map.keys()
    |> Enum.filter(fn path -> Enum.any?(old_prefixes, &String.starts_with?(path, &1)) end)
    |> Enum.sort()
    |> Enum.map(&AgentWorkspace.prepare_delete/1)
  end

  defp version_numbers(vfs, site_root) do
    prefix = site_root <> "/_versions/"

    vfs
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.flat_map(fn path ->
      result =
        path
        |> String.replace_prefix(prefix, "")
        |> String.split("/", parts: 2)
        |> hd()
        |> parse_version_number()

      case result do
        {:ok, number} -> [number]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp parse_version_number("v" <> digits) do
    case Integer.parse(digits) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> :error
    end
  end

  defp parse_version_number(_), do: :error

  defp version_name(number) do
    "v" <> (number |> Integer.to_string() |> String.pad_leading(4, "0"))
  end

  defp resolve_source(args, ctx, vfs) do
    html = String.trim(arg(args, "html"))
    source_path = String.trim(arg(args, "source_path"))
    source_root = String.trim(arg(args, "source_root"))

    cond do
      html != "" ->
        {:document, validate_html!(html)}

      source_path != "" ->
        {:document, read_source_html!(source_path, ctx)}

      source_root != "" ->
        {:directory, source_tree!(source_root, vfs)}

      true ->
        raise "html, an absolute source_path, or an absolute source_root is required"
    end
  end

  defp read_source_html!(source_path, ctx) do
    if not String.starts_with?(source_path, "/"),
      do: raise("html or an absolute source_path is required")

    html =
      case FileBackend.stat(ctx, source_path) do
        {:error, :not_found} ->
          raise "read source HTML from visible files: no such file: #{source_path}"

        {:ok, %{size: size}} when is_integer(size) and size > @max_html_bytes ->
          raise "source HTML too large (#{@max_html_bytes}+ bytes, limit #{@max_html_bytes})"

        {:ok, _} ->
          case FileBackend.read(ctx, source_path) do
            {:ok, content, false} -> String.trim(content)
            {:ok, _content, true} -> raise "source HTML too large"
            {:error, reason} -> raise "read source HTML from visible files: #{inspect(reason)}"
          end
      end

    validate_html!(html)
  end

  defp validate_html!(html) do
    cond do
      byte_size(html) > @max_html_bytes ->
        raise "HTML too large (#{byte_size(html)} bytes, limit #{@max_html_bytes})"

      html == "" ->
        raise "html content is empty"

      String.starts_with?(String.downcase(html), "data:text/html") ->
        raise "data:text/html URLs are not publishable previews; pass raw HTML or a VFS source_path"

      true ->
        html
    end
  end

  defp source_tree!(raw_root, vfs) do
    root = normalize_absolute_root!(raw_root)
    entries = public_tree_entries(vfs, root)

    case Map.get(entries, "index.html") do
      %{"size" => size} when is_integer(size) and size > 0 -> entries
      _ -> raise "source_root does not contain index.html: #{root}"
    end
  end

  defp normalize_absolute_root!(root) do
    cond do
      not String.starts_with?(root, "/") ->
        raise "source_root must be an absolute VFS directory"

      root == "/" ->
        raise "source_root must not be the workspace root"

      true ->
        segments = String.split(root, "/", trim: true)

        if Enum.any?(segments, &(&1 in [".", ".."])),
          do: raise("source_root must not contain traversal segments")

        "/" <> Enum.join(segments, "/")
    end
  end

  defp public_site_entries(vfs, site_root) do
    public_tree_entries(vfs, site_root)
  end

  defp public_tree_entries(vfs, root) do
    prefix = root <> "/"

    vfs
    |> Enum.flat_map(fn {path, entry} ->
      relative = String.replace_prefix(path, prefix, "")

      if path != relative and publishable_relative_path?(relative),
        do: [{relative, entry}],
        else: []
    end)
    |> Map.new()
  end

  defp publishable_relative_path?(""), do: false
  defp publishable_relative_path?("_api.json"), do: true

  defp publishable_relative_path?(relative) do
    relative
    |> String.split("/", parts: 2)
    |> hd()
    |> then(&(not String.starts_with?(&1, "_")))
  end

  defp same_content?(nil, _content), do: false

  defp same_content?(entry, content) do
    entry["size"] == byte_size(content) and
      entry["hash"] == SalixStore.Crypto.hex(content)
  end

  defp same_tree?(live_entries, source_entries) do
    Enum.sort(Map.keys(live_entries)) == Enum.sort(Map.keys(source_entries)) and
      Enum.all?(source_entries, fn {relative, entry} ->
        same_entry?(Map.get(live_entries, relative), entry)
      end)
  end

  defp same_entry?(nil, _right), do: false

  defp same_entry?(left, right) do
    (left["size"] || left[:size]) == (right["size"] || right[:size]) and
      (left["hash"] || left[:hash]) == (right["hash"] || right[:hash])
  end

  defp copy_entry!(path, entry) do
    {:ok, event} = AgentWorkspace.prepare_copy_entry(path, entry)
    event
  end

  defp authorize_events!(ctx, events) do
    attrs = %{
      agent_id: ctx.agent_id,
      events: events,
      billing_context: Map.get(ctx, :billing_context) || Map.get(ctx, "billing_context") || %{},
      entrypoint: "storage_write",
      actor_type: "tool"
    }

    case StorageAuthorization.authorize_write(attrs) do
      :ok -> :ok
      {:error, reason} -> raise "publish website: #{inspect(reason)}"
    end
  end

  defp manifest!(agent_id) do
    case AgentWorkspace.manifest(agent_id) do
      {:ok, vfs} -> vfs
      {:error, reason} -> raise "read website workspace: #{inspect(reason)}"
    end
  end

  defp resolve_site_name(args, ctx) do
    case sanitize_site_name(arg(args, "site_name")) do
      "" ->
        default_site_name(
          arg(args, "title"),
          arg(args, "source_path"),
          arg(args, "source_root"),
          Map.get(ctx, :tool_call_id, "")
        )

      name ->
        name
    end
  end

  # Default site name: title -> source path/root basename -> tool call id -> "preview".
  defp default_site_name(title, source_path, source_root, tool_call_id) do
    source =
      case String.trim(source_path) do
        "" -> String.trim(source_root)
        path -> path
      end

    base = Path.basename(source)

    base =
      case Path.extname(base) do
        "" -> base
        ext -> String.trim_trailing(base, ext)
      end

    [title, base, tool_call_id]
    |> Enum.map(&sanitize_site_name/1)
    |> Enum.find("preview", &(&1 != ""))
  end

  @doc false
  # Lowercase; keep [a-z0-9]; map -/_/space/. runs to a single hyphen; trim
  # hyphens; cap to one hosted DNS label.
  def sanitize_site_name(value) do
    {out, _} =
      value
      |> String.trim()
      |> String.downcase()
      |> String.to_charlist()
      |> Enum.reduce({[], false}, fn ch, {acc, last_hyphen} ->
        cond do
          (ch >= ?a and ch <= ?z) or (ch >= ?0 and ch <= ?9) -> {[ch | acc], false}
          ch in [?-, ?_, ?\s, ?.] and not last_hyphen -> {[?- | acc], true}
          true -> {acc, last_hyphen}
        end
      end)

    out = out |> Enum.reverse() |> List.to_string() |> String.trim("-")
    max_length = SiteId.max_host_site_name_bytes()

    if String.length(out) > max_length do
      out |> String.slice(0, max_length) |> String.trim("-")
    else
      out
    end
  end

  defp maybe_put_backup_version(output, nil), do: output
  defp maybe_put_backup_version(output, version), do: Map.put(output, "backup_version", version)

  defp site_url(agent_id, site_name) do
    case SiteId.site_url(agent_id, site_name) do
      nil -> raise "build preview URL: invalid agent id #{agent_id}"
      url -> url <> "/"
    end
  end

  # Same string-args pattern as SalixAgent.Tools.arg/2.
  defp arg(args, key), do: to_string(args[key] || args[String.to_atom(key)] || "")
end
