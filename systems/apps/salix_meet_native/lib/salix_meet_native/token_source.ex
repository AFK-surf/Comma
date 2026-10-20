defmodule SalixMeetNative.TokenSource do
  @moduledoc false

  @meetings_scope "oauth2:https://www.googleapis.com/auth/meetings"

  @spec fetch_bearer(String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, term()}
  def fetch_bearer(profile, opts \\ []) do
    case Keyword.get(opts, :bearer) do
      bearer when is_binary(bearer) and bearer != "" -> {:ok, bearer}
      _ -> fetch_from_factory(profile, opts)
    end
  end

  defp fetch_from_factory(profile, opts) when is_binary(profile) and profile != "" do
    cfg = config(opts)

    with {:ok, base} <- fetch_cfg(cfg, :base_url),
         {:ok, secret} <- fetch_cfg(cfg, :secret) do
      url =
        String.trim_trailing(base, "/") <>
          "/v1/accounts/" <>
          URI.encode(profile, &URI.char_unreserved?/1) <>
          "/service-token?scope=" <> URI.encode_www_form(@meetings_scope)

      request =
        Req.new(method: :get, url: url, redirect: false, retry: false, receive_timeout: 20_000)
        |> Req.Request.put_header("authorization", "Bearer #{secret}")

      case Req.request(request) do
        {:ok, %Req.Response{status: 200, body: body}} -> extract_token(body)
        {:ok, %Req.Response{status: status}} -> {:error, {:token_factory_status, status}}
        {:error, %{reason: reason}} -> {:error, {:token_factory_unreachable, reason}}
        {:error, other} -> {:error, {:token_factory_unreachable, other}}
      end
    end
  end

  defp fetch_from_factory(_profile, _opts), do: {:error, :missing_profile}

  defp extract_token(%{"access_token" => token}) when is_binary(token) and token != "",
    do: {:ok, token}

  defp extract_token(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> extract_token(map)
      _ -> {:error, :invalid_token_response}
    end
  end

  defp extract_token(_), do: {:error, :missing_access_token}

  defp config(opts) do
    SystemsRuntime.get_env(:salix_meet_native, :master_token_factory, [])
    |> Keyword.merge(Keyword.get(opts, :master_token_factory, []))
  end

  defp fetch_cfg(cfg, key) do
    case Keyword.get(cfg, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_config, key}}
    end
  end
end
