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
         {:ok, fields} <- secret_fields(provider, params["fields"]),
         :ok <- app_source_owner(opts),
         {:ok, app} <- require_app(tenant_id, provider, Keyword.get(opts, :app_source)) do
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
          now = SystemsClock.system_time(:millisecond)

          record = %{
            "state" => state,
            "tenant" => tenant_id,
            "group_id" => group_id,
            "agent_id" => nil,
            "session_id" => nil,
            "provider" => provider,
            "alias" => alias_name,
            "fields" => fields,
            "scopes" => scopes,
            "code_verifier" => verifier,
            "redirect_uri" => redirect_uri,
            "redirect_after" => blank_to_nil(params["redirect_after"]),
            "origin" => "web",
            "comma_member" => Keyword.get(opts, :comma_member),
            "bft_member" => Keyword.get(opts, :bft_member),
            "app_source" => Keyword.get(opts, :app_source),
            "comma_operation" => Keyword.get(opts, :comma_operation),
            "mcp_binding_ids" => Keyword.get(opts, :mcp_binding_ids, []),
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
            callback_code(provider, query["code"]),
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
    case require_app(auth["tenant"], provider, auth["app_source"]) do
      {:error, _} ->
        finish(auth, provider, nil, "provider app not configured")

      {:ok, app} ->
        ctx = %{
          "redirect_uri" => auth["redirect_uri"] || callback_url(provider),
          "code_verifier" => auth["code_verifier"],
          "scopes" => auth["scopes"] || [],
          "fields" => auth["fields"] || []
        }

        case adapter.exchange_code(app, ctx, code) do
          {:ok, %{"tokens" => tokens, "account" => account}} ->
            case SalixWeb.OAuthCommitGuard.run(auth, fn ->
                   persist_connection_and_binding(auth, provider, tokens, account || %{})
                 end) do
              {:ok, completion} ->
                result = finish(auth, provider, completion, nil)
                start_managed_mcp_refresh(auth, provider)
                result

              {:error, reason} ->
                finish(auth, provider, nil, reason)
            end

          {:error, reason} ->
            finish(auth, provider, nil, "token exchange: " <> format_reason(reason))
        end
    end
  end

  # MCP discovery can take minutes; it runs after the grant is recorded so a
  # slow or rejecting MCP server never delays or fails the OAuth completion.
  defp start_managed_mcp_refresh(auth, provider) do
    case auth["mcp_binding_ids"] do
      [_ | _] = binding_ids ->
        case SystemsRuntime.TaskSupervisor.start_child(SalixWeb.OAuthMCPRefreshSupervisor, fn ->
               refresh_managed_mcps(auth, provider, binding_ids)
             end) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.warning("OAuth MCP refresh not started: #{inspect(reason)}")
        end

      _ ->
        :ok
    end
  end

  defp refresh_managed_mcps(auth, provider, binding_ids) do
    Enum.each(binding_ids, fn binding_id ->
      with {:ok, binding} <-
             SalixMCP.Store.get_binding(auth["tenant"], auth["group_id"], binding_id),
           true <- binding["enabled"] != false,
           true <-
             Enum.any?(binding["oauth_binding_refs"] || %{}, fn {_name, ref} ->
               ref["provider"] == provider and ref["alias"] == auth["alias"]
             end) do
        _ = SalixMCP.Gateway.refresh_binding(auth["tenant"], auth["group_id"], binding_id)
      end
    end)
  end

  defp persist_connection_and_binding(auth, provider, tokens, account) do
    # Providers commonly omit granted scopes; fall back to what was requested.
    tokens =
      if clean_scopes(tokens["scopes"]) == [] and clean_scopes(auth["scopes"]) != [],
        do: Map.put(tokens, "scopes", auth["scopes"]),
        else: tokens

    connection_id = "conn-" <> random_hex()
    record = connection_record(connection_id, auth, provider, tokens, account)

    if is_map(auth["bft_member"]),
      do: persist_member_connection(connection_id, record, account),
      else: persist_group_connection(auth, provider, tokens, account, connection_id, record)
  end

  # A BFT member's personal grant belongs to that member, not to a Group: it
  # gets no Group binding, so no Agent can resolve it as a credential.
  defp persist_member_connection(connection_id, record, account) do
    case Connections.put(connection_id, record) do
      :ok ->
        {:ok,
         %{
           "binding_id" => nil,
           "connection_id" => connection_id,
           "provider_account_name" => account["provider_account_name"]
         }}

      {:error, reason} ->
        {:error, "persist connection: " <> format_reason(reason)}
    end
  end

  defp persist_group_connection(auth, provider, tokens, account, connection_id, record) do
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
    now = SystemsClock.system_time(:millisecond)

    extra_metadata =
      account
      |> Map.drop(["provider_account_id", "provider_account_name"])

    tokens
    |> Map.merge(%{
      "connection_id" => connection_id,
      "tenant" => auth["tenant"],
      "provider" => provider,
      "comma_member" => auth["comma_member"],
      "bft_member" => auth["bft_member"],
      "app_source" => auth["app_source"],
      "owner" => auth["owner"],
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

  @doc """
  Revoke and delete a BFT member's personal connection. The owner must match,
  so one member's request can never remove another's grant.
  """
  @spec delete_member_connection(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def delete_member_connection(tenant_id, connection_id, bft_member) when is_map(bft_member) do
    case Connections.get(connection_id) do
      {:ok, %{"tenant" => ^tenant_id, "bft_member" => owner} = conn} when owner == bft_member ->
        best_effort_revoke(tenant_id, conn)

        case delete_connection_record(connection_id) do
          {:error, reason} -> {:error, reason}
          _deleted -> :ok
        end

      {:ok, _other} ->
        {:error, :not_found}

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
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

  @doc "The form a secret's link opens. Showing it consumes nothing; posting it does."
  def secret_form(query) do
    with state when is_binary(state) <- blank_to_nil(query["state"]),
         {:ok, %{"provider" => "secret", "status" => "pending", "alias" => alias_name} = auth} <-
           AuthState.get(state) do
      {:page, 200,
       SalixWeb.OAuthCallbackPage.render_secret_form(state, alias_name, auth["fields"] || [])}
    else
      _ -> finish(nil, "secret", nil, "authorization session expired")
    end
  end

  @doc """
  The value a person typed on a request's card, for `state`: the secret's
  callback, as its form posts it. The callback's own ending ends the request.
  """
  def submit_secret(state, value),
    do: handle_callback("secret", %{"state" => state, "code" => value})

  @doc """
  The app a person gave on a request's card: the tenant's own from now on,
  unless it got one meanwhile, which stands. Returns the provider's page for
  `state`; the flow goes on from there as any other does.
  """
  def submit_app(state, client_id, client_secret) do
    with {:ok, %{"status" => "pending", "tenant" => tenant, "provider" => provider} = auth} <-
           AuthState.get(state),
         {:ok, app} <- own_app(tenant, provider, client_id, client_secret),
         {:ok, adapter} <- lookup_adapter(provider) do
      challenge =
        Base.url_encode64(:crypto.hash(:sha256, auth["code_verifier"]), padding: false)

      adapter.authorization_url(app, %{
        "redirect_uri" => auth["redirect_uri"],
        "state" => state,
        "scopes" => auth["scopes"],
        "code_challenge" => challenge
      })
    end
  end

  @doc """
  Keeps a CLI login's files for `owner`, as a secret credential of theirs with
  the alias `cli-login-<program>`: they can see it among their credentials and
  delete it. Keeping again replaces it.
  """
  def keep_login(tenant, group, owner, program, archive) do
    auth = %{
      "tenant" => tenant,
      "group_id" => group,
      "provider" => "secret",
      "alias" => login_alias(program),
      "owner" => owner,
      "scopes" => []
    }

    with {:ok, adapter} <- lookup_adapter("secret"),
         {:ok, %{"tokens" => tokens, "account" => account}} <-
           adapter.exchange_code(%{}, %{}, archive) do
      persist_connection_and_binding(auth, "secret", tokens, account)
    end
  end

  @doc "What `keep_login/5` kept for `owner`: `{:ok, archive}`, or `:none`."
  def kept_login(_tenant, group, owner, program) do
    with {:ok, bindings} <- SalixAgent.OAuthStore.bindings_for_group(group),
         %{"connection_id" => connection} <-
           Enum.find(bindings, fn binding ->
             binding["provider"] == "secret" and binding["alias"] == login_alias(program) and
               SalixAgent.OAuthCredentials.usable_by?(binding, owner)
           end),
         {:ok, %{"access_token" => archive}} when is_binary(archive) <-
           Connections.get(connection) do
      {:ok, archive}
    else
      _none -> :none
    end
  end

  defp login_alias(program), do: "cli-login-" <> program

  defp own_app(tenant, provider, client_id, client_secret) do
    case OAuthApps.get_own(tenant, provider) do
      {:ok, app} ->
        {:ok, app}

      {:error, :not_configured} ->
        attrs = %{"client_id" => client_id, "client_secret" => client_secret}

        with {:ok, _saved} <- OAuthApps.put(tenant, provider, attrs),
             do: OAuthApps.get_own(tenant, provider)

      error ->
        error
    end
  end

  # ---- device authorization (RFC 8628) ----

  @doc """
  One poll of a device authorization, asked for by `oauth.complete_authorization`:
  there is no callback, and nothing polls on its own. Confirmed, it connects the
  account as a callback does. A state another poll consumed answers as it stands.
  """
  def poll_device(
        %{"state" => state, "provider" => "custom." <> _ = provider, "device_code" => code} =
          record
      ) do
    with {:ok, app} <- OAuthApps.get(record["tenant"], provider) do
      case SalixWeb.OAuthCustomAdapter.device_poll(app, code) do
        :pending ->
          {:ok, record}

        {:ok, %{"tokens" => tokens, "account" => account}} ->
          with {:ok, auth} <- AuthState.consume(state) do
            case persist_connection_and_binding(auth, provider, tokens, account) do
              {:ok, completion} -> finish(auth, provider, completion, nil)
              {:error, reason} -> finish(auth, provider, nil, reason)
            end
          end

          AuthState.get(state)

        {:error, reason} ->
          with {:ok, auth} <- AuthState.consume(state),
               do: finish(auth, provider, nil, format_reason(reason))

          AuthState.get(state)
      end
    end
  end

  # ---- a member's Feishu or Lark sign-in with their own bot app ----

  @doc """
  Begins a Comma member's Feishu or Lark sign-in by a device code
  (`SalixStore.OAuth.LarkDevice`) with the bot app their scan made (`source`,
  kind `lark_im_connect`). The answer has the link the member confirms.
  """
  def begin_member_device(tenant_id, provider, scopes, source)
      when provider in ~w(feishu lark) and is_map(source) do
    with {:ok, app} <- require_app(tenant_id, provider, source) do
      SalixStore.OAuth.LarkDevice.begin(provider, app, scopes)
    end
  end

  @doc """
  Asks once whether the member confirmed a sign-in `begin_member_device/4`
  began. Confirmed, it becomes the Group's `provider` binding under
  `alias_name` for `comma_member`, refreshed with the same bot app, and
  replaces that binding's earlier grant.

  Only the person whose scan made the app can confirm it: a sign-in by
  anyone else (the code forwarded to them) is refused. The binding belongs
  to the member: an Agent uses it only for work done for them
  (`SalixAgent.OAuthCredentials.usable_by?/2`).
  """
  def poll_member_device(
        tenant_id,
        group_id,
        provider,
        device_code,
        source,
        comma_member,
        alias_name
      )
      when provider in ~w(feishu lark) and is_map(source) and is_map(comma_member) do
    with {:ok, app} <- require_app(tenant_id, provider, source) do
      case SalixStore.OAuth.LarkDevice.poll(provider, app, device_code) do
        {:ok, %{"tokens" => tokens, "account" => account}} ->
          if account["provider_account_id"] == app["owner_open_id"] do
            auth = %{
              "tenant" => tenant_id,
              "group_id" => group_id,
              "alias" => alias_name,
              "scopes" => [],
              "comma_member" => comma_member,
              "owner" => SalixIFC.Codec.encode_principal!({:comma_user, comma_member["user_id"]}),
              "app_source" => source
            }

            persist_connection_and_binding(auth, provider, tokens, account)
          else
            {:error, {:device_refused, "not_app_owner"}}
          end

        other ->
          other
      end
    end
  end

  # ---- terminal outcome + response rendering (willow finishOAuthCallback) ----

  defp finish(auth, provider, completion, error_message) do
    if auth do
      if record_outcome(auth["state"], completion, error_message) == :ok do
        # The verified OAuth state, not a chat button, is the success authority.
        # A native check-result button can retry delivery after an outage.
        SalixIM.TelegramInteractions.oauth_completed(auth["state"])
        if is_nil(error_message), do: end_capability_requests(auth, completion)
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
        {:page, status, result_page(provider, auth, error_message)}
    end
  end

  defp result_page("secret", %{"alias" => alias_name}, nil) when is_binary(alias_name),
    do: SalixWeb.OAuthCallbackPage.render_secret_saved(alias_name)

  defp result_page(provider, _auth, error_message),
    do: SalixWeb.OAuthCallbackPage.render(provider, error_message)

  # A Comma conversation's request card for this account ends here, and the
  # Agent waiting on it goes on (SalixAgent.CapabilityRequests).
  defp end_capability_requests(%{"group_id" => group, "tenant" => tenant} = auth, completion)
       when is_binary(group) and is_binary(tenant) do
    flow = %{
      "state" => auth["state"],
      "provider" => auth["provider"],
      "alias" => auth["alias"],
      "provider_account_name" => if(is_map(completion), do: completion["provider_account_name"])
    }

    case SalixAgent.CapabilityRequests.complete_oauth_authorization(group, tenant, flow) do
      {:ok, _ended} ->
        :ok

      {:error, reason} ->
        Logger.warning("end oauth capability requests: #{format_reason(reason)}")
    end
  end

  defp end_capability_requests(_auth, _completion), do: :ok

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

  # A trusted caller may name the Swarm's own Slack bot app instead of the
  # tenant's provider app. Its credentials are read from the connect at each
  # leg and never stored in the authorization state.
  # A bot-app grant is only ever a member's personal grant: it must never
  # become a Group binding that Agents resolve.
  defp app_source_owner(opts) do
    if is_nil(Keyword.get(opts, :app_source)) or is_map(Keyword.get(opts, :bft_member)) or
         is_map(Keyword.get(opts, :comma_member)),
       do: :ok,
       else: {:error, {:bad_request, "app source requires a member grant"}}
  end

  @doc """
  The client app of a connection made with an app source (a member's own bot
  app), for its refresh: the source as it stands now, or an error when the
  app is gone.
  """
  def source_app(tenant_id, provider, source) when is_map(source) do
    case require_app(tenant_id, provider, source) do
      {:ok, app} -> {:ok, app}
      {:error, {_kind, message}} -> {:error, message}
    end
  end

  # A secret's form posts its fields together, by name; any other code is text.
  defp callback_code("secret", %{} = fields), do: fields
  defp callback_code(_provider, code), do: blank_to_nil(code)

  defp secret_fields("secret", fields) do
    case SalixStore.OAuth.Adapters.Secret.fields(fields) do
      {:ok, fields} -> {:ok, fields}
      {:error, message} -> {:error, {:bad_request, message}}
    end
  end

  defp secret_fields(_provider, _fields), do: {:ok, []}

  # Checked at both legs: the bot app must still differ from the tenant's
  # Slack OAuth app, or the grant's scopes would join a Group-bound token.
  defp require_app(tenant_id, "slack", %{"kind" => "slack_im_connect"} = source) do
    with {:ok, connect} <-
           SalixIM.ProviderConnects.get_active_connect_by_id(
             source["group_id"],
             source["connect_id"],
             "slack"
           ),
         true <- connect["tenant_id"] == tenant_id,
         id when is_binary(id) and id != "" <- connect["client_id"],
         secret when is_binary(secret) and secret != "" <- connect["client_secret"],
         false <- tenant_app_client_id(tenant_id) == id do
      {:ok, %{"client_id" => id, "client_secret" => secret, "source" => "slack_im_connect"}}
    else
      _unavailable ->
        {:error, {:precondition_failed, "slack bot app is not usable for a member grant"}}
    end
  end

  # A member's own Feishu or Lark bot app, made by their scan: only its
  # owner's connect in the Group, and only for the brand the app is on.
  defp require_app(tenant_id, provider, %{"kind" => "lark_im_connect"} = source)
       when provider in ~w(feishu lark) do
    with {:ok, connect} <-
           SalixIM.ProviderConnects.get_active_connect_by_id(
             source["group_id"],
             source["connect_id"],
             provider
           ),
         true <- connect["tenant_id"] == tenant_id and connect["owner_only"] == true,
         id when is_binary(id) and id != "" <- connect["app_id"],
         secret when is_binary(secret) and secret != "" <-
           SalixIM.ProviderConnects.app_secret(connect) do
      {:ok,
       %{
         "client_id" => id,
         "client_secret" => secret,
         "source" => "lark_im_connect",
         "owner_open_id" => connect["owner_open_id"]
       }}
    else
      _unavailable ->
        {:error, {:precondition_failed, "#{provider} bot app is not usable for a member grant"}}
    end
  end

  defp require_app(_tenant_id, _provider, source) when not is_nil(source),
    do: {:error, {:bad_request, "unsupported app source"}}

  # A secret is typed into Salix's own form: there is no provider app.
  defp require_app(_tenant_id, "secret", nil), do: {:ok, %{}}
  defp require_app(tenant_id, provider, nil), do: require_provider_app(tenant_id, provider)

  defp tenant_app_client_id(tenant_id) do
    case OAuthApps.get(tenant_id, "slack") do
      {:ok, %{"client_id" => client_id}} -> client_id
      _none -> nil
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

  defp new_token, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

  defp random_hex, do: SystemsRuntime.Proc.random_bytes(16) |> Base.encode16(case: :lower)

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
