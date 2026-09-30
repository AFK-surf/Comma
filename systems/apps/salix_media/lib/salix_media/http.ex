defmodule SalixMedia.HTTP do
  @moduledoc """
  Shared Req plumbing for the media clients. Resolves the configurable
  `base_url` / `api_key` (config first, then env var, then default — mirroring
  `SalixLlm.Anthropic`) and POSTs a JSON body to a provider endpoint, returning
  the decoded body on 200 or a tagged error otherwise.

  Tests override `config :salix_media, :base_url, ...` to point at a mock
  Bandit server.
  """

  require Logger

  @default_base_url "https://api.salix.media"

  @doc "Resolve `base_url` / `api_key` from app config, falling back to env then defaults."
  @spec config() :: %{base_url: String.t(), api_key: String.t()}
  def config do
    env = Application.get_all_env(:salix_media)

    %{
      base_url: pick(env, :base_url, "SALIX_MEDIA_BASE_URL", @default_base_url),
      api_key: pick(env, :api_key, "SALIX_MEDIA_API_KEY", "")
    }
  end

  @doc "Resolve provider-ish config maps into base_url/api_key/header values."
  def provider_config(opts_or_cfg \\ []) do
    cfg =
      if Keyword.keyword?(opts_or_cfg),
        do: Keyword.get(opts_or_cfg, :config, %{}),
        else: opts_or_cfg

    cfg = normalize(cfg)
    provider_cfg = normalize(cfg["provider_config"] || %{})

    legacy =
      if cfg["credential_scope"] == "tenant",
        do: %{base_url: "", api_key: ""},
        else: config()

    %{
      credential_scope: cfg["credential_scope"],
      provider: to_string(cfg["provider"] || "legacy"),
      model: to_string(cfg["model"] || ""),
      base_url: to_string(provider_cfg["base_url"] || legacy.base_url),
      api_key: resolve_key(provider_cfg, legacy.api_key),
      default_headers: normalize(provider_cfg["default_headers"] || %{}),
      request_headers: normalize(cfg["request_headers"] || %{})
    }
  end

  @doc """
  POST `body` as JSON to a path or absolute URL. Returns `{:ok, decoded_body}`
  on 2xx, `{:error, {:http, status, body}}` on other statuses, and
  `{:error, {:transport, reason}}` on transport failure.
  """
  @spec post(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(path, body, opts \\ []) do
    case opts[:transport] do
      transport when is_function(transport, 2) ->
        case transport.(path, json: body) do
          {:ok, %{status: status, body: raw}} when status in 200..299 -> Jason.decode(raw)
          {:ok, %{status: status, body: raw}} -> {:error, {:http, status, raw}}
          {:error, reason} -> {:error, {:transport, reason}}
        end

      nil ->
        post_http(path, body, opts)
    end
  end

  defp post_http(path, body, opts) do
    provider = Keyword.get(opts, :provider) || provider_config(opts[:config] || [])

    with {:ok, url} <- request_url(path, provider) do
      headers =
        [
          {"content-type", "application/json"}
        ] ++ auth_headers(provider, Keyword.get(opts, :auth, :bearer)) ++ extra_headers(provider)

      case Req.post(url,
             json: body,
             headers: headers,
             receive_timeout: opts[:receive_timeout] || 120_000,
             retry: :transient
           ) do
        {:ok, %{status: status, body: resp}} when status in 200..299 ->
          {:ok, resp}

        {:ok, %{status: status, body: resp}} ->
          Logger.error("salix_media #{path} #{status}: #{inspect(resp)}")
          {:error, {:http, status, resp}}

        {:error, reason} ->
          Logger.error("salix_media #{path} transport error: #{inspect(reason)}")
          {:error, {:transport, reason}}
      end
    end
  end

  def get(path, opts \\ []) do
    provider = Keyword.get(opts, :provider) || provider_config(opts[:config] || [])

    headers = auth_headers(provider, Keyword.get(opts, :auth, :bearer)) ++ extra_headers(provider)

    case Req.get(path,
           headers: headers,
           receive_timeout: opts[:receive_timeout] || 120_000,
           retry: :transient
         ) do
      {:ok, %{status: status, body: resp}} when status in 200..299 -> {:ok, resp}
      {:ok, %{status: status, body: resp}} -> {:error, {:http, status, resp}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  def download(url, opts \\ []) do
    case Req.get(url, receive_timeout: opts[:receive_timeout] || 600_000, retry: :transient) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        {:ok, body, content_type(headers)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # Tenant-owned credentials must never be sent through a platform endpoint fallback.
  defp request_url(path, %{credential_scope: "tenant"}) do
    case URI.parse(path) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, path}

      _ ->
        {:error, :private_media_endpoint_required}
    end
  end

  defp request_url(path, _provider),
    do: {:ok, if(String.starts_with?(path, "http"), do: path, else: config().base_url <> path)}

  defp pick(env, key, env_var, default) do
    cond do
      v = env[key] -> v
      v = System.get_env(env_var) -> v
      true -> default
    end
  end

  defp normalize(nil), do: %{}
  defp normalize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp normalize(list) when is_list(list), do: Map.new(list, fn {k, v} -> {to_string(k), v} end)
  defp normalize(_), do: %{}

  defp resolve_key(provider_cfg, legacy) do
    key = provider_cfg["api_key"] |> to_string() |> String.trim()
    env = provider_cfg["api_key_env"] |> to_string() |> String.trim()

    cond do
      key != "" -> key
      env != "" -> System.get_env(env, "")
      true -> legacy || ""
    end
  end

  defp auth_headers(%{api_key: ""}, _), do: []
  defp auth_headers(%{api_key: key}, :x_goog_api_key), do: [{"x-goog-api-key", key}]
  defp auth_headers(%{api_key: key}, _), do: [{"authorization", "Bearer " <> key}]

  defp extra_headers(provider) do
    Map.merge(provider.default_headers, provider.request_headers)
    |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
  end

  defp content_type(headers) do
    Enum.find_value(headers, "", fn {k, v} ->
      if String.downcase(to_string(k)) == "content-type", do: to_string(v)
    end)
  end
end
