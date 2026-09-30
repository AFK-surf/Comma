defmodule SalixAgent.Tools.OAuth do
  @moduledoc """
  OAuth credential tools, ported to willow parity from
  `internal/tools/listoauth.go`, `internal/tools/request_oauth_auth.go`, and
  `internal/tools/complete_oauth_auth.go`. Group bindings, the tenant client
  app, and the public base URL come from the `SalixAgent.OAuthStore` seam;
  durable authorization state lives in `SalixStore.OAuth.AuthState` records at
  `ctl/oauth/auth_states/{state}.json`; provider specifics go through
  `SalixStore.OAuth.Adapters`. The token exchange happens in the HTTP
  callback (`/v1/oauth/{provider}/callback`), never in these tools — willow
  parity; `oauth.complete_authorization` only polls the auth-state record.

  ## Intentional divergences from willow

    * Tool names use the canonical namespace form:
      `oauth.list_credentials`, `oauth.request_authorization`,
      `oauth.complete_authorization`, and `oauth.delete_credential`.
      Intra-description references to tool names are renamed to match.
    * Required-argument errors use Salix's `'field' is required` wording
      instead of willow's `missing required parameter: field`.
    * `oauth.request_authorization`'s description and result `instructions`
      drop willow's "creates a user-visible authorization request card/link"
      phrasing. Salix has no path that surfaces the authorization request to
      the chat automatically (the capability request only feeds the web
      dashboard SSE), so both now tell the agent to post the `authorization_url`
      to the user itself via `call` — e.g. a Slack Block Kit
      card, or the Feishu/other provider message API.
    * `oauth.request_authorization` creates a durable capability request
      through `SalixAgent.CapabilityRequestStore`, marks the tool call as
      async-running, and returns a generic `wait_set` session fact, from which
      an idle session derives the product `waiting` state.
    * `oauth.complete_authorization` is only a status polling tool. User/UI
      completion of the capability request resolves the async tool call through
      `SalixAgent.complete_async_tool_call/6`.
    * The completed response additionally carries `provider_account_name`
      when the callback recorded one (willow returns only `binding_id`).
    * PKCE `state` and `code_verifier` are 32 random bytes base64url without
      padding generated here; willow injects `OAuthNewState` /
      `OAuthNewCodeVerifier` (equivalent entropy). The S256 code challenge is
      computed locally and passed to the adapter.
    * Adapter lookup honors the `:oauth_adapters_fn` app-env test seam
      (default `SalixStore.OAuth.Adapters.for_provider/1`); willow's
      list-tool keeps a local provider→env-var map to avoid an import cycle —
      Salix asks the adapter's `default_env_var/0` directly, falling back to
      `"OAUTH_TOKEN"` for unsupported providers exactly like the original behavior.
    * `expires_at` / `created_at` are unix MILLISECONDS (Salix journal/store
      convention); willow uses unix seconds.
    * Willow's `tenantOAuthApp` Normalized() trim is approximated by checking
      for non-blank `client_id` / `client_secret` strings.

  ## Events (string-keyed, existing `SalixAgent.State` vocabulary)

    * `oauth.request_authorization` →
      `async_tool_call_started` plus `%{"type" => "wait_set", "session_id" => sid, "wait" => wait_payload}`
  """

  alias SalixAgent.{CapabilityRequestStore, OAuthStore, Waits}
  alias SalixAgent.Tools.AsyncPolicy
  alias SalixStore.OAuth.AuthState

  # willow request_oauth_auth.go: default 10min, max 30min.
  @default_timeout_seconds 600
  @max_timeout_seconds 1800
  @normal_auto_wait_seconds AsyncPolicy.normal_tool_auto_wait_seconds()
  @user_interaction_auto_wait_seconds AsyncPolicy.user_interaction_tool_auto_wait_seconds()
  @visible_request_opts [safety: "write"]

  @doc """
  Tool defs in canonical registry order (`oauth.list_credentials`,
  `oauth.request_authorization`, `oauth.complete_authorization`). Descriptions are
  willow's, with tool-name references renamed to the Salix snake_case names.
  """
  @spec defs() ::
          [
            {String.t(), String.t(), (map(), map() -> term()), pos_integer()}
            | {String.t(), String.t(), (map(), map() -> term()), pos_integer(), keyword()}
          ]
  def defs do
    [
      {"oauth.list_credentials",
       "List OAuth credential aliases available to this agent group.\n\n" <>
         "Returns one entry per (provider, alias) binding, including disabled bindings. " <>
         "Only entries with enabled=true can be passed into credential_env on compute.exec, process.start, or env.exec. Token values are never returned.",
       &__MODULE__.list_oauth_credentials/2, @normal_auto_wait_seconds},
      {"oauth.request_authorization",
       "Start a managed OAuth authorization flow for this agent group.\n\n" <>
         "Returns an authorization URL and waits until the user completes or rejects it. " <>
         "The URL is NOT surfaced automatically: you must post it to the requester yourself through the current visible reply path. For an internal Comma conversation, use call(tool=\"im_api.internal.send_message\", params={...}) with connect_id=\"internal\" inside params. For an external provider, call the matching im_api.* operation directly when provider/connect/API are known; use IM discovery/help only when those facts are missing. " <>
         "Returns a deferred result with the provider binding when completed. " <>
         "Use the resulting provider and alias in a credential_env entry on compute.exec, process.start, or env.exec, with env_var and value.",
       &__MODULE__.request_oauth_authorization/2, @user_interaction_auto_wait_seconds,
       @visible_request_opts},
      {"oauth.complete_authorization",
       "Verify the outcome of an authorization flow previously started by oauth.request_authorization.\n\n" <>
         "Returns status=completed with the (provider, alias) once the user finishes the browser flow, status=pending if they have not finished yet, or status=failed/expired with an error reason. " <>
         "Idempotent: completed/failed flows return the same result on subsequent calls until the auth state row is purged.",
       &__MODULE__.complete_oauth_authorization/2, @normal_auto_wait_seconds},
      {"oauth.delete_credential",
       "Delete (disconnect) an OAuth credential for this agent group.\n\n" <>
         "Identify the credential by provider and alias (as returned by oauth.list_credentials). " <>
         "Best-effort revokes the stored token at the provider and removes the binding so the group's agents can no longer use it. " <>
         "Idempotent: deleting a credential that does not exist returns status=not_found.",
       &__MODULE__.delete_oauth_credential/2, @normal_auto_wait_seconds}
    ]
  end

  # ---- list_oauth_credentials (willow listoauth.go) ----

  @doc false
  def list_oauth_credentials(_args, ctx) do
    case OAuthStore.agent_oauth_context(ctx.agent_id) do
      {:ok, %{group_id: group_id}} when is_binary(group_id) and group_id != "" ->
        case OAuthStore.bindings_for_group(group_id) do
          {:ok, bindings} ->
            entries =
              bindings
              |> Enum.map(&credential_entry/1)
              |> Enum.sort_by(fn e -> {e["provider"], e["alias"]} end)

            Jason.encode!(%{"credentials" => entries})

          {:error, reason} ->
            raise "list oauth bindings: #{format_reason(reason)}"
        end

      # No group / no store configured → empty list (willow: tc.GroupID == "").
      _ ->
        Jason.encode!(%{"credentials" => []})
    end
  end

  defp credential_entry(binding) do
    provider = to_string(binding["provider"] || "")
    alias_ = to_string(binding["alias"] || "")
    enabled = Map.get(binding, "enabled", true) != false

    %{
      "provider" => provider,
      "alias" => alias_,
      "enabled" => enabled,
      "status" => to_string(binding["status"] || "")
    }
    |> put_usage(enabled, provider, alias_)
    |> put_present("provider_account_name", binding["provider_account_name"])
    |> put_scopes(binding["scopes"])
  end

  defp put_usage(map, true, provider, alias_),
    do: Map.put(map, "usage", usage_hint(provider, alias_))

  defp put_usage(map, false, _provider, _alias), do: map

  defp put_present(map, key, value) do
    if is_binary(value) and value != "", do: Map.put(map, key, value), else: map
  end

  defp put_scopes(map, scopes) when is_list(scopes) and scopes != [],
    do: Map.put(map, "scopes", scopes)

  defp put_scopes(map, _), do: map

  # The same reference shape works on connector and Compute subprocesses.
  defp usage_hint(provider, alias_) do
    "credential_env for compute.exec, process.start, or env.exec: [{\"env_var\": \"" <>
      default_env_var(provider) <>
      "\", \"provider\": \"" <>
      provider <> "\", \"alias\": \"" <> alias_ <> "\", \"value\": \"access_token\"}]"
  end

  defp default_env_var(provider) do
    case adapters_fn().(provider) do
      {:ok, adapter} -> adapter.default_env_var()
      _ -> "OAUTH_TOKEN"
    end
  end

  # ---- oauth.request_authorization (willow request_oauth_auth.go) ----

  @doc false
  def request_oauth_authorization(args, ctx) do
    provider = args |> required_arg("provider") |> String.downcase()
    alias_ = required_arg(args, "alias")
    reason = required_arg(args, "reason")
    timeout_seconds = timeout_seconds(raw(args, "timeout_seconds"))
    scopes = clean_scopes(raw(args, "scopes"))

    {tenant, group_id} = oauth_context!(ctx.agent_id)
    app = provider_app!(tenant, provider)

    base = String.trim(to_string(OAuthStore.public_base_url() || ""))

    if base == "" do
      raise "public_base_url is not configured; an admin needs to set the server's public base URL before OAuth flows can run"
    end

    # willow buildOAuthRedirectURI: base path + /v1/oauth/{provider}/callback.
    redirect_uri = String.trim_trailing(base, "/") <> "/v1/oauth/" <> provider <> "/callback"

    state = random_token()
    code_verifier = random_token()
    code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)

    adapter =
      case adapters_fn().(provider) do
        {:ok, adapter} -> adapter
        {:error, _} -> raise "oauth provider #{inspect(provider)} is not supported"
      end

    authorization_url =
      case adapter.authorization_url(app, %{
             "redirect_uri" => redirect_uri,
             "state" => state,
             "scopes" => scopes,
             "code_challenge" => code_challenge
           }) do
        {:ok, url} -> url
        {:error, why} -> raise "build authorization url: #{format_reason(why)}"
      end

    now = System.system_time(:millisecond)
    expires_at = now + timeout_seconds * 1000

    record = %{
      "state" => state,
      "tenant" => tenant,
      "group_id" => group_id,
      "agent_id" => ctx.agent_id,
      "session_id" => session_id(ctx),
      "provider" => provider,
      "alias" => alias_,
      "scopes" => scopes,
      "code_verifier" => code_verifier,
      "redirect_uri" => redirect_uri,
      "redirect_after" => nil,
      "origin" => "agent",
      "status" => "pending",
      "error" => nil,
      "binding_id" => nil,
      "connection_id" => nil,
      "provider_account_name" => nil,
      "expires_at" => expires_at,
      "created_at" => now
    }

    record =
      if SalixAgent.TelegramInteraction.source?(ctx) do
        scope = ctx[:terminal_reply_context]

        unless is_map(scope) and scope["eligible"] == true and ctx[:llm_tool_envelope] == true,
          do: raise("Telegram authorization must be a standalone current-source call.")

        request_id =
          [ctx.agent_id, session_id(ctx), tool_call_id(ctx)]
          |> Jason.encode!()
          |> then(&:crypto.hash(:sha256, &1))
          |> Base.url_encode64(padding: false)

        Map.put(record, "telegram_interaction", %{"group_id" => group_id, "id" => request_id})
      else
        record
      end

    case AuthState.create(record) do
      :ok ->
        :ok

      {:error, :already_exists} ->
        raise "persist authorization state: state already exists"

      {:error, why} ->
        raise "persist authorization state: #{format_reason(why)}"
    end

    tool_call_id = tool_call_id(ctx)

    if SalixAgent.TelegramInteraction.source?(ctx) do
      SalixAgent.TelegramInteraction.request(
        "oauth",
        %{
          "reason" => reason,
          "authorization_url" => authorization_url,
          "oauth_state" => state,
          "locale" => args["locale"],
          "timeout_seconds" => timeout_seconds
        },
        ctx
      )
    else
      request =
        create_capability_request!(%{
          "tenant_id" => tenant,
          "group_id" => group_id,
          "source_agent_id" => ctx.agent_id,
          "source_session_id" => session_id(ctx),
          "tool_call_id" => tool_call_id,
          "request_type" => "oauth_authorization",
          "request_payload" => %{
            "oauth_authorization" => %{
              "provider" => provider,
              "alias" => alias_,
              "state" => state,
              "reason" => reason,
              "authorization_url" => authorization_url
            }
          },
          "expires_at" => div(expires_at, 1000)
        })

      content =
        Jason.encode!(%{
          "status" => "running",
          "request_id" => request["request_id"],
          "tool_call_id" => tool_call_id,
          "provider" => provider,
          "alias" => alias_,
          "state" => state,
          "authorization_url" => authorization_url,
          "expires_at" => expires_at,
          "message" => "oauth authorization request is pending",
          "instructions" =>
            "Post the authorization_url to the requester yourself through the current visible reply path; it is not delivered automatically. " <>
              "For an internal Comma conversation, use call(tool=\"im_api.internal.send_message\", params={...}) with connect_id=\"internal\" inside params. For an external provider, call the matching im_api.* operation directly when provider/connect/API are known; use IM discovery/help only when those facts are missing. " <>
              "Ask the user to complete the browser flow, then call oauth.complete_authorization with this state to verify the outcome.",
          "reason" => reason
        })

      wait =
        Waits.build(
          "oauth authorization: " <> provider <> "/" <> alias_,
          @user_interaction_auto_wait_seconds,
          "auto_wait",
          %{
            "tool_call_id" => tool_call_id,
            "tool_name" => "oauth.request_authorization"
          }
        )

      wait_set = Waits.event(session_id(ctx), wait)

      {content,
       [
         %{
           "type" => "async_tool_call_started",
           "session_id" => session_id(ctx),
           "tool_call_id" => tool_call_id,
           "tool_name" => "oauth.request_authorization",
           "input" =>
             Jason.encode!(%{
               "provider" => provider,
               "alias" => alias_,
               "reason" => reason,
               "scopes" => scopes,
               "timeout_seconds" => timeout_seconds
             }),
           "status" => "running",
           "completion_mode" => "external_callback",
           "started_at" => now,
           "auto_wait_seconds" => @user_interaction_auto_wait_seconds
         }
         |> Map.merge(CapabilityRequestStore.execution_fields(request)),
         wait_set
       ]}
    end
  end

  defp timeout_seconds(nil), do: @default_timeout_seconds

  defp timeout_seconds(n) when is_integer(n) do
    if n < 1 or n > @max_timeout_seconds do
      raise "timeout_seconds must be between 1 and #{@max_timeout_seconds}"
    else
      n
    end
  end

  defp timeout_seconds(_), do: raise("timeout_seconds must be an integer")

  # willow cleanedScopes: trim and drop empties.
  defp clean_scopes(list) when is_list(list) do
    list |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == ""))
  end

  defp clean_scopes(_), do: []

  defp oauth_context!(agent_id) do
    case OAuthStore.agent_oauth_context(agent_id) do
      {:ok, %{tenant: tenant, group_id: group_id}} ->
        if String.trim(to_string(tenant)) == "", do: raise("agent has no tenant")
        if String.trim(to_string(group_id)) == "", do: raise("agent has no group")
        {tenant, group_id}

      {:error, :oauth_store_not_configured} ->
        raise "oauth authorization is not configured for this runtime"

      {:error, why} ->
        raise "load agent: #{format_reason(why)}"
    end
  end

  defp provider_app!(tenant, provider) do
    case OAuthStore.provider_app(tenant, provider) do
      {:ok, %{"client_id" => cid, "client_secret" => secret} = app}
      when is_binary(cid) and cid != "" and is_binary(secret) and secret != "" ->
        app

      {:ok, _incomplete} ->
        raise not_configured_message(provider)

      {:error, :not_configured} ->
        raise not_configured_message(provider)

      {:error, why} ->
        raise "load provider app: #{format_reason(why)}"
    end
  end

  # willow request_oauth_auth.go — exact wording.
  defp not_configured_message(provider) do
    "oauth provider #{provider} is not configured for this tenant; an admin needs to add it in the OAuth settings"
  end

  # 32 random bytes, base64url without padding (willow oauth.NewState /
  # NewCodeVerifier equivalents).
  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # ---- oauth.complete_authorization (willow complete_oauth_auth.go) ----

  @doc false
  def complete_oauth_authorization(args, ctx) do
    state = required_arg(args, "state")

    group_id =
      case OAuthStore.agent_oauth_context(ctx.agent_id) do
        {:ok, %{group_id: group_id}} when is_binary(group_id) and group_id != "" ->
          group_id

        _ ->
          raise "oauth.complete_authorization requires agent and group context"
      end

    record =
      case AuthState.get(state) do
        {:ok, record} ->
          record

        {:error, :not_found} ->
          raise "authorization state not found; call oauth.request_authorization again"

        {:error, why} ->
          raise "load authorization state: #{format_reason(why)}"
      end

    # Don't leak that a different group's row exists (willow parity).
    if record["group_id"] != group_id do
      raise "authorization state not found; call oauth.request_authorization again"
    end

    if record["origin"] != "agent" do
      raise "authorization state was not initiated by an agent; use oauth.request_authorization to start an agent-initiated flow"
    end

    provider = record["provider"]
    alias_ = record["alias"]

    case record["status"] do
      "completed" ->
        out =
          %{"status" => "completed", "provider" => provider, "alias" => alias_}
          |> put_present("binding_id", record["binding_id"])
          |> put_present("provider_account_name", record["provider_account_name"])

        Jason.encode!(out)

      "failed" ->
        out = %{
          "status" => "failed",
          "provider" => provider,
          "alias" => alias_,
          "error" => record["error"]
        }

        Jason.encode!(out)

      "expired" ->
        out = %{
          "status" => "expired",
          "provider" => provider,
          "alias" => alias_,
          "message" =>
            "authorization expired; call oauth.request_authorization to start a fresh flow"
        }

        Jason.encode!(out)

      # pending, or consumed (callback claimed but not yet completed) —
      # willow's default branch.
      _ ->
        Jason.encode!(%{
          "status" => "pending",
          "provider" => provider,
          "alias" => alias_,
          "expires_at" => record["expires_at"],
          "message" =>
            "authorization is still pending; ask the user to complete the browser flow, then call oauth.complete_authorization again"
        })
    end
  end

  # ---- delete_oauth_credential ----

  @doc false
  def delete_oauth_credential(args, ctx) do
    provider = args |> required_arg("provider") |> String.downcase()
    alias_ = required_arg(args, "alias")

    {tenant, group_id} = oauth_context!(ctx.agent_id)

    bindings =
      case OAuthStore.bindings_for_group(group_id) do
        {:ok, list} -> list
        {:error, reason} -> raise "list oauth bindings: #{format_reason(reason)}"
      end

    match =
      Enum.find(bindings, fn binding ->
        to_string(binding["provider"]) == provider and to_string(binding["alias"]) == alias_
      end)

    case match do
      nil ->
        not_found_result(provider, alias_)

      %{"binding_id" => binding_id} ->
        case OAuthStore.delete_binding(tenant, group_id, binding_id) do
          :ok ->
            Jason.encode!(%{
              "status" => "deleted",
              "provider" => provider,
              "alias" => alias_,
              "binding_id" => binding_id
            })

          {:error, :not_found} ->
            not_found_result(provider, alias_)

          {:error, :oauth_store_not_configured} ->
            raise "oauth authorization is not configured for this runtime"

          {:error, reason} ->
            raise "delete oauth binding: #{format_reason(reason)}"
        end
    end
  end

  defp not_found_result(provider, alias_) do
    Jason.encode!(%{
      "status" => "not_found",
      "provider" => provider,
      "alias" => alias_,
      "message" => "no matching oauth credential to delete"
    })
  end

  # ---- helpers ----

  defp session_id(ctx) do
    case Map.get(ctx, :session_id) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: raise("ctx.session_id is required"), else: value

      _ ->
        raise "ctx.session_id is required"
    end
  end

  defp adapters_fn do
    Application.get_env(
      :salix_agent,
      :oauth_adapters_fn,
      &SalixStore.OAuth.Adapters.for_provider/1
    )
  end

  defp create_capability_request!(attrs) do
    case CapabilityRequestStore.create_capability_request(attrs) do
      {:ok, request} -> request
      {:error, reason} -> raise "create capability request: #{format_reason(reason)}"
    end
  end

  defp tool_call_id(ctx) do
    case Map.get(ctx, :tool_call_id) do
      id when is_binary(id) and id != "" -> id
      _ -> random_id()
    end
  end

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp raw(args, key), do: Map.get(args, key, Map.get(args, String.to_atom(key)))

  defp arg(args, key), do: to_string(raw(args, key) || "")

  # Server-side mirror of the schema's `required` list (SalixAgent.Tools.Schemas).
  defp required_arg(args, key) do
    case args |> arg(key) |> String.trim() do
      "" -> raise "'#{key}' is required"
      value -> value
    end
  end
end
