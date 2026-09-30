defmodule SalixStore.OAuth.Adapters.Slack do
  @moduledoc """
  Slack OAuth v2 adapter for user-on-behalf-of integrations. Port of willow's
  `internal/oauth/slack.go` (`SlackAdapter`). Requested scopes are passed to
  Slack as `user_scope`, and the access token we store is the **user token**
  (`xoxp-…`) returned under `authed_user`. Bot tokens are intentionally out of
  scope: agents act as the authorizing user, not as a bot identity.

  Endpoints (overridable via `:oauth_endpoint_overrides` under `"slack"`):

    * `"authorize_url"` — `https://slack.com/oauth/v2/authorize`
    * `"token_url"`     — `https://slack.com/api/oauth.v2.access`
    * `"revoke_url"`    — `https://slack.com/api/auth.revoke`

  Behavior ported from the Go source:

    * Authorization URL: cleaned scopes joined with `,` as `user_scope` (param
      omitted when no scopes). No PKCE.
    * Slack returns HTTP 200 with `ok: false` on failure; the `error` field is
      the message.
    * Exchange lifts `authed_user.access_token` (the xoxp user token) into the
      primary `access_token` slot; a missing user token errors with the
      "ensure user_scope was requested" message. Account name shows
      `"<user_id> · <team_name>"` when a team name is present; enterprise
      id/name are added to metadata when set.
    * Refresh (token rotation): responses put the rotated token at the **top
      level**, not under `authed_user`. Apps without rotation never store a
      refresh token — the existing non-expiring token is returned unchanged.
    * Revoke posts the user token to `auth.revoke` with a bearer header;
      `token_revoked` / `invalid_auth` / `not_authed` count as success.

  Divergences: see `SalixStore.OAuth.Adapter` (ms expiry, nil-for-missing,
  in-adapter invalid_grant classification), plus:

    * Token sets carry the provider extra `"slack_user_token"` (same xoxp value
      as `"access_token"`) so stored connections are self-describing;
      `resolve_credential_value/2` prefers `"slack_user_token"` and falls back
      to `"access_token"`. Willow has a single AccessToken slot.
  """

  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  @label "slack oauth"

  defp authorize_url,
    do: Adapter.endpoint("slack", "authorize_url", "https://slack.com/oauth/v2/authorize")

  defp token_url,
    do: Adapter.endpoint("slack", "token_url", "https://slack.com/api/oauth.v2.access")

  defp revoke_url,
    do: Adapter.endpoint("slack", "revoke_url", "https://slack.com/api/auth.revoke")

  @impl true
  def default_env_var, do: "SLACK_USER_TOKEN"

  @impl true
  def authorization_url(app, req) do
    cond do
      Adapter.blank?(app["client_id"]) ->
        {:error, "#{@label}: client_id is required"}

      Adapter.blank?(req["redirect_uri"]) ->
        {:error, "#{@label}: redirect_uri is required"}

      true ->
        cleaned =
          (req["scopes"] || [])
          |> Enum.map(&Adapter.trim/1)
          |> Enum.reject(&(&1 == ""))

        q =
          [
            {"client_id", app["client_id"]},
            {"redirect_uri", req["redirect_uri"]},
            {"state", req["state"] || ""}
          ] ++ if(cleaned != [], do: [{"user_scope", Enum.join(cleaned, ",")}], else: [])

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
        {"redirect_uri", ctx["redirect_uri"] || ""},
        {"code", code}
      ]

      with {:ok, parsed} <- post_token_form(form) do
        authed = parsed["authed_user"] || %{}

        if Adapter.blank?(authed["access_token"]) do
          {:error,
           "#{@label}: response missing user access token; ensure user_scope was requested"}
        else
          tokens = %{
            "access_token" => authed["access_token"],
            "refresh_token" => presence(authed["refresh_token"]),
            "token_type" => authed["token_type"],
            "scopes" => Adapter.split_scopes(authed["scope"], ","),
            "expires_at" => Adapter.expires_at_ms(authed["expires_in"]),
            "refresh_expires_at" => nil,
            "slack_user_token" => authed["access_token"]
          }

          {:ok, %{"tokens" => tokens, "account" => account_from_response(parsed, authed)}}
        end
      end
    end
  end

  @impl true
  def refresh(app, conn) do
    cond do
      not is_map(conn) ->
        {:error, "#{@label}: connection is nil"}

      Adapter.blank?(conn["refresh_token"]) ->
        # Apps without token rotation never store a refresh token; the user
        # token is non-expiring.
        {:ok, Map.put(Adapter.passthrough_tokens(conn), "slack_user_token", conn["access_token"])}

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
            # Refresh responses put the rotated token at the top level rather
            # than under authed_user.
            if Adapter.blank?(parsed["access_token"]) do
              {:error, "slack token refresh response missing access_token"}
            else
              {:ok,
               %{
                 "access_token" => parsed["access_token"],
                 "refresh_token" => presence(parsed["refresh_token"]),
                 "token_type" => parsed["token_type"],
                 "scopes" => Adapter.split_scopes(parsed["scope"], ","),
                 "expires_at" => Adapter.expires_at_ms(parsed["expires_in"]),
                 "refresh_expires_at" => nil,
                 "slack_user_token" => parsed["access_token"]
               }}
            end

          {:error, msg} ->
            Adapter.refresh_error(msg)
        end
    end
  end

  @impl true
  def revoke(_app, conn) do
    if not is_map(conn) or Adapter.blank?(conn["access_token"]) do
      :ok
    else
      case Adapter.post_form(
             revoke_url(),
             [{"token", conn["access_token"]}],
             "slack token revocation",
             auth: {:bearer, conn["access_token"]}
           ) do
        {:ok, _status, %{"ok" => true}} ->
          :ok

        {:ok, _status, parsed} ->
          case parsed["error"] do
            e when e in ["token_revoked", "invalid_auth", "not_authed"] -> :ok
            e -> {:error, "slack token revocation: #{e}"}
          end

        {:error, msg} ->
          {:error, msg}
      end
    end
  end

  @impl true
  def validate_credential_value(value, scopes),
    do: Adapter.validate_access_token(value, scopes, @label)

  @impl true
  def resolve_credential_value(conn, value) do
    cond do
      not is_map(conn) ->
        {:error, "#{@label}: connection is nil"}

      value != Adapter.credential_access_token() ->
        {:error, "#{@label}: unsupported credential value #{inspect(value)}"}

      true ->
        # The stored access token IS the xoxp user token; prefer the explicit
        # extra when present so older records resolve identically.
        {:ok, conn["slack_user_token"] || conn["access_token"]}
    end
  end

  # ---- internals ----

  defp post_token_form(form) do
    case Adapter.post_form(token_url(), form, "slack token") do
      {:ok, status, parsed} ->
        # Slack returns HTTP 200 with `ok: false` on failure.
        if parsed["ok"] == true do
          {:ok, parsed}
        else
          msg =
            case Adapter.trim(parsed["error"]) do
              "" -> "slack token error (status #{status})"
              e -> e
            end

          {:error, "slack token error: #{msg}"}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp account_from_response(parsed, authed) do
    team = parsed["team"] || %{}
    enterprise = parsed["enterprise"] || %{}

    name =
      if Adapter.blank?(team["name"]) do
        authed["id"]
      else
        # Show the workspace alongside the user id when surfacing the
        # connected account. Bindings are still keyed on the user.
        "#{authed["id"]} · #{team["name"]}"
      end

    metadata = %{
      "authed_user_id" => authed["id"],
      "team_id" => team["id"],
      "team_name" => team["name"],
      "app_id" => parsed["app_id"]
    }

    metadata =
      if Adapter.blank?(enterprise["id"]) do
        metadata
      else
        metadata
        |> Map.put("enterprise_id", enterprise["id"])
        |> Map.put("enterprise_name", enterprise["name"])
      end

    %{
      "provider_account_id" => authed["id"],
      "provider_account_name" => name,
      "metadata" => metadata
    }
  end

  defp presence(s) when is_binary(s) and s != "", do: s
  defp presence(_), do: nil
end
