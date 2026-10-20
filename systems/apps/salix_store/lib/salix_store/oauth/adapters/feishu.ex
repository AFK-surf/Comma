defmodule SalixStore.OAuth.Adapters.Feishu do
  @moduledoc """
  Feishu (`open.feishu.cn`) user sign-in: OAuth 2.0 with PKCE and refresh
  through Feishu's `/authen/v2/oauth/token`. The provider app is the
  organization's Feishu app; its App ID and App Secret are the client
  credentials.

  A sign-in lets the bot of a Feishu connect read as that person what Feishu
  shows only to people: meetings, meeting notes, Minutes recordings and
  documents (`SalixIM.Provider.Feishu.Meetings`). `offline_access` makes
  Feishu return a refresh token. Feishu has no revocation endpoint.
  """
  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  # The names follow the official larksuite/cli (`vc +search`, `vc +notes`,
  # `note`, `minutes`, `doc`); a scope the app does not offer as a user scope
  # makes the sign-in page refuse the whole request.
  @default_scopes ~w(
    vc:meeting.search:read
    vc:meeting.meetingevent:read
    vc:record:readonly
    vc:note:read
    minutes:minutes:readonly
    minutes:minutes.basic:read
    minutes:minutes.artifacts:read
    minutes:minutes.search:read
    minutes:minutes.media:export
    docx:document:readonly
    wiki:node:read
    docs:document.comment:read
    docs:document.media:download
    docs:permission.member:retrieve
    docs:permission.setting:read
    offline_access
  )

  @doc "The scopes a sign-in asks for. The app needs each as a user scope."
  @spec default_scopes() :: [String.t()]
  def default_scopes, do: @default_scopes

  @impl true
  def default_env_var, do: "FEISHU_USER_ACCESS_TOKEN"

  @impl true
  def authorization_url(app, req) do
    if Enum.any?(
         [app["client_id"], req["redirect_uri"], req["code_challenge"]],
         &Adapter.blank?/1
       ) do
      {:error, "feishu oauth: client_id, redirect_uri, and PKCE challenge are required"}
    else
      scopes = if req["scopes"] in [nil, []], do: @default_scopes, else: req["scopes"]

      query =
        Adapter.encode_query([
          {"client_id", app["client_id"]},
          {"redirect_uri", req["redirect_uri"]},
          {"state", req["state"] || ""},
          {"scope", Enum.join(scopes, " ")},
          {"code_challenge", req["code_challenge"]},
          {"code_challenge_method", "S256"}
        ])

      {:ok,
       endpoint("authorize_url", "https://accounts.feishu.cn/open-apis/authen/v1/authorize") <>
         "?" <> query}
    end
  end

  @impl true
  def exchange_code(app, ctx, code) do
    if Adapter.blank?(ctx["code_verifier"]) do
      {:error, "feishu oauth: PKCE verifier is required"}
    else
      with {:ok, parsed} <-
             token_request(app, %{
               "grant_type" => "authorization_code",
               "code" => code,
               "redirect_uri" => ctx["redirect_uri"],
               "code_verifier" => ctx["code_verifier"]
             }),
           {:ok, account} <- account(parsed["access_token"]) do
        {:ok, %{"tokens" => tokens(parsed), "account" => account}}
      end
    end
  end

  @impl true
  def refresh(app, conn) do
    if Adapter.blank?(conn["refresh_token"]) do
      {:error, :reauthorization_required}
    else
      with {:ok, parsed} <-
             token_request(app, %{
               "grant_type" => "refresh_token",
               "refresh_token" => conn["refresh_token"]
             }) do
        refreshed = tokens(parsed)

        {:ok,
         refreshed
         |> Map.put("refresh_token", parsed["refresh_token"] || conn["refresh_token"])
         |> Map.put(
           "refresh_expires_at",
           refreshed["refresh_expires_at"] || conn["refresh_expires_at"]
         )
         |> Map.put(
           "scopes",
           if(Adapter.blank?(parsed["scope"]),
             do: conn["scopes"] || [],
             else: refreshed["scopes"]
           )
         )}
      end
    end
  end

  @impl true
  def revoke(_app, _conn), do: {:error, :revocation_not_supported}

  @impl true
  def validate_credential_value(value, scopes),
    do: Adapter.validate_access_token(value, scopes, "feishu oauth")

  @impl true
  def resolve_credential_value(conn, value),
    do: Adapter.resolve_access_token(conn, value, "feishu oauth")

  defp token_request(app, body) do
    if Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]) do
      {:error, "feishu oauth: client credentials are required"}
    else
      body =
        Map.merge(body, %{
          "client_id" => app["client_id"],
          "client_secret" => app["client_secret"]
        })

      with {:ok, parsed} <-
             request(:post, endpoint("token_url", api("/authen/v2/oauth/token")), json: body) do
        if Adapter.blank?(parsed["access_token"]),
          do: {:error, "feishu oauth: token response missing access_token"},
          else: {:ok, parsed}
      end
    end
  end

  defp account(access_token) do
    case request(:get, endpoint("api_url", api("/authen/v1/user_info")),
           auth: {:bearer, access_token}
         ) do
      {:ok, %{"data" => %{"open_id" => open_id} = user}}
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

      {:error, _} = error ->
        error

      _ ->
        {:error, "feishu oauth: user info response missing open_id"}
    end
  end

  defp tokens(parsed),
    do: %{
      "access_token" => parsed["access_token"],
      "refresh_token" => parsed["refresh_token"],
      "token_type" => parsed["token_type"] || "Bearer",
      "scopes" => Adapter.split_scopes(parsed["scope"], ~r/\s+/),
      "expires_at" => Adapter.expires_at_ms(parsed["expires_in"]),
      "refresh_expires_at" => Adapter.expires_at_ms(parsed["refresh_token_expires_in"])
    }

  # Feishu answers with `code` 0 on success. A refused grant (an expired,
  # revoked or used code or refresh token) is `invalid_grant`. Provider bodies
  # and transport exceptions can contain credentials; return only safe
  # classifications.
  defp request(method, url, opts) do
    case Req.request(
           [
             method: method,
             url: url,
             receive_timeout: 15_000,
             retry: false,
             redirect: false,
             headers: [{"accept", "application/json"}]
           ] ++ opts
         ) do
      {:ok, %{status: status, body: %{"code" => 0} = body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{body: %{"error" => "invalid_grant"}}} ->
        {:error, :reauthorization_required}

      {:ok, %{status: status, body: %{"code" => code}}} ->
        {:error, "feishu oauth: provider returned HTTP #{status} code #{code}"}

      {:ok, %{status: status}} ->
        {:error, "feishu oauth: provider returned HTTP #{status}"}

      {:error, _} ->
        {:error, "feishu oauth: provider request failed"}
    end
  end

  defp api(path), do: "https://open.feishu.cn/open-apis" <> path

  defp endpoint(key, fallback), do: Adapter.endpoint("feishu", key, fallback)
end
