defmodule SalixStore.OAuth.Adapters.X do
  @moduledoc """
  X confidential-client OAuth 2.0 with PKCE, refresh, and revocation.
  Uses the existing managed OAuth adapter contract and Req transport.
  """
  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  @default_scopes ~w(tweet.read tweet.write users.read media.write follows.read follows.write dm.read dm.write bookmark.read bookmark.write offline.access)

  @impl true
  def default_env_var, do: "X_ACCESS_TOKEN"

  @impl true
  def authorization_url(app, req) do
    if Enum.any?(
         [app["client_id"], req["redirect_uri"], req["code_challenge"]],
         &Adapter.blank?/1
       ) do
      {:error, "x oauth: client_id, redirect_uri, and PKCE challenge are required"}
    else
      scopes = if req["scopes"] in [nil, []], do: @default_scopes, else: req["scopes"]

      query =
        Adapter.encode_query([
          {"response_type", "code"},
          {"client_id", app["client_id"]},
          {"redirect_uri", req["redirect_uri"]},
          {"state", req["state"] || ""},
          {"scope", Enum.join(scopes, " ")},
          {"code_challenge", req["code_challenge"]},
          {"code_challenge_method", "S256"}
        ])

      {:ok, endpoint("authorize_url", "https://x.com/i/oauth2/authorize") <> "?" <> query}
    end
  end

  @impl true
  def exchange_code(app, ctx, code) do
    if Adapter.blank?(ctx["code_verifier"]) do
      {:error, "x oauth: PKCE verifier is required"}
    else
      with {:ok, parsed} <-
             token_request(app, [
               {"grant_type", "authorization_code"},
               {"code", code},
               {"redirect_uri", ctx["redirect_uri"]},
               {"code_verifier", ctx["code_verifier"]}
             ]),
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
      case token_request(app, [
             {"grant_type", "refresh_token"},
             {"refresh_token", conn["refresh_token"]}
           ]) do
        {:ok, parsed} ->
          refreshed = tokens(parsed)

          {:ok,
           refreshed
           |> Map.put("refresh_token", parsed["refresh_token"] || conn["refresh_token"])
           |> Map.put(
             "scopes",
             if(Adapter.blank?(parsed["scope"]),
               do: conn["scopes"] || [],
               else: refreshed["scopes"]
             )
           )}

        {:error, _} = error ->
          error
      end
    end
  end

  @impl true
  def revoke(app, conn) do
    if Adapter.blank?(conn["access_token"]) do
      :ok
    else
      with {:ok, auth} <- client_auth(app),
           {:ok, _} <-
             request(:post, endpoint("revoke_url", "https://api.x.com/2/oauth2/revoke"),
               auth: auth,
               form: [{"token", conn["access_token"]}]
             ) do
        :ok
      end
    end
  end

  @impl true
  def validate_credential_value(value, scopes),
    do: Adapter.validate_access_token(value, scopes, "x oauth")

  @impl true
  def resolve_credential_value(conn, value),
    do: Adapter.resolve_access_token(conn, value, "x oauth")

  defp token_request(app, form) do
    with {:ok, auth} <- client_auth(app),
         {:ok, parsed} <-
           request(:post, endpoint("token_url", "https://api.x.com/2/oauth2/token"),
             auth: auth,
             form: form
           ) do
      if Adapter.blank?(parsed["access_token"]),
        do: {:error, "x oauth: token response missing access_token"},
        else: {:ok, parsed}
    end
  end

  defp client_auth(app) do
    if Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]),
      do: {:error, "x oauth: client credentials are required"},
      else: {:ok, {:basic, "#{app["client_id"]}:#{app["client_secret"]}"}}
  end

  defp account(access_token) do
    with {:ok, %{"data" => %{"id" => id} = user}} when is_binary(id) and id != "" <-
           request(:get, endpoint("api_url", "https://api.x.com/2/users/me"),
             auth: {:bearer, access_token}
           ) do
      {:ok,
       %{
         "provider_account_id" => id,
         "provider_account_name" => user["username"] || user["name"] || id,
         "metadata" => %{"username" => user["username"], "name" => user["name"]}
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "x oauth: account response missing user id"}
    end
  end

  defp tokens(parsed),
    do: %{
      "access_token" => parsed["access_token"],
      "refresh_token" => parsed["refresh_token"],
      "token_type" => parsed["token_type"],
      "scopes" => Adapter.split_scopes(parsed["scope"], ~r/\s+/),
      "expires_at" => Adapter.expires_at_ms(parsed["expires_in"]),
      "refresh_expires_at" => nil
    }

  # Provider bodies and transport exceptions can contain credentials. Return only safe classifications.
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
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) -> {:ok, body}
      {:ok, %{body: %{"error" => "invalid_grant"}}} -> {:error, :reauthorization_required}
      {:ok, %{status: status}} -> {:error, "x oauth: provider returned HTTP #{status}"}
      {:error, _} -> {:error, "x oauth: provider request failed"}
    end
  end

  defp endpoint(key, fallback), do: Adapter.endpoint("x", key, fallback)
end
