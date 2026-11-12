defmodule SalixWeb.Site do
  @moduledoc """
  Public static serving for agent-hosted VFS websites.

  Two entry points share one resolver:

    * `serve_host/3` — public site server. `SalixWeb.Endpoint` routes requests
      whose Host matches `{site}-{base32-agent-id}.{domain}` here. Public site
      reads intentionally do not require bearer auth.
    * `serve/4` — the path-addressed `/site/:agent/:site/...` dev fallback
      kept for deployments without a wildcard sites domain.

  Serving behavior: `index.html` resolution for bare/directory URLs with a
  `preview/index.html` entrypoint fallback at the site root, path traversal
  rejection, reserved `/_*` paths blocked from static serving, content-type mapping,
  `Cache-Control: no-cache` for every public file so stable asset URLs
  revalidate after an update, content-hash `ETag` / `If-None-Match` plus
  `Last-Modified` / `If-Modified-Since` 304s for byte-stable non-HTML assets,
  and tenant favicon / og:image / twitter HTML head decoration. Decorated HTML
  always returns its current representation instead of using validators that
  cover only the source file.

  A page's share image is the first of: its own `og:image`, a thumbnail file in
  its directory, one at the site root, the tenant's default, and a screenshot of
  the site's home page (`SalixWeb.SiteOgImage`, host mode only). With that image
  go the text tags link previews need, taken from the page's `<title>` and
  description. X shows no card without `og:title`, and `<title>` does not count.
  A page with its own `og:image` keeps its Open Graph tags as written.

  Reads are lease-free state materialization, matching the site-serving
  invariant that public GETs never claim the agent.
  """

  import Plug.Conn

  alias Salix.Control.Tenants
  alias SalixAgent.{Control, SiteId}
  alias SalixWeb.SiteOgImage

  @primary_root "/.salix/websites"
  @thumbnail_names ~w(thumbnail.png thumbnail.jpg thumbnail.webp og-image.png og-image.jpg)
  @html_decoration_scan_bytes 256 * 1024

  @mime_types %{
    ".avif" => "image/avif",
    ".css" => "text/css; charset=utf-8",
    ".gif" => "image/gif",
    ".htm" => "text/html; charset=utf-8",
    ".html" => "text/html; charset=utf-8",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".js" => "text/javascript; charset=utf-8",
    ".json" => "application/json",
    ".mjs" => "text/javascript; charset=utf-8",
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".svg" => "image/svg+xml",
    ".wasm" => "application/wasm",
    ".webp" => "image/webp",
    ".xml" => "text/xml; charset=utf-8",
    ".woff2" => "font/woff2"
  }

  # ---- public entry points ----

  @doc """
  Serve a request to a site host (`{site}-{b32}.{domain}`). `agent_id` is the
  canonical id decoded from the Host label.
  """
  @spec serve_host(Plug.Conn.t(), String.t(), String.t()) :: Plug.Conn.t()
  def serve_host(conn, agent_id, site_name) do
    case lookup_agent(agent_id) do
      {:ok, canonical_id, _agent} ->
        do_serve(conn, canonical_id, site_name, conn.request_path, :host)

      {:error, :not_found} ->
        site_error(conn, 404, "Site not found")

      {:error, _} ->
        site_error(conn, 500, "Internal server error")
    end
  end

  @doc "Path-addressed serving for `/site/:agent/:site/...` (dev fallback)."
  @spec serve(Plug.Conn.t(), String.t(), String.t(), [String.t()]) :: Plug.Conn.t()
  def serve(conn, agent_id, site_name, path_segments) do
    case lookup_agent(agent_id) do
      {:ok, canonical_id, _agent} ->
        do_serve(
          conn,
          canonical_id,
          site_name,
          "/" <> Enum.join(path_segments, "/"),
          :path
        )

      {:error, :not_found} ->
        site_error(conn, 404, "Site not found")

      {:error, _} ->
        site_error(conn, 500, "Internal server error")
    end
  end

  @doc """
  Find the agent record for a host-decoded canonical Salix agent id.
  """
  @spec lookup_agent(String.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def lookup_agent(agent_id) do
    case Control.get(agent_id) do
      {:ok, agent} -> {:ok, agent_id, agent}
      other -> other
    end
  end

  # ---- serving ----

  defp do_serve(conn, agent_id, site_name, raw_path, mode) do
    req_path = clean_path(raw_path)

    cond do
      not SiteId.valid_site_name?(site_name) ->
        site_error(conn, 404, "Site not found")

      String.contains?(req_path, "..") ->
        site_error(conn, 400, "Invalid path")

      mode == :host and req_path == SiteOgImage.path() ->
        serve_default_og_image(conn, agent_id, site_name)

      # Root /_* paths are private website control state. Endpoint dispatches
      # /_api and /_api/* before static serving; everything else reserved here,
      # including _api.json, drafts, and automatic version snapshots, is never
      # exposed as a static file.
      req_path == "/_" or String.starts_with?(req_path, "/_") ->
        site_error(conn, 404, "Not found")

      true ->
        case SalixAgent.AgentWorkspace.manifest(agent_id) do
          {:ok, vfs} -> serve_resolved(conn, agent_id, site_name, vfs, req_path, mode)
          {:error, _} -> site_error(conn, 500, "Internal server error")
        end
    end
  end

  defp serve_default_og_image(conn, agent_id, site_name) do
    with {:ok, vfs} <- SalixAgent.AgentWorkspace.manifest(agent_id),
         {:ok, base, _path, _entry} <- resolve_site_file(vfs, site_name, "/") do
      version = SiteOgImage.version(vfs, base)
      etag = ~s("#{version}")

      if etag_matches?(get_req_header(conn, "if-none-match"), etag) do
        conn |> put_og_image_headers(etag) |> send_resp(304, "")
      else
        case SiteOgImage.fetch(agent_id, site_name, version) do
          {:ok, image} ->
            conn
            |> put_resp_header("content-type", "image/jpeg")
            |> put_og_image_headers(etag)
            |> send_resp(200, image)

          {:error, reason}
          when reason in [:browser_disabled, :browser_not_configured, :browser_capture_restricted] ->
            site_error(conn, 404, "Not found")

          {:error, _reason} ->
            conn
            |> put_resp_header("retry-after", SiteOgImage.retry_after_seconds())
            |> site_error(503, "Preview image unavailable")
        end
      end
    else
      {:error, {status, message}} -> site_error(conn, status, message)
      {:error, _} -> site_error(conn, 500, "Internal server error")
    end
  end

  defp put_og_image_headers(conn, etag) do
    conn
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("etag", etag)
  end

  defp serve_resolved(conn, agent_id, site_name, vfs, req_path, mode) do
    with {:ok, base, vfs_path, entry} <- resolve_site_file(vfs, site_name, req_path) do
      content_type = content_type(vfs_path)

      if not_modified?(conn, content_type, entry) do
        conn
        |> put_cache_headers(content_type, entry)
        |> send_resp(304, "")
      else
        case SalixAgent.AgentWorkspace.stream(agent_id, vfs_path) do
          {:ok, stream, size} ->
            conn
            |> put_resp_header("content-type", content_type)
            |> put_cache_headers(content_type, entry)
            |> stream_site_body(
              stream,
              size,
              conn,
              agent_id,
              site_name,
              vfs,
              base,
              vfs_path,
              content_type,
              mode
            )

          {:error, _} ->
            site_error(conn, 500, "Internal server error")
        end
      end
    else
      {:error, {status, message}} -> site_error(conn, status, message)
    end
  end

  defp stream_site_body(
         resp_conn,
         stream,
         size,
         req_conn,
         agent_id,
         site_name,
         vfs,
         base,
         file_path,
         content_type,
         mode
       ) do
    if String.starts_with?(content_type, "text/html") do
      {favicon_url, default_og_image_url} = tenant_site_branding(agent_id)

      page_image =
        case thumbnail_url(req_conn, agent_id, site_name, vfs, base, file_path, mode) ||
               absolute_url(req_conn, default_og_image_url) do
          nil -> home_screenshot(agent_id, site_name, vfs, base, mode)
          url -> %{url: url}
        end

      page_url = page_url(req_conn, agent_id, site_name, mode)
      stream_html_response(resp_conn, stream, size, favicon_url, page_image, page_url)
    else
      stream_response(resp_conn, stream, size)
    end
  end

  defp stream_response(conn, stream, size) do
    conn
    |> put_resp_header("content-length", Integer.to_string(size))
    |> send_chunked(200)
    |> stream_chunks(stream)
  end

  defp stream_chunks(conn, stream) do
    Enum.reduce_while(stream, conn, fn piece, conn ->
      case Plug.Conn.chunk(conn, IO.iodata_to_binary(piece)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp stream_html_response(conn, stream, size, nil, nil, _page_url),
    do: stream_response(conn, stream, size)

  defp stream_html_response(conn, stream, size, favicon_url, page_image, page_url) do
    state =
      Enum.reduce_while(
        stream,
        %{
          conn: conn,
          prefix: "",
          sent?: false,
          size: size,
          favicon_url: favicon_url,
          page_image: page_image,
          page_url: page_url
        },
        &stream_html_chunk/2
      )

    if state.sent? do
      state.conn
    else
      decorated = decorate_html_prefix(state.prefix, state)

      case state.conn
           |> start_length_stream(byte_size(decorated))
           |> maybe_chunk(decorated) do
        {:ok, conn} -> conn
        {:error, _reason} -> state.conn
      end
    end
  end

  defp stream_html_chunk(piece, %{sent?: true, conn: conn} = state) do
    case Plug.Conn.chunk(conn, IO.iodata_to_binary(piece)) do
      {:ok, conn} -> {:cont, %{state | conn: conn}}
      {:error, _reason} -> {:halt, state}
    end
  end

  defp stream_html_chunk(piece, state) do
    body = state.prefix <> IO.iodata_to_binary(piece)

    if byte_size(body) < @html_decoration_scan_bytes do
      {:cont, %{state | prefix: body}}
    else
      <<prefix::binary-size(@html_decoration_scan_bytes), rest::binary>> = body
      decorated = decorate_html_prefix(prefix, state)
      length = state.size + byte_size(decorated) - byte_size(prefix)
      conn = start_length_stream(state.conn, length)

      case Plug.Conn.chunk(conn, decorated) do
        {:ok, conn} ->
          case maybe_chunk(conn, rest) do
            {:ok, conn} -> {:cont, %{state | conn: conn, prefix: "", sent?: true}}
            {:error, _reason} -> {:halt, %{state | conn: conn, prefix: "", sent?: true}}
          end

        {:error, _reason} ->
          {:halt, state}
      end
    end
  end

  defp maybe_chunk(conn, ""), do: {:ok, conn}
  defp maybe_chunk(conn, piece), do: Plug.Conn.chunk(conn, piece)

  defp start_length_stream(conn, length) do
    conn
    |> put_resp_header("content-length", Integer.to_string(length))
    |> send_chunked(200)
  end

  defp decorate_html_prefix(prefix, state) do
    if String.valid?(prefix) do
      warm_home_screenshot(prefix, state.page_image)

      prefix
      |> site_html_decoration_tags(state.favicon_url, state.page_image, state.page_url)
      |> then(&inject_html_head(prefix, &1))
    else
      prefix
    end
  end

  # ---- resolution ----

  defp resolve_site_file(vfs, site_name, req_path) do
    base = @primary_root <> "/" <> site_name

    if root_exists?(vfs, base) do
      resolve_at_base(vfs, base, req_path)
    else
      {:error, {404, "Not found"}}
    end
  end

  # The manifest holds files only (directories are implicit), so a website
  # root exists when anything lives under it.
  defp root_exists?(vfs, base) do
    Map.has_key?(vfs, base) or
      Enum.any?(Map.keys(vfs), &String.starts_with?(&1, base <> "/"))
  end

  defp resolve_at_base(vfs, base, req_path) do
    vfs_path = if req_path == "/", do: base, else: base <> req_path

    case Map.fetch(vfs, vfs_path) do
      {:ok, entry} ->
        {:ok, base, vfs_path, entry}

      :error ->
        # Try with /index.html appended (bare directory URLs).
        index_path = String.trim_trailing(vfs_path, "/") <> "/index.html"

        case Map.fetch(vfs, index_path) do
          {:ok, entry} ->
            {:ok, base, index_path, entry}

          :error when vfs_path == base ->
            # Preview entrypoint, only at the site root.
            preview_path = base <> "/preview/index.html"

            case Map.fetch(vfs, preview_path) do
              {:ok, entry} -> {:ok, base, preview_path, entry}
              :error -> {:error, {404, "Not found"}}
            end

          :error ->
            {:error, {404, "Not found"}}
        end
    end
  end

  # ---- conditional requests / headers ----

  defp not_modified?(conn, content_type, entry) do
    if html_content_type?(content_type) do
      false
    else
      case get_req_header(conn, "if-none-match") do
        [] -> not_modified_since?(conn, entry)
        values -> etag_matches?(values, entry_etag(entry))
      end
    end
  end

  defp not_modified_since?(conn, entry) do
    with ts when is_integer(ts) <- entry["modified_at"],
         [ims | _] <- get_req_header(conn, "if-modified-since"),
         {:ok, since} <- parse_http_date(ims) do
      ts <= since
    else
      _ -> false
    end
  end

  defp etag_matches?(_values, nil), do: false

  defp etag_matches?(values, etag) do
    Enum.any?(values, fn value ->
      value
      |> String.split(",")
      |> Enum.any?(fn candidate -> String.trim(candidate) in ["*", etag] end)
    end)
  end

  defp entry_etag(%{"hash" => hash}) when is_binary(hash), do: ~s("#{hash}")
  defp entry_etag(_entry), do: nil

  defp put_cache_headers(conn, content_type, entry) do
    conn = put_resp_header(conn, "cache-control", "no-cache")

    if html_content_type?(content_type) do
      conn
    else
      conn =
        case entry_etag(entry) do
          nil -> conn
          etag -> put_resp_header(conn, "etag", etag)
        end

      case entry["modified_at"] do
        ts when is_integer(ts) -> put_resp_header(conn, "last-modified", http_date(ts))
        _ -> conn
      end
    end
  end

  defp html_content_type?(content_type), do: String.starts_with?(content_type, "text/html")

  defp http_date(unix) do
    unix
    |> DateTime.from_unix!()
    |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
  end

  defp parse_http_date(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      :bad_date ->
        :error

      erl_dt ->
        {:ok, erl_dt |> :calendar.datetime_to_gregorian_seconds() |> Kernel.-(62_167_219_200)}
    end
  end

  @doc false
  def content_type(path) do
    ext = String.downcase(Path.extname(path))

    case Map.fetch(@mime_types, ext) do
      {:ok, type} ->
        type

      :error ->
        # Approximate Go's /etc/mime.types lookup with the MIME library.
        case ext do
          "." <> rest ->
            case MIME.type(rest) do
              "application/octet-stream" -> "application/octet-stream"
              "text/" <> _ = type -> type <> "; charset=utf-8"
              type -> type
            end

          _ ->
            "application/octet-stream"
        end
    end
  end

  # ---- path cleaning ----

  defp clean_path(path) do
    cleaned =
      path
      |> String.split("/")
      |> Enum.reduce([], fn
        "", acc -> acc
        ".", acc -> acc
        "..", [] -> []
        "..", [_ | rest] -> rest
        seg, acc -> [seg | acc]
      end)
      |> Enum.reverse()
      |> Enum.join("/")

    "/" <> cleaned
  end

  # ---- error pages ----

  @doc false
  def site_error(conn, status, message) do
    body =
      "<!doctype html><html><head><title>#{status} #{message}</title></head>" <>
        "<body><h1>#{status} #{message}</h1></body></html>"

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end

  # ---- HTML decoration ----

  defp tenant_site_branding(agent_id) do
    with {:ok, agent} <- Control.get(agent_id),
         {:ok, tenant} <- Tenants.get(agent["tenant_id"]),
         {:ok, config} <- Jason.decode(tenant["config"] || "{}") do
      {trimmed(config["favicon_url"]), trimmed(config["default_og_image_url"])}
    else
      _ -> {nil, nil}
    end
  end

  defp page_url(conn, agent_id, site_name, :host),
    do: SiteId.site_url(agent_id, site_name) <> clean_path(conn.request_path)

  defp page_url(conn, _agent_id, _site_name, :path),
    do: absolute_url(conn, clean_path(conn.request_path))

  # The capture needs the site's public URL, which path mode does not have. That
  # URL also names the image: previews such as iMessage need https, which the
  # request's forwarded scheme does not promise.
  defp home_screenshot(_agent_id, _site_name, _vfs, _base, :path), do: nil

  # A site without a home page has nothing to capture, so its pages name no image.
  defp home_screenshot(agent_id, site_name, vfs, base, :host) do
    if match?({:ok, _, _, _}, resolve_site_file(vfs, site_name, "/")) and
         SiteOgImage.available?(agent_id) do
      version = SiteOgImage.version(vfs, base)

      %{
        url: SiteId.site_url(agent_id, site_name) <> SiteOgImage.url(version),
        screenshot: {agent_id, site_name, version}
      }
    end
  end

  # A crawler that meets a missing image may keep the miss for days, so the first
  # visit starts the capture before anyone asks for the image.
  defp warm_home_screenshot(existing, %{screenshot: {agent_id, site_name, version}}) do
    unless meta?(existing, "og:image"), do: SiteOgImage.warm(agent_id, site_name, version)
  end

  defp warm_home_screenshot(_existing, _page_image), do: :ok

  # Probe the HTML file's directory, then the site root, for the fixed thumbnail
  # names.
  defp thumbnail_url(conn, agent_id, site_name, vfs, base, file_path, mode) do
    dir = Path.dirname(file_path)

    if String.starts_with?(dir, base) do
      [String.trim_trailing(dir, "/"), base]
      |> Enum.uniq()
      |> Enum.flat_map(fn root -> Enum.map(@thumbnail_names, &(root <> "/" <> &1)) end)
      |> Enum.find(&Map.has_key?(vfs, &1))
      |> case do
        nil -> nil
        path -> site_path_url(conn, agent_id, site_name, base, path, mode)
      end
    else
      nil
    end
  end

  # Convert a site-relative VFS path to an absolute URL. Host mode resolves
  # against the site subdomain itself; path mode against the path-addressed
  # /site/ prefix.
  defp site_path_url(conn, agent_id, site_name, base, vfs_path, mode) do
    rel = String.replace_prefix(vfs_path, base, "")
    rel = if String.starts_with?(rel, "/"), do: rel, else: "/" <> rel

    case mode do
      :host ->
        absolute_url(conn, rel)

      :path ->
        absolute_url(
          conn,
          "/site/" <> URI.encode(agent_id) <> "/" <> URI.encode(site_name) <> rel
        )
    end
  end

  # Absolute refs pass through; relative refs resolve against the request
  # scheme/host (X-Forwarded-* aware).
  defp absolute_url(_conn, nil), do: nil

  defp absolute_url(conn, ref) do
    ref = String.trim(ref)

    cond do
      ref == "" ->
        nil

      match?(%URI{scheme: scheme} when is_binary(scheme), URI.parse(ref)) ->
        ref

      String.starts_with?(ref, "//") ->
        request_scheme(conn) <> ":" <> ref

      true ->
        ref = if String.starts_with?(ref, "/"), do: ref, else: "/" <> ref
        request_scheme(conn) <> "://" <> request_host(conn) <> ref
    end
  end

  defp request_scheme(conn) do
    case first_forwarded(conn, "x-forwarded-proto") do
      nil -> Atom.to_string(conn.scheme || :http)
      proto -> proto
    end
  end

  defp request_host(conn) do
    case first_forwarded(conn, "x-forwarded-host") do
      nil ->
        host = conn.host || "localhost"
        if conn.port in [80, 443, nil], do: host, else: "#{host}:#{conn.port}"

      host ->
        host
    end
  end

  defp first_forwarded(conn, header) do
    case get_req_header(conn, header) do
      [value | _] ->
        case value |> String.split(",") |> List.first() |> String.trim() do
          "" -> nil
          first -> first
        end

      _ ->
        nil
    end
  end

  defp site_html_decoration_tags(existing, favicon_url, page_image, page_url) do
    []
    |> maybe_add_favicon(favicon_url)
    |> maybe_add_og_tags(existing, page_image, page_url)
    |> Enum.reverse()
    |> Enum.join("")
  end

  defp maybe_add_favicon(tags, nil), do: tags

  defp maybe_add_favicon(tags, favicon_url),
    do: [~s(<link rel="icon" href="#{html_escape(favicon_url)}">\n) | tags]

  defp maybe_add_og_tags(tags, _existing, nil, _page_url), do: tags

  defp maybe_add_og_tags(tags, existing, page_image, page_url) do
    if meta?(existing, "og:image") do
      tags
    else
      image = html_escape(page_image.url)

      missing =
        [
          {"property", "og:title", page_title(existing)},
          {"property", "og:description", page_description(existing)},
          {"property", "og:url", html_escape(page_url)},
          {"property", "og:type", "website"},
          {"name", "twitter:image", image},
          {"name", "twitter:card", "summary_large_image"}
        ]
        |> Enum.reject(fn {_attr, name, content} -> is_nil(content) or meta?(existing, name) end)

      [{"property", "og:image", image}]
      |> Kernel.++(screenshot_tags(page_image))
      |> Kernel.++(missing)
      |> Enum.reduce(tags, fn {attr, name, content}, tags ->
        [~s(<meta #{attr}="#{name}" content="#{content}">\n) | tags]
      end)
    end
  end

  # Facebook shows an image on the first share only when it knows the size.
  defp screenshot_tags(%{screenshot: _}) do
    {width, height} = SalixAgent.Browser.capture_size()

    [
      {"property", "og:image:type", "image/jpeg"},
      {"property", "og:image:width", width},
      {"property", "og:image:height", height}
    ]
  end

  defp screenshot_tags(_page_image), do: []

  defp meta?(existing, name) do
    String.match?(
      existing,
      ~r/<meta\s+[^>]*(property|name)\s*=\s*["']#{Regex.escape(name)}["'][^>]*>/is
    )
  end

  # Both values are already HTML text. Only a quote can break out of the attribute.
  defp page_title(existing) do
    case Regex.run(~r/<title\b[^>]*>(.*?)<\/title>/is, existing) do
      [_, title] -> attribute_text(title)
      nil -> nil
    end
  end

  defp page_description(existing) do
    with [tag] <- Regex.run(~r/<meta\s+[^>]*name\s*=\s*["']description["'][^>]*>/is, existing),
         [_, _quote, description] <- Regex.run(~r/\bcontent\s*=\s*(["'])(.*?)\1/is, tag) do
      attribute_text(description)
    else
      nil -> nil
    end
  end

  defp attribute_text(text) do
    case text |> String.split() |> Enum.join(" ") do
      "" -> nil
      text -> String.replace(text, "\"", "&quot;")
    end
  end

  defp inject_html_head(body, ""), do: body

  defp inject_html_head(body, tags) do
    case Regex.run(~r/<head\b[^>]*>/is, body, return: :index) do
      [{start, len}] ->
        {before_head, rest} = String.split_at(body, start + len)
        before_head <> tags <> rest

      nil ->
        tags <> body
    end
  end

  defp trimmed(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp trimmed(_), do: nil

  defp html_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
