defmodule SalixStore.OAuth.Adapters.Notion do
  @moduledoc """
  Notion OAuth2 adapter for public integrations. Port of willow's
  `internal/oauth/notion.go` (`NotionAdapter`).

  Endpoints (overridable via `:oauth_endpoint_overrides` under `"notion"`):

    * `"authorize_url"` — `https://api.notion.com/v1/oauth/authorize`
    * `"token_url"`     — `https://api.notion.com/v1/oauth/token`

  Behavior ported from the Go source:

    * Authorization URL: `response_type=code`, `owner=user`, no scope
      parameter (Notion has no scope model in the authorize URL), no PKCE.
    * Token exchange posts a JSON body with HTTP Basic auth
      (`client_id:client_secret`). The token response carries workspace/bot
      identity inline — no separate user-info fetch; `workspace_id`/`name`
      fall back to `bot_id`.
    * Tokens carry no scopes and no expiry (long-lived). When the connection
      has no refresh token there is nothing to refresh and the current token
      is returned unchanged; integrations that do return a `refresh_token`
      rotate via `grant_type=refresh_token`.
    * Revoke: Notion exposes no usable revocation endpoint (willow returns
      `ErrNoOpToken`; here `{:error, :revocation_not_supported}`).

  Divergences: see `SalixStore.OAuth.Adapter` (nil-for-missing, in-adapter
  invalid_grant classification, revoke sentinel).
  """

  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  @label "notion oauth"

  defp authorize_url,
    do: Adapter.endpoint("notion", "authorize_url", "https://api.notion.com/v1/oauth/authorize")

  defp token_url,
    do: Adapter.endpoint("notion", "token_url", "https://api.notion.com/v1/oauth/token")

  @impl true
  def default_env_var, do: "NOTION_TOKEN"

  @impl true
  def authorization_url(app, req) do
    cond do
      Adapter.blank?(app["client_id"]) ->
        {:error, "#{@label}: client_id is required"}

      Adapter.blank?(req["redirect_uri"]) ->
        {:error, "#{@label}: redirect_uri is required"}

      true ->
        q = [
          {"client_id", app["client_id"]},
          {"redirect_uri", req["redirect_uri"]},
          {"response_type", "code"},
          {"owner", "user"},
          {"state", req["state"] || ""}
        ]

        {:ok, "#{authorize_url()}?#{Adapter.encode_query(q)}"}
    end
  end

  @impl true
  def exchange_code(app, ctx, code) do
    if Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]) do
      {:error, "#{@label}: missing client credentials"}
    else
      body = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => ctx["redirect_uri"] || ""
      }

      case post_token(app, body) do
        {:ok, parsed} ->
          account_id = first_present([parsed["workspace_id"], parsed["bot_id"]])
          account_name = first_present([parsed["workspace_name"], parsed["bot_id"]])

          {:ok,
           %{
             "tokens" => tokens_from_response(parsed),
             "account" => %{
               "provider_account_id" => account_id,
               "provider_account_name" => account_name,
               "metadata" => %{
                 "workspace_id" => parsed["workspace_id"],
                 "workspace_name" => parsed["workspace_name"],
                 "workspace_icon" => parsed["workspace_icon"],
                 "bot_id" => parsed["bot_id"],
                 "owner" => parsed["owner"]
               }
             }
           }}

        {:error, msg} ->
          {:error, msg}
      end
    end
  end

  @impl true
  def refresh(app, conn) do
    cond do
      not is_map(conn) ->
        {:error, "#{@label}: connection is nil"}

      Adapter.blank?(conn["refresh_token"]) ->
        # Public integrations issue long-lived tokens; nothing to refresh.
        {:ok, Adapter.passthrough_tokens(conn)}

      Adapter.blank?(app["client_id"]) or Adapter.blank?(app["client_secret"]) ->
        {:error, "#{@label}: missing client credentials"}

      true ->
        body = %{"grant_type" => "refresh_token", "refresh_token" => conn["refresh_token"]}

        case post_token(app, body) do
          {:ok, parsed} -> {:ok, tokens_from_response(parsed)}
          {:error, msg} -> Adapter.refresh_error(msg)
        end
    end
  end

  @impl true
  def revoke(_app, _conn) do
    # Willow returns ErrNoOpToken: Notion does not expose a revocation
    # endpoint usable across integration types; the binding deletion path
    # drops the stored row.
    {:error, :revocation_not_supported}
  end

  @impl true
  def validate_credential_value(value, scopes),
    do: Adapter.validate_access_token(value, scopes, @label)

  @impl true
  def resolve_credential_value(conn, value),
    do: Adapter.resolve_access_token(conn, value, @label)

  # ---- internals ----

  defp post_token(app, body) do
    case Adapter.post_json(token_url(), body, "notion token",
           auth: {:basic, "#{app["client_id"]}:#{app["client_secret"]}"}
         ) do
      {:ok, status, parsed} ->
        err = Adapter.trim(parsed["error"])

        cond do
          err != "" ->
            msg =
              if Adapter.blank?(parsed["error_description"]),
                do: err,
                else: parsed["error_description"]

            {:error, "notion token error: #{msg}"}

          Adapter.blank?(parsed["access_token"]) ->
            {:error, "notion token response missing access_token (status #{status})"}

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
      "scopes" => [],
      "expires_at" => nil,
      "refresh_expires_at" => nil
    }
  end

  defp first_present(values), do: Enum.find(values, "", &(!Adapter.blank?(&1))) |> Adapter.trim()

  defp presence(s) when is_binary(s) and s != "", do: s
  defp presence(_), do: nil
end
