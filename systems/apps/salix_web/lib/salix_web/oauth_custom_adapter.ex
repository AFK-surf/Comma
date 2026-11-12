defmodule SalixWeb.OAuthCustomAdapter do
  @moduledoc """
  A provider a Workspace defines itself (`custom.<key>`): standard OAuth 2.0
  (RFC 6749 with PKCE, and RFC 8628 when the definition has a device
  authorization endpoint). The definition arrives as the provider app
  (`Salix.Control.OAuthApps.put_custom/3`). Its endpoints are the Workspace's to
  choose, so requests go only to public addresses (`SalixMCP.URLPolicy`), and
  provider bodies are not repeated: they can hold credentials.
  """
  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  @impl true
  def default_env_var, do: "OAUTH_TOKEN"

  @impl true
  def authorization_url(app, req) do
    cond do
      Adapter.blank?(app["authorize_url"]) ->
        {:error, "custom oauth: this provider has no authorization endpoint"}

      Adapter.blank?(req["redirect_uri"]) or Adapter.blank?(req["code_challenge"]) ->
        {:error, "custom oauth: redirect_uri and PKCE challenge are required"}

      true ->
        query =
          Adapter.encode_query([
            {"response_type", "code"},
            {"client_id", app["client_id"]},
            {"redirect_uri", req["redirect_uri"]},
            {"state", req["state"] || ""},
            {"scope", Enum.join(scopes(app, req), " ")},
            {"code_challenge", req["code_challenge"]},
            {"code_challenge_method", "S256"}
          ])

        separator = if String.contains?(app["authorize_url"], "?"), do: "&", else: "?"
        {:ok, app["authorize_url"] <> separator <> query}
    end
  end

  @impl true
  def exchange_code(app, ctx, code) do
    with {:ok, tokens} <-
           token_request(app, [
             {"grant_type", "authorization_code"},
             {"code", code},
             {"redirect_uri", ctx["redirect_uri"]},
             {"code_verifier", ctx["code_verifier"]}
           ]) do
      {:ok, %{"tokens" => tokens, "account" => no_account()}}
    end
  end

  @impl true
  def refresh(app, conn) do
    if Adapter.blank?(conn["refresh_token"]) do
      {:error, :reauthorization_required}
    else
      with {:ok, tokens} <-
             token_request(app, [
               {"grant_type", "refresh_token"},
               {"refresh_token", conn["refresh_token"]}
             ]) do
        {:ok, Map.put(tokens, "refresh_token", tokens["refresh_token"] || conn["refresh_token"])}
      end
    end
  end

  @impl true
  def revoke(_app, _conn), do: {:error, :revocation_not_supported}

  @impl true
  def validate_credential_value(value, scopes),
    do: Adapter.validate_access_token(value, scopes, "custom oauth")

  @impl true
  def resolve_credential_value(conn, value),
    do: Adapter.resolve_access_token(conn, value, "custom oauth")

  @doc """
  Starts a device authorization: what to show the person, and the code to poll
  with. The person's confirmation arrives through `device_poll/2`.
  """
  def device_authorize(app, req) do
    if Adapter.blank?(app["device_authorization_url"]) do
      {:error, "custom oauth: this provider has no device authorization endpoint"}
    else
      form = client_form(app, [{"scope", Enum.join(scopes(app, req), " ")}])

      case post(app["device_authorization_url"], form, headers(app)) do
        {:ok, status, %{"device_code" => device_code, "user_code" => user_code} = body}
        when status in 200..299 ->
          {:ok,
           %{
             "device_code" => device_code,
             "user_code" => user_code,
             "verification_uri" => body["verification_uri"] || body["verification_url"],
             "verification_uri_complete" => body["verification_uri_complete"],
             "expires_in" => body["expires_in"]
           }}

        {:ok, status, _body} ->
          {:error, "custom oauth: device authorization returned HTTP #{status}"}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "One poll: `:pending` until the person confirms."
  def device_poll(app, device_code) do
    form = [
      {"grant_type", "urn:ietf:params:oauth:grant-type:device_code"},
      {"device_code", device_code}
    ]

    case post(app["token_url"], client_form(app, form), headers(app)) do
      {:ok, status, %{"access_token" => token} = body}
      when status in 200..299 and is_binary(token) and token != "" ->
        {:ok, %{"tokens" => tokens(body), "account" => no_account()}}

      {:ok, _status, %{"error" => error}} when error in ["authorization_pending", "slow_down"] ->
        :pending

      {:ok, _status, %{"error" => error}} when is_binary(error) ->
        {:error, "custom oauth: " <> error}

      {:ok, status, _body} ->
        {:error, "custom oauth: token endpoint returned HTTP #{status}"}

      {:error, _} = error ->
        error
    end
  end

  defp token_request(app, form) do
    case post(app["token_url"], client_form(app, form), headers(app)) do
      {:ok, status, %{"access_token" => token} = body}
      when status in 200..299 and is_binary(token) and token != "" ->
        {:ok, tokens(body)}

      {:ok, _status, %{"error" => error}} when error in ["invalid_grant", "expired_token"] ->
        {:error, :reauthorization_required}

      {:ok, status, _body} ->
        {:error, "custom oauth: token endpoint returned HTTP #{status}"}

      {:error, _} = error ->
        error
    end
  end

  defp tokens(body) do
    %{
      "access_token" => body["access_token"],
      "refresh_token" => body["refresh_token"],
      "token_type" => body["token_type"] || "Bearer",
      "scopes" => Adapter.split_scopes(body["scope"], ~r/[\s,]+/),
      "expires_at" => Adapter.expires_at_ms(body["expires_in"]),
      "refresh_expires_at" => Adapter.expires_at_ms(body["refresh_token_expires_in"])
    }
  end

  defp no_account, do: %{"provider_account_id" => "", "provider_account_name" => ""}

  defp scopes(app, req) do
    case req["scopes"] do
      [_ | _] = scopes -> scopes
      _ -> app["scopes"] || []
    end
  end

  # `client_auth` basic sends the client in a header; a public client has no secret.
  defp client_form(%{"client_auth" => "basic"}, form), do: form

  defp client_form(app, form) do
    form = [{"client_id", app["client_id"]} | form]

    if Adapter.blank?(app["client_secret"]),
      do: form,
      else: [{"client_secret", app["client_secret"]} | form]
  end

  defp headers(%{"client_auth" => "basic"} = app) do
    [
      {"authorization",
       "Basic " <> Base.encode64(app["client_id"] <> ":" <> (app["client_secret"] || ""))}
    ]
  end

  defp headers(_app), do: []

  defp post(url, form, headers) do
    case SystemsRuntime.get_env(:salix_web, :oauth_custom_http_fn) do
      nil -> post_public(url, form, headers)
      fun -> fun.(url, form, headers)
    end
  end

  defp post_public(url, form, headers) do
    with {:ok, target} <- SalixMCP.URLPolicy.public_http_target(url) do
      case Req.post(target.url,
             form: form,
             headers: [{"accept", "application/json"}, {"host", target.host_header}] ++ headers,
             connect_options: target.connect_options,
             inet6: target.inet6,
             redirect: false,
             retry: false
           ) do
        {:ok, %Req.Response{status: status, body: body}} -> {:ok, status, decoded(body)}
        {:error, _} -> {:error, "custom oauth: provider request failed"}
      end
    else
      {:error, _} -> {:error, "custom oauth: the endpoint is not a public address"}
    end
  end

  defp decoded(%{} = body), do: body

  defp decoded(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _ -> URI.decode_query(body)
    end
  end

  defp decoded(_body), do: %{}
end
