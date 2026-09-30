defmodule SalixWeb.OAuthFlow do
  @moduledoc """
  OAuth authorization-flow orchestration (port of willow
  `internal/api/oauth.go`: startOAuthAuthorize, handleOAuthCallback,
  finishOAuthCallback, renderOAuthCallbackPage, writeOAuthCallbackError,
  cleanupOrphanedOAuthConnection, deleteGroupOAuthBinding revocation, and
  oauthCallbackURL).

  Flow: `start_authorization/4` builds the provider authorize URL through the
  tenant's provider app + a PKCE verifier and persists a pending
  `SalixStore.OAuth.AuthState` record. `handle_callback/2` is the browser
  redirect target: it atomically consumes the state (replays lose), exchanges
  the code via the provider adapter, persists the connection record
  (`SalixStore.OAuth`), upserts the (group, provider, alias) binding,
  cleans up the orphaned previous connection, records the terminal outcome on
  the auth-state record (agent-origin flows poll it), and either 303-redirects
  back to `redirect_after` or renders willow's self-contained completion page.

  Intentional divergences from willow:

    * The `redirect_uri` registered with the provider is persisted on the
      auth-state record at authorize time and reused at callback time; willow
      recomputes it from `server.api_base_url` on both legs.
    * `SalixWeb.Application.public_base_url/0` always resolves (it falls back
      to the local listener), so willow's 412 "server.api_base_url is not
      configured" path is unreachable here.
    * The 30s exchange / 15s revoke deadlines live inside the adapter HTTP
      clients rather than a per-request context.
    * Connection ids are `"conn-" <> 16-byte-hex` and binding ids
      `"oauth-" <> 16-byte-hex` (willow uses UUIDv7 for both).
    * Binding upsert is a scan + create-once/CAS sequence, not a SQLite
      transaction; two concurrent callbacks for the same brand-new alias can
      in principle each create a binding (willow serializes in SQL). The
      window is a single in-flight browser redirect, accepted for V1.
    * Missing / expired / already-consumed states are distinct AuthState
      errors but all render willow's "authorization session expired" page.
    * Internal failures return `{:json, 500, %{error: ...}}` shaped like the
      rest of the Salix router (willow's writeError).
  """

  require Logger

  alias Salix.Control.{OAuthApps, OAuthBindings}
  alias SalixStore.OAuth, as: Connections
  alias SalixStore.OAuth.{Adapters, AuthState}

  @auth_state_ttl_ms 600_000

  @type callback_response ::
          {:redirect, String.t()}
          | {:page, non_neg_integer(), String.t()}
          | {:json, non_neg_integer(), map()}

  # ---- authorize (web origin) ----

  @doc """
  Willow's startOAuthAuthorize: validate provider + alias, require a
  configured tenant provider app, build the authorization URL, persist a
  pending web-origin auth state. Error tuples map to HTTP statuses:
  `{:bad_request, msg}` → 400, `{:precondition_failed, msg}` → 412,
  `{:internal, msg}` → 500.
  """
  @spec start_authorization(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, {:bad_request | :precondition_failed | :internal, String.t()}}
  # Only authenticated product code can supply this context. HTTP params are
  # deliberately separate and cannot claim a Comma member identity.
  def start_authorization(tenant_id, group_id, provider, params, opts \\ []) do
    provider = normalize_provider(provider)
    params = if is_map(params), do: params, else: %{}

    with {:ok, adapter} <- lookup_adapter(provider),
         {:ok, alias_name} <- require_alias(params),
         {:ok, app} <- require_provider_app(tenant_id, provider) do
      scopes = clean_scopes(params["scopes"])
      state = new_token()
      verifier = new_token()
      redirect_uri = callback_url(provider)

      authorization_request = %{
        "redirect_uri" => redirect_uri,
        "state" => state,
        "scopes" => scopes,
        "code_challenge" => code_challenge_s256(verifier)
      }

      case adapter.authorization_url(app, authorization_request) do
        {:ok, url} ->
          now = System.system_time(:millisecond)

          record = %{
            "state" => state,
            "tenant" => tenant_id,
            "group_id" => group_id,
            "agent_id" => nil,
            "session_id" => nil,
            "provider" => provider,
            "alias" => alias_name,
            "scopes" => scopes,
            "code_verifier" => verifier,
            "redirect_uri" => redirect_uri,
            "redirect_after" => blank_to_nil(params["redirect_after"]),
            "origin" => "web",
            "comma_member" => Keyword.get(opts, :comma_member),
            "comma_operation" => Keyword.get(opts, :comma_operation),
            "status" => "pending",
            "error" => nil,
            "binding_id" => nil,
            "connection_id" => nil,
            "provider_account_name" => nil,
            "expires_at" =>
              case Keyword.get(opts, :expires_at) do
                value when is_integer(value) -> min(value, now + @auth_state_ttl_ms)
                _ -> now + @auth_state_ttl_ms
              end,
            "created_at" => now
          }

          case AuthState.create(record) do
            :ok ->
              {:ok, %{"authorization_url" => url, "state" => state}}

            {:error, reason} ->
              {:error, {:internal, "persist state: " <> format_reason(reason)}}
          end

        {:error, reason} ->
          {:error, {:bad_request, format_reason(reason)}}
      end
    end
  end

  # ---- callback ----

  @doc """
  Willow's handleOAuthCallback. `query` is the raw callback query-param map
  (`state`, `code`, `error`). Returns a response directive for the router.
  """
  @spec handle_callback(String.t(), map()) :: callback_response()
  def handle_callback(provider, query) do
    provider = normalize_provider(provider)
    state = blank_to_nil(query["state"])

    if is_nil(state) do
      finish(nil, provider, nil, "missing state")
    else
      case AuthState.consume(state) do
        {:ok, auth} ->
          continue_callback(
            auth,
            provider,
            blank_to_nil(query["code"]),
            blank_to_nil(query["error"])
          )

        {:error, reason} when reason in [:not_found, :expired, :already_consumed] ->
          finish(nil, provider, nil, "authorization session expired")

        {:error, reason} ->
          {:json, 500, %{error: format_reason(reason)}}
      end
    end
  end

  defp continue_callback(auth, provider, code, provider_error) do
    cond do
      normalize_provider(auth["provider"]) != provider ->
        finish(auth, provider, nil, "provider mismatch")

      not is_nil(provider_error) ->
        finish(auth, provider, nil, "authorization denied: " <> provider_error)

      is_nil(code) ->
        finish(auth, provider, nil, "missing code")

      true ->
        case lookup_adapter(provider) do
          {:ok, adapter} -> exchange(auth, provider, adapter, code)
          {:error, _} -> finish(auth, provider, nil, "unsupported provider")
        end
    end
  end

  defp exchange(auth, provider, adapter, code) do
    case require_provider_app(auth["tenant"], provider) do
      {:error, _} ->
        finish(auth, provider, nil, "provider app not configured")

      {:ok, app} ->
        ctx = %{
          "redirect_uri" => auth["redirect_uri"] || callback_url(provider),
          "code_verifier" => auth["code_verifier"],
          "scopes" => auth["scopes"] || []
        }

        case adapter.exchange_code(app, ctx, code) do
          {:ok, %{"tokens" => tokens, "account" => account}} ->
            case SalixWeb.OAuthCommitGuard.run(auth, fn ->
                   persist_connection_and_binding(auth, provider, tokens, account || %{})
                 end) do
              {:ok, completion} -> finish(auth, provider, completion, nil)
              {:error, reason} -> finish(auth, provider, nil, reason)
            end

          {:error, reason} ->
            finish(auth, provider, nil, "token exchange: " <> format_reason(reason))
        end
    end
  end

  defp persist_connection_and_binding(auth, provider, tokens, account) do
    # Providers commonly omit granted scopes; fall back to what was requested.
    tokens =
      if clean_scopes(tokens["scopes"]) == [] and clean_scopes(auth["scopes"]) != [],
        do: Map.put(tokens, "scopes", auth["scopes"]),
        else: tokens

    connection_id = "conn-" <> random_hex()
    record = connection_record(connection_id, auth, provider, tokens, account)

    case Connections.put(connection_id, record) do
      :ok ->
        case OAuthBindings.put(
               auth["tenant"],
               auth["group_id"],
               provider,
               auth["alias"],
               connection_id
             ) do
          {:ok, binding, previous_connection_id} ->
            # V1 keeps one connection per binding: re-authorizing an alias
            # repointed the binding above, so the previous connection is now
            # unreferenced and must be revoked + deleted — unless the provider
            # re-issued the same token material (Slack additive grants,
            # classic GitHub OAuth Apps), in which case revoking it would kill
            # the token the new binding depends on.
            if previous_connection_id do
              cleanup_orphaned_connection(auth["tenant"], previous_connection_id, tokens)
            end

            {:ok,
             %{
               "binding_id" => binding["binding_id"],
               "connection_id" => connection_id,
               "provider_account_name" => account["provider_account_name"]
             }}

          {:error, reason} ->
            # A Comma reauthorization can commit its binding even when the
            # response is lost. Preserve that credential for the fenced retry.
            if is_nil(auth["comma_operation"]) do
              _ = delete_connection_record(connection_id)
            end

            {:error, "persist binding: " <> format_reason(reason)}
        end

      {:error, reason} ->
        {:error, "persist connection: " <> format_reason(reason)}
    end
  end

  # Connection record (willow oauth_connections columns): token fields stay
  # flat ("access_token", "refresh_token", "expires_at" ms, ... — the shape
  # `SalixStore.OAuth.valid_token/3` refreshes), account ids/names are
  # top-level, remaining account fields land under "metadata".
  defp connection_record(connection_id, auth, provider, tokens, account) do
    now = System.system_time(:millisecond)

    extra_metadata =
      account
      |> Map.drop(["provider_account_id", "provider_account_name"])

    tokens
    |> Map.merge(%{
      "connection_id" => connection_id,
      "tenant" => auth["tenant"],
      "provider" => provider,
      "comma_member" => auth["comma_member"],
      "provider_account_id" => account["provider_account_id"] || "",
      "provider_account_name" => account["provider_account_name"] || "",
      "metadata" => extra_metadata,
      "status" => "active",
      "created_at" => now,
      "updated_at" => now
    })
  end

  # ---- binding deletion (willow deleteGroupOAuthBinding) ----

  @doc """
  Delete a group binding; when it was the last reference to its connection,
  best-effort revoke at the provider and delete the connection record.
  Tenant-scoped 404 covers missing bindings and cross-tenant ids alike.
  """
  @spec delete_binding(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete_binding(tenant_id, group_id, binding_id) do
    case OAuthBindings.get(group_id, binding_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok, binding} ->
        if binding["tenant_id"] not in [nil, tenant_id] do
          {:error, :not_found}
        else
          with :ok <- OAuthBindings.delete(group_id, binding_id) do
            connection_id = binding["connection_id"]

            if is_binary(connection_id) and connection_id != "" and
                 OAuthBindings.count_for_connection(connection_id) == 0 do
              # V1: connections are group-local — revoke (best-effort) + delete.
              case Connections.get(connection_id) do
                {:ok, conn} -> best_effort_revoke(tenant_id, conn)
                _ -> :ok
              end

              _ = delete_connection_record(connection_id)
            end

            :ok
          end
        end
    end
  end

  # ---- orphan cleanup (willow cleanupOrphanedOAuthConnection) ----

  defp cleanup_orphaned_connection(tenant_id, connection_id, new_tokens) do
    if OAuthBindings.count_for_connection(connection_id) == 0 do
      case Connections.get(connection_id) do
        {:ok, conn} ->
          share_token =
            present?(conn["access_token"]) and conn["access_token"] == new_tokens["access_token"]

          share_refresh =
            present?(conn["refresh_token"]) and
              conn["refresh_token"] == new_tokens["refresh_token"]

          if share_token or share_refresh do
            Logger.info(
              "skipping oauth provider revoke; new binding shares token material connection_id=#{connection_id} provider=#{conn["provider"]}"
            )
          else
            best_effort_revoke(tenant_id, conn)
          end

        {:error, reason} ->
          Logger.warning(
            "load orphan oauth connection connection_id=#{connection_id}: #{format_reason(reason)}"
          )
      end

      case delete_connection_record(connection_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "delete orphan oauth connection connection_id=#{connection_id}: #{format_reason(reason)}"
          )
      end
    else
      # Future-proofing: a shared connection must outlive this binding.
      :ok
    end
  end

  defp best_effort_revoke(tenant_id, conn) do
    with {:ok, adapter} <- lookup_adapter(normalize_provider(conn["provider"])) do
      app =
        case OAuthApps.get(tenant_id, conn["provider"]) do
          {:ok, app} -> app
          _ -> %{"client_id" => "", "client_secret" => ""}
        end

      case adapter.revoke(app, conn) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("oauth provider revoke failed: #{format_reason(reason)}")
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("oauth provider revoke raised: #{Exception.message(error)}")
      :ok
  end

  # `SalixStore.OAuth` has no delete; the record key is public via Keys.
  defp delete_connection_record(connection_id),
    do: SalixStore.S3.delete(SalixStore.Keys.oauth_connection(connection_id))

  # ---- terminal outcome + response rendering (willow finishOAuthCallback) ----

  defp finish(auth, provider, completion, error_message) do
    if auth do
      if record_outcome(auth["state"], completion, error_message) == :ok do
        # The verified OAuth state, not a chat button, is the success authority.
        # A native check-result button can retry delivery after an outage.
        SalixIM.TelegramInteractions.oauth_completed(auth["state"])
      end
    end

    redirect_after = auth && blank_to_nil(auth["redirect_after"])

    cond do
      error_message && redirect_after ->
        {:redirect, append_oauth_error(redirect_after, error_message)}

      is_nil(error_message) && redirect_after ->
        {:redirect, redirect_after}

      true ->
        status = if error_message, do: 400, else: 200
        {:page, status, SalixWeb.OAuthCallbackPage.render(provider, error_message)}
    end
  end

  defp record_outcome(state, completion, error_message) do
    cond do
      is_binary(error_message) ->
        case AuthState.record_failure(state, error_message) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("record oauth auth state failure: #{format_reason(reason)}")
        end

      is_map(completion) ->
        case AuthState.record_completion(state, completion) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("record oauth auth state completion: #{format_reason(reason)}")
        end

      true ->
        :ok
    end
  end

  defp append_oauth_error(redirect_after, message) do
    uri = URI.parse(redirect_after)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("oauth_error", message)
      |> URI.encode_query()

    URI.to_string(%{uri | query: query})
  end

  # ---- helpers ----

  defp lookup_adapter(provider) do
    case Adapters.for_provider(provider) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, :unsupported_provider} -> {:error, {:bad_request, "unsupported oauth provider"}}
    end
  end

  defp require_alias(params) do
    case blank_to_nil(params["alias"]) do
      nil -> {:error, {:bad_request, "alias is required"}}
      alias_name -> {:ok, alias_name}
    end
  end

  defp require_provider_app(tenant_id, provider) do
    case OAuthApps.get(tenant_id, provider) do
      {:ok, app} ->
        {:ok, app}

      {:error, :not_configured} ->
        {:error, {:precondition_failed, "oauth provider #{provider} is not configured"}}

      {:error, reason} ->
        {:error, {:internal, format_reason(reason)}}
    end
  end

  # Willow's oauthCallbackURL: public API origin + /v1/oauth/{provider}/callback.
  defp callback_url(provider) do
    String.trim_trailing(SalixWeb.Application.public_base_url(), "/") <>
      "/v1/oauth/#{provider}/callback"
  end

  defp normalize_provider(provider),
    do: provider |> to_string() |> String.trim() |> String.downcase()

  defp clean_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&(&1 |> to_string() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp clean_scopes(_scopes), do: []

  defp new_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp random_hex, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp code_challenge_s256(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp present?(value), do: is_binary(value) and value != ""

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
