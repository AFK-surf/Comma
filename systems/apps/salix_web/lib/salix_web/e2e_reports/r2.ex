defmodule SalixWeb.E2EReports.R2 do
  @moduledoc """
  Minimal R2 reader/deleter for E2E report bundles.

  Uploads happen from GitHub Actions. Salix only needs read/list/delete for the
  admin dashboard and signed report-session file serving.
  """

  @finch SalixStore.Finch
  @recv_timeout 30_000

  def get_object(key) do
    with {:ok, cfg} <- config(),
         {:ok, %{status: status, body: body, headers: headers}} <-
           request("GET", object_url(cfg, key), [], "", cfg) do
      case status do
        code when code in 200..299 ->
          {:ok, %{body: body, size: byte_size(body), headers: headers}}

        404 ->
          {:error, :not_found}

        code ->
          {:error, {:http, code, body}}
      end
    end
  end

  def delete_object(key) do
    with {:ok, cfg} <- config(),
         {:ok, %{status: status, body: body}} <-
           request("DELETE", object_url(cfg, key), [], "", cfg) do
      case status do
        code when code in 200..299 -> :ok
        404 -> :ok
        code -> {:error, {:http, code, body}}
      end
    end
  end

  def list_objects(prefix) do
    list_objects(prefix, nil, [])
  end

  defp list_objects(prefix, continuation_token, acc) do
    with {:ok, cfg} <- config() do
      query =
        [
          {"list-type", "2"},
          {"prefix", prefix}
        ]
        |> maybe_query("continuation-token", continuation_token)
        |> URI.encode_query()

      case request("GET", bucket_url(cfg) <> "?" <> query, [], "", cfg) do
        {:ok, %{status: 200, body: body}} ->
          page = parse_list(body)
          objects = acc ++ page.objects

          case page.next do
            nil -> {:ok, objects}
            next -> list_objects(prefix, next, objects)
          end

        {:ok, %{status: status, body: body}} ->
          {:error, {:http, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp request(method, url, headers, body, cfg) do
    signed = SalixStore.SigV4.sign(method, url, headers, body, cfg)

    Finch.build(method_atom(method), url, signed, body)
    |> Finch.request(@finch, receive_timeout: @recv_timeout)
  end

  defp method_atom("GET"), do: :get
  defp method_atom("DELETE"), do: :delete

  defp config do
    env = Application.get_env(:salix_web, :e2e_reports_r2, [])

    cfg = %SalixStore.Config{
      endpoint: pick(env, :endpoint),
      region: pick(env, :region, "auto"),
      bucket: pick(env, :bucket),
      access_key_id: pick(env, :access_key_id),
      secret_access_key: pick(env, :secret_access_key),
      addressing: :path,
      atomic_operations: :s3
    }

    cond do
      blank?(cfg.endpoint) -> {:error, :not_configured}
      blank?(cfg.bucket) -> {:error, :not_configured}
      blank?(cfg.access_key_id) -> {:error, :not_configured}
      blank?(cfg.secret_access_key) -> {:error, :not_configured}
      true -> {:ok, cfg}
    end
  end

  defp pick(env, key, default \\ nil) do
    Keyword.get(env, key, default)
  end

  defp bucket_url(cfg) do
    "#{String.trim_trailing(cfg.endpoint, "/")}/#{encode_segment(cfg.bucket)}"
  end

  defp object_url(cfg, key), do: "#{bucket_url(cfg)}/#{encode_key(key)}"

  defp encode_key(key) do
    key
    |> String.split("/")
    |> Enum.map(&encode_segment/1)
    |> Enum.join("/")
  end

  defp encode_segment(segment) do
    URI.encode(segment, &uri_unreserved?/1)
  end

  defp uri_unreserved?(char) do
    char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?-, ?_, ?., ?~]
  end

  defp maybe_query(query, _key, nil), do: query
  defp maybe_query(query, key, value), do: query ++ [{key, value}]

  defp blank?(value), do: value in [nil, ""]

  defp parse_list(xml) do
    objects =
      Regex.scan(~r{<Contents>(.*?)</Contents>}s, xml)
      |> Enum.map(fn [_, inner] ->
        %{
          key: tag(inner, "Key"),
          size: (tag(inner, "Size") || "0") |> String.to_integer(),
          lastModified: tag(inner, "LastModified")
        }
      end)

    next =
      case tag(xml, "NextContinuationToken") do
        nil -> nil
        "" -> nil
        token -> token
      end

    %{objects: objects, next: next}
  end

  defp tag(xml, name) do
    case Regex.run(~r{<#{name}>(.*?)</#{name}>}s, xml) do
      [_, val] -> unescape(val)
      _ -> nil
    end
  end

  defp unescape(value) do
    value
    |> String.replace("&#34;", "\"")
    |> String.replace("&#x22;", "\"")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&#x27;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
