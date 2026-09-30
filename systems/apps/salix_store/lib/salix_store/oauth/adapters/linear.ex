defmodule SalixStore.OAuth.Adapters.Linear do
  @moduledoc """
  Linear OAuth2 adapter. Port of willow's `internal/oauth/linear.go`
  (`LinearAdapter`).

  Endpoints (overridable via `:oauth_endpoint_overrides` under `"linear"`):

    * `"authorize_url"` — `https://linear.app/oauth/authorize`
    * `"token_url"`     — `https://api.linear.app/oauth/token`
    * `"revoke_url"`    — `https://api.linear.app/oauth/revoke`
    * `"api_url"`       — `https://api.linear.app/graphql` (viewer/organization query)

  Behavior ported from the Go source:

    * Authorization URL: comma-joined `scope` (default `read` when none),
      `prompt=consent`, PKCE S256 challenge when provided.
    * Token responses may carry scopes as a `scopes` array or a comma- or space-separated
      `scope` string; the array wins when non-empty.
    * Account metadata comes from a GraphQL `viewer`/`organization` query;
      organization id/name are the primary account identity with viewer
      fallback, and `metadata.actor` is `"user"`.
    * Refresh requires a refresh token (error when absent).
    * Revoke posts the access token with a bearer header; 400/401 (already
      invalid) count as success.

  Divergences: see `SalixStore.OAuth.Adapter` (ms expiry, nil-for-missing,
  in-adapter invalid_grant classification, precomputed code_challenge).
  """

  @behaviour SalixStore.OAuth.Adapter

  alias SalixStore.OAuth.Adapter

  @label "linear oauth"

  defp authorize_url,
    do: Adapter.endpoint("linear", "authorize_url", "https://linear.app/oauth/authorize")

  defp token_url,
    do: Adapter.endpoint("linear", "token_url", "https://api.linear.app/oauth/token")

  defp revoke_url,
    do: Adapter.endpoint("linear", "revoke_url", "https://api.linear.app/oauth/revoke")

  defp graphql_url, do: Adapter.endpoint("linear", "api_url", "https://api.linear.app/graphql")

  @impl true
  def default_env_var, do: "LINEAR_ACCESS_TOKEN"

  @impl true
  def authorization_url(app, req) do
    cond do
      Adapter.blank?(app["client_id"]) ->
        {:error, "#{@label}: client_id is required"}

      Adapter.blank?(req["redirect_uri"]) ->
        {:error, "#{@label}: redirect_uri is required"}

      true ->
        scopes = req["scopes"] || []
        scope = if scopes == [], do: "read", else: Enum.join(scopes, ",")

        q =
          [
            {"client_id", app["client_id"]},
            {"redirect_uri", req["redirect_uri"]},
            {"response_type", "code"},
            {"state", req["state"] || ""},
            {"scope", scope},
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
          {:ok, parsed} -> {:ok, tokens_from_response(parsed)}
          {:error, msg} -> Adapter.refresh_error(msg)
        end
    end
  end

  @impl true
  def revoke(_app, conn) do
    if not is_map(conn) or Adapter.blank?(conn["access_token"]) do
      :ok
    else
      case Adapter.post_form_status(
             revoke_url(),
             [{"token", conn["access_token"]}],
             "linear token revocation",
             auth: {:bearer, conn["access_token"]}
           ) do
        {:ok, status} when status >= 200 and status < 300 -> :ok
        # Treat token-already-invalid as success.
        {:ok, status} when status in [400, 401] -> :ok
        {:ok, status} -> {:error, "linear token revocation: status #{status}"}
        {:error, msg} -> {:error, msg}
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
    case Adapter.post_form(token_url(), form, "linear token") do
      {:ok, status, parsed} ->
        err = Adapter.trim(parsed["error"])

        cond do
          err != "" ->
            msg =
              if Adapter.blank?(parsed["error_description"]),
                do: err,
                else: parsed["error_description"]

            {:error, "linear token error: #{msg}"}

          Adapter.blank?(parsed["access_token"]) ->
            {:error, "linear token response missing access_token (status #{status})"}

          true ->
            {:ok, parsed}
        end

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp tokens_from_response(parsed) do
    scopes =
      case parsed["scopes"] do
        list when is_list(list) and list != [] -> list
        _ -> Adapter.split_scopes(parsed["scope"], ~r/[\s,]+/)
      end

    %{
      "access_token" => parsed["access_token"],
      "refresh_token" => presence(parsed["refresh_token"]),
      "token_type" => parsed["token_type"],
      "scopes" => scopes,
      "expires_at" => Adapter.expires_at_ms(parsed["expires_in"]),
      "refresh_expires_at" => nil
    }
  end

  defp load_account_metadata(access_token) do
    query = "query { viewer { id name email } organization { id name urlKey } }"

    case Adapter.post_json(graphql_url(), %{"query" => query}, "linear viewer query",
           auth: {:bearer, access_token}
         ) do
      {:ok, _status, parsed} ->
        viewer = get_in(parsed, ["data", "viewer"]) || %{}
        org = get_in(parsed, ["data", "organization"]) || %{}

        account_id = first_present([org["id"], viewer["id"]])
        account_name = first_present([org["name"], viewer["name"]])

        {:ok,
         %{
           "provider_account_id" => account_id,
           "provider_account_name" => account_name,
           "metadata" => %{
             "workspace_id" => org["id"],
             "workspace_name" => org["name"],
             "url_key" => org["urlKey"],
             "viewer_id" => viewer["id"],
             "viewer_name" => viewer["name"],
             "actor" => "user"
           }
         }}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp first_present(values), do: Enum.find(values, "", &(!Adapter.blank?(&1)))

  defp presence(s) when is_binary(s) and s != "", do: s
  defp presence(_), do: nil
end
