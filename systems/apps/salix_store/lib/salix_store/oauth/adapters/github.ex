defmodule SalixStore.OAuth.Adapters.GitHub do
  @moduledoc """
  GitHub OAuth adapter. Port of willow's `internal/oauth/github.go`
  (`GitHubAdapter`): OAuth Apps and GitHub Apps with user-to-server tokens.
  Only github.com is supported; GitHub Enterprise is intentionally out of scope.

  Endpoints (overridable via `:oauth_endpoint_overrides` under `"github"`):

    * `"authorize_url"` — `https://github.com/login/oauth/authorize`
    * `"token_url"`     — `https://github.com/login/oauth/access_token`
    * `"api_url"`       — `https://api.github.com` (user metadata at `/user`)

  Behavior ported from the Go source:

    * Authorization URL: `client_id`, `redirect_uri`, `state`, space-joined
      `scope` (only when scopes present), `allow_signup=false`. No PKCE — the
      Go adapter ignores `CodeVerifier`, so `"code_challenge"` is ignored here.
    * Token exchange posts a form with body credentials; scopes split on `,`.
    * Refresh: classic OAuth Apps have no refresh token — the existing
      non-expiring access token is returned unchanged. GitHub Apps rotate via
      `grant_type=refresh_token` and report `refresh_token_expires_in`.
    * Revoke: no-op — there is no public revocation usable for both app types
      (willow returns `ErrNoOpToken`; here `{:error, :revocation_not_supported}`).

  Divergences: see `SalixStore.OAuth.Adapter` (ms expiry, nil-for-missing,
  in-adapter invalid_grant classification, revoke sentinel).
  """

  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  @label "github oauth"

  defp authorize_url,
    do: Adapter.endpoint("github", "authorize_url", "https://github.com/login/oauth/authorize")

  defp token_url,
    do: Adapter.endpoint("github", "token_url", "https://github.com/login/oauth/access_token")

  defp api_url, do: Adapter.endpoint("github", "api_url", "https://api.github.com")

  @impl true
  def default_env_var, do: "GH_TOKEN"

  @impl true
  def authorization_url(app, req) do
    cond do
      Adapter.blank?(app["client_id"]) ->
        {:error, "#{@label}: client_id is required"}

      Adapter.blank?(req["redirect_uri"]) ->
        {:error, "#{@label}: redirect_uri is required"}

      true ->
        scopes = req["scopes"] || []

        q =
          [
            {"client_id", app["client_id"]},
            {"redirect_uri", req["redirect_uri"]},
            {"state", req["state"] || ""},
            {"allow_signup", "false"}
          ] ++ if(scopes != [], do: [{"scope", Enum.join(scopes, " ")}], else: [])

        {:ok, "#{authorize_url()}?#{Adapter.encode_query(q)}"}
    end
  end

  @impl true
  def exchange_code(app, ctx, code) do
    if Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]) do
      {:error, "#{@label}: missing client credentials"}
    else
      form = [
        {"client_id", app["client_id"]},
        {"client_secret", app["client_secret"]},
        {"code", code},
        {"redirect_uri", ctx["redirect_uri"] || ""}
      ]

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

      Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]) ->
        {:error, "#{@label}: missing client credentials"}

      Adapter.blank?(conn["refresh_token"]) ->
        # Classic OAuth Apps issue non-expiring tokens; return what we have.
        {:ok, Adapter.passthrough_tokens(conn)}

      true ->
        form = [
          {"client_id", app["client_id"]},
          {"client_secret", app["client_secret"]},
          {"grant_type", "refresh_token"},
          {"refresh_token", conn["refresh_token"]}
        ]

        case post_token_form(form) do
          {:ok, parsed} -> {:ok, tokens_from_response(parsed)}
          {:error, msg} -> Adapter.refresh_error(msg)
        end
    end
  end

  @impl true
  def revoke(_app, _conn) do
    # Willow returns ErrNoOpToken: no public revocation works for both OAuth
    # Apps and GitHub Apps; the binding deletion path drops the stored row.
    {:error, :revocation_not_supported}
  end

  @impl true
  def validate_credential_value(value, scopes),
    do: Adapter.validate_access_token(value, scopes, @label)

  @impl true
  def resolve_credential_value(conn, value),
    do: Adapter.resolve_access_token(conn, value, @label)

  # ---- internals ----

  defp post_token_form(form) do
    case Adapter.post_form(token_url(), form, "github token") do
      {:ok, status, parsed} ->
        err = Adapter.trim(parsed["error"])

        cond do
          err != "" ->
            msg =
              if Adapter.blank?(parsed["error_description"]),
                do: err,
                else: parsed["error_description"]

            {:error, "github token error: #{msg}"}

          Adapter.blank?(parsed["access_token"]) ->
            {:error, "github token response missing access_token (status #{status})"}

          true ->
            {:ok, parsed}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp tokens_from_response(parsed) do
    now = System.system_time(:millisecond)

    %{
      "access_token" => parsed["access_token"],
      "refresh_token" => presence(parsed["refresh_token"]),
      "token_type" => parsed["token_type"],
      "scopes" => Adapter.split_scopes(parsed["scope"], ","),
      "expires_at" => Adapter.expires_at_ms(parsed["expires_in"], now),
      "refresh_expires_at" => Adapter.expires_at_ms(parsed["refresh_token_expires_in"], now)
    }
  end

  defp load_account_metadata(access_token) do
    case Adapter.get_json("#{api_url()}/user", access_token, "github user",
           accept: "application/vnd.github+json"
         ) do
      {:ok, status, user} ->
        if Adapter.blank?(user["login"]) do
          {:error, "github user response missing login (status #{status})"}
        else
          metadata = %{"login" => user["login"], "user_id" => user["id"]}

          metadata =
            if Adapter.blank?(user["name"]),
              do: metadata,
              else: Map.put(metadata, "name", user["name"])

          {:ok,
           %{
             "provider_account_id" => to_string(user["id"]),
             "provider_account_name" => user["login"],
             "metadata" => metadata
           }}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp presence(s) when is_binary(s) and s != "", do: s
  defp presence(_), do: nil
end
