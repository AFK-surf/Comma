defmodule SalixStore.OAuth.Adapters.Google do
  @moduledoc """
  Google OAuth 2.0 / OpenID Connect adapter. Port of willow's
  `internal/oauth/google.go` (`GoogleAdapter`): web-server applications acting
  on behalf of the authorizing user; service-account flows are out of scope.

  Endpoints (overridable via `:oauth_endpoint_overrides` under `"google"`):

    * `"authorize_url"` — `https://accounts.google.com/o/oauth2/v2/auth`
    * `"token_url"`     — `https://oauth2.googleapis.com/token`
    * `"revoke_url"`    — `https://oauth2.googleapis.com/revoke`
    * `"api_url"`       — `https://openidconnect.googleapis.com/v1/userinfo`

  Behavior ported from the Go source:

    * Authorization URL sets `access_type=offline`, `include_granted_scopes=true`,
      and `prompt=consent` so a refresh token is issued on every authorization.
      Requested scopes are merged with the OpenID minimum
      (`openid email profile`, required-first, de-duplicated). PKCE S256
      challenge included when provided.
    * Token errors keep the provider error code first
      (`"google token error: <code>: <description>"`) so the invalid_grant
      classifier can see `invalid_grant`.
    * Refresh: requires a refresh token. Google omits `refresh_token` from
      refresh responses — the existing one is kept; empty scopes also fall back
      to the connection's.
    * Revoke: prefers the refresh token (invalidates derived access tokens),
      falls back to the access token; 400/401 (already invalid) count as success.

  Divergences: see `SalixStore.OAuth.Adapter` (ms expiry, nil-for-missing,
  in-adapter invalid_grant classification, precomputed code_challenge).
  """

  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  @label "google oauth"
  @required_scopes ["openid", "email", "profile"]

  defp authorize_url,
    do:
      Adapter.endpoint("google", "authorize_url", "https://accounts.google.com/o/oauth2/v2/auth")

  defp token_url,
    do: Adapter.endpoint("google", "token_url", "https://oauth2.googleapis.com/token")

  defp revoke_url,
    do: Adapter.endpoint("google", "revoke_url", "https://oauth2.googleapis.com/revoke")

  defp user_url,
    do: Adapter.endpoint("google", "api_url", "https://openidconnect.googleapis.com/v1/userinfo")

  @impl true
  def default_env_var, do: "GOOGLE_ACCESS_TOKEN"

  @impl true
  def authorization_url(app, req) do
    cond do
      Adapter.blank?(app["client_id"]) ->
        {:error, "#{@label}: client_id is required"}

      Adapter.blank?(req["redirect_uri"]) ->
        {:error, "#{@label}: redirect_uri is required"}

      true ->
        scopes = merge_scopes(req["scopes"] || [])

        q =
          [
            {"client_id", app["client_id"]},
            {"redirect_uri", req["redirect_uri"]},
            {"response_type", "code"},
            {"state", req["state"] || ""},
            {"scope", Enum.join(scopes, " ")},
            {"access_type", "offline"},
            {"include_granted_scopes", "true"},
            {"prompt", "consent"}
          ] ++ challenge_params(req["code_challenge"])

        {:ok, "#{authorize_url()}?#{Adapter.encode_query(q)}"}
    end
  end

  @impl true
  def exchange_code(app, ctx, code) do
    if Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]) do
      {:error, "#{@label}: missing client credentials"}
    else
      form =
        [
          {"client_id", app["client_id"]},
          {"client_secret", app["client_secret"]},
          {"redirect_uri", ctx["redirect_uri"] || ""},
          {"grant_type", "authorization_code"},
          {"code", code}
        ] ++
          if(Adapter.blank?(ctx["code_verifier"]),
            do: [],
            else: [{"code_verifier", ctx["code_verifier"]}]
          )

      with {:ok, parsed} <- post_token_form(form),
           tokens = tokens_from_response(parsed),
           {:ok, account} <- load_account_metadata(tokens["access_token"]) do
        {:ok, %{"tokens" => tokens, "account" => account}}
      end
    end
  end

  @impl true
  def refresh(app, conn) do
    cond do
      not is_map(conn) ->
        {:error, "#{@label}: connection is nil"}

      Adapter.blank?(conn["refresh_token"]) ->
        {:error, "#{@label}: connection has no refresh token"}

      Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]) ->
        {:error, "#{@label}: missing client credentials"}

      true ->
        form = [
          {"client_id", app["client_id"]},
          {"client_secret", app["client_secret"]},
          {"grant_type", "refresh_token"},
          {"refresh_token", conn["refresh_token"]}
        ]

        case post_token_form(form) do
          {:ok, parsed} ->
            tokens = tokens_from_response(parsed)

            # Google omits refresh_token from refresh responses; keep the
            # existing one so the connection stays refreshable.
            tokens =
              if tokens["refresh_token"] == nil,
                do: Map.put(tokens, "refresh_token", conn["refresh_token"]),
                else: tokens

            tokens =
              if tokens["scopes"] == [],
                do: Map.put(tokens, "scopes", conn["scopes"] || []),
                else: tokens

            {:ok, tokens}

          {:error, msg} ->
            Adapter.refresh_error(msg)
        end
    end
  end

  @impl true
  def revoke(_app, conn) do
    if not is_map(conn) do
      :ok
    else
      # Prefer revoking the refresh token (this also invalidates derived
      # access tokens). Fall back to the access token.
      token =
        case Adapter.trim(conn["refresh_token"]) do
          "" -> Adapter.trim(conn["access_token"])
          t -> t
        end

      if token == "" do
        :ok
      else
        case Adapter.post_form_status(revoke_url(), [{"token", token}], "google token revocation") do
          {:ok, status} when status >= 200 and status < 300 -> :ok
          # Google returns 400 with `invalid_token` for already-revoked tokens.
          {:ok, status} when status in [400, 401] -> :ok
          {:ok, status} -> {:error, "google token revocation: status #{status}"}
          {:error, msg} -> {:error, msg}
        end
      end
    end
  end

  @impl true
  def validate_credential_value(value, scopes),
    do: Adapter.validate_access_token(value, scopes, @label)

  @impl true
  def resolve_credential_value(conn, value),
    do: Adapter.resolve_access_token(conn, value, @label)

  # ---- internals ----

  defp challenge_params(challenge) do
    if Adapter.blank?(challenge) do
      []
    else
      [{"code_challenge", challenge}, {"code_challenge_method", "S256"}]
    end
  end

  defp post_token_form(form) do
    case Adapter.post_form(token_url(), form, "google token") do
      {:ok, status, parsed} ->
        err = Adapter.trim(parsed["error"])

        cond do
          err != "" ->
            # Keep the provider error code first so the invalid_grant
            # classifier (substring match) can see it.
            msg =
              if Adapter.blank?(parsed["error_description"]),
                do: err,
                else: "#{err}: #{parsed["error_description"]}"

            {:error, "google token error: #{msg}"}

          Adapter.blank?(parsed["access_token"]) ->
            {:error, "google token response missing access_token (status #{status})"}

          true ->
            {:ok, parsed}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp tokens_from_response(parsed) do
    %{
      "access_token" => parsed["access_token"],
      "refresh_token" => presence(parsed["refresh_token"]),
      "token_type" => parsed["token_type"],
      "scopes" => Adapter.split_scopes(parsed["scope"], " "),
      "expires_at" => Adapter.expires_at_ms(parsed["expires_in"]),
      "refresh_expires_at" => nil
    }
  end

  defp load_account_metadata(access_token) do
    case Adapter.get_json(user_url(), access_token, "google userinfo") do
      {:ok, status, user} ->
        if Adapter.blank?(user["sub"]) do
          {:error, "google userinfo response missing sub (status #{status})"}
        else
          display_name =
            Enum.find([user["email"], user["name"], user["sub"]], &(!Adapter.blank?(&1)))

          metadata = %{
            "sub" => user["sub"],
            "email" => user["email"],
            "email_verified" => user["email_verified"]
          }

          metadata =
            metadata
            |> put_unless_blank("name", user["name"])
            |> put_unless_blank("picture", user["picture"])
            |> put_unless_blank("hosted_domain", user["hd"])

          {:ok,
           %{
             "provider_account_id" => user["sub"],
             "provider_account_name" => display_name,
             "metadata" => metadata
           }}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp put_unless_blank(map, _key, value) when value in [nil, ""], do: map
  defp put_unless_blank(map, key, value), do: Map.put(map, key, value)

  # Willow mergeGoogleScopes: required OpenID scopes first, then caller scopes
  # preserved verbatim and de-duplicated.
  defp merge_scopes(requested) do
    requested
    |> Enum.map(&Adapter.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> then(&(@required_scopes ++ &1))
    |> Enum.uniq()
  end

  defp presence(s) when is_binary(s) and s != "", do: s
  defp presence(_), do: nil
end
