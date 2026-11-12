defmodule SalixStore.OAuth.LarkDevice do
  @moduledoc """
  A Feishu or Lark user sign-in by a device code (RFC 8628), as the official
  larksuite/cli `auth login` does: the person confirms a link in Feishu or
  Lark, and the app gets their user access token. It needs no redirect URI,
  so it works with the app a scan made (`SalixIM.Provider.Lark.Registration`),
  which has nobody in the Developer Console to register one.

  The app is the client: its App ID and App Secret authenticate both steps.
  The tokens refresh like any other sign-in of the provider
  (`SalixStore.OAuth.Adapters.Feishu.refresh/2`, `...Lark.refresh/2`).
  """

  alias SalixStore.OAuth.Adapter

  @accounts %{
    "feishu" => "https://accounts.feishu.cn",
    "lark" => "https://accounts.larksuite.com"
  }
  @api %{
    "feishu" => "https://open.feishu.cn/open-apis",
    "lark" => "https://open.larksuite.com/open-apis"
  }

  @type begun :: %{
          device_code: String.t(),
          url: String.t(),
          interval_s: pos_integer(),
          expires_in_s: pos_integer()
        }

  @doc """
  Asks for a device code for `scopes` with `app`. The answer has the link the
  person confirms in Feishu or Lark.
  """
  @spec begin(String.t(), map(), [String.t()]) :: {:ok, begun()} | {:error, term()}
  def begin(provider, app, scopes) when is_map_key(@accounts, provider) do
    with :ok <- client(app) do
      scope = Enum.uniq(scopes ++ ["offline_access"]) |> Enum.join(" ")

      case request(provider, "device_authorization_url", "/oauth/v1/device_authorization",
             form: [client_id: app["client_id"], scope: scope],
             auth: {:basic, app["client_id"] <> ":" <> app["client_secret"]}
           ) do
        {:ok, %{"device_code" => code} = body} when is_binary(code) and code != "" ->
          url = body["verification_uri_complete"] || body["verification_uri"]

          if is_binary(url) and url != "" do
            {:ok,
             %{
               device_code: code,
               url: url,
               interval_s: positive(body["interval"], 5),
               expires_in_s: positive(body["expires_in"], 240)
             }}
          else
            {:error, "#{provider} oauth: device authorization returned no link"}
          end

        {:ok, %{"error" => error}} when is_binary(error) ->
          {:error, {:device_refused, String.slice(error, 0, 64)}}

        {:ok, _body} ->
          {:error, "#{provider} oauth: device authorization returned no code"}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Asks once whether the person confirmed. `:pending` and `:slow_down` ask
  again later; `{:error, :denied | :expired}` ends the sign-in. Confirmed, it
  answers the tokens and the account as a code exchange does.
  """
  @spec poll(String.t(), map(), String.t()) ::
          {:ok, %{String.t() => map()}} | :pending | :slow_down | {:error, term()}
  def poll(provider, app, device_code)
      when is_map_key(@accounts, provider) and is_binary(device_code) do
    with :ok <- client(app) do
      case request(provider, "device_token_url", "/oauth/v3/token",
             form: [
               grant_type: "urn:ietf:params:oauth:grant-type:device_code",
               device_code: device_code,
               client_id: app["client_id"],
               client_secret: app["client_secret"]
             ]
           ) do
        {:ok, %{"access_token" => token} = body} when is_binary(token) and token != "" ->
          with {:ok, account} <- account(provider, token) do
            {:ok, %{"tokens" => tokens(body), "account" => account}}
          end

        {:ok, %{"error" => "authorization_pending"}} ->
          :pending

        {:ok, %{"error" => "slow_down"}} ->
          :slow_down

        # Throttled (HTTP 429): ask again later.
        {:error, :throttled} ->
          :slow_down

        {:ok, %{"error" => "access_denied"}} ->
          {:error, :denied}

        {:ok, %{"error" => "expired_token"}} ->
          {:error, :expired}

        {:ok, %{"error" => error}} when is_binary(error) ->
          {:error, {:device_refused, String.slice(error, 0, 64)}}

        {:ok, _body} ->
          {:error, "#{provider} oauth: token response missing access_token"}

        {:error, _} = error ->
          error
      end
    end
  end

  defp account(provider, token) do
    case Req.request(
           [
             method: :get,
             url: Adapter.endpoint(provider, "api_url", @api[provider] <> "/authen/v1/user_info"),
             auth: {:bearer, token}
           ] ++ base_options()
         ) do
      {:ok, %{status: 200, body: %{"code" => 0, "data" => %{"open_id" => open_id} = user}}}
      when is_binary(open_id) and open_id != "" ->
        {:ok,
         %{
           "provider_account_id" => open_id,
           "provider_account_name" => user["name"] || user["en_name"] || open_id,
           "metadata" => %{
             "open_id" => open_id,
             "union_id" => user["union_id"],
             "name" => user["name"],
             "email" => user["enterprise_email"] || user["email"],
             "tenant_key" => user["tenant_key"]
           }
         }}

      _ ->
        {:error, "#{provider} oauth: user info response missing open_id"}
    end
  end

  defp tokens(body),
    do: %{
      "access_token" => body["access_token"],
      "refresh_token" => body["refresh_token"],
      "token_type" => body["token_type"] || "Bearer",
      "scopes" => Adapter.split_scopes(body["scope"], ~r/\s+/),
      "expires_at" => Adapter.expires_at_ms(body["expires_in"]),
      "refresh_expires_at" => Adapter.expires_at_ms(body["refresh_token_expires_in"])
    }

  # The accounts service answers OAuth errors with a 4xx and an `error` body;
  # those are answers, not failures. Bodies can carry credentials: only safe
  # classifications leave here.
  defp request(provider, key, path, opts) do
    case Req.request(
           [method: :post, url: Adapter.endpoint(provider, key, @accounts[provider] <> path)] ++
             base_options() ++ opts
         ) do
      # Throttled, with or without a JSON body: ask again later.
      {:ok, %{status: 429}} ->
        {:error, :throttled}

      {:ok, %{status: status, body: body}} when status in 200..499 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "#{provider} oauth: provider returned HTTP #{status}"}

      {:error, _} ->
        {:error, "#{provider} oauth: provider request failed"}
    end
  end

  defp base_options,
    do:
      [
        receive_timeout: 15_000,
        retry: false,
        redirect: false,
        headers: [{"accept", "application/json"}]
      ] ++ SystemsRuntime.get_env(:salix_store, :lark_device_http_options, [])

  defp client(app) do
    if Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]),
      do: {:error, "oauth: client credentials are required"},
      else: :ok
  end

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
