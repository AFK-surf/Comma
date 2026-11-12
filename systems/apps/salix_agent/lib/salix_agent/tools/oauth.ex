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
    * `oauth.request_authorization`'s result labels itself `{public}` in a
      labelling session. `SalixAgent.IFC.Destination` gives the tool no effect,
      so no `ifc.sources` is declared and the round's label would join the whole
      context; one `agent_private` item then makes the link unsendable anywhere.
      The result holds what the runtime just minted, so the model's `reason`
      is not echoed in it.
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

  alias SalixAgent.{CapabilityRequestStore, OAuthCredentials, OAuthStore, Waits}
  alias SalixAgent.Tools.AsyncPolicy
  alias SalixIFC.{Codec, Label}
  alias SalixStore.OAuth.AuthState

  # willow request_oauth_auth.go: default 10min, max 30min.
  @default_timeout_seconds 600
  @max_timeout_seconds 1800
  # A card the person fills in: they may first have to find the value in a console.
  @input_timeout_seconds @max_timeout_seconds
  # The account comes through the customer's own app: its card first asks for the app.
  @own_app_consoles %{
    "lark" => "https://open.larksuite.com/app",
    "feishu" => "https://open.feishu.cn/app"
  }
  # A station's call waits this long for the person; the call's own deadline is a little longer.
  @station_wait_ms 18 * 60 * 1000
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
         "An entry with usable=false is another person's. Only entries with enabled=true and usable=true can be passed into credential_env on compute.exec, process.start, or env.exec. Token values are never returned.",
       &__MODULE__.list_oauth_credentials/2, @normal_auto_wait_seconds},
      {"oauth.request_authorization",
       "Start a managed OAuth authorization flow for this agent group.\n\n" <>
         "Returns an authorization URL and waits until the user completes or rejects it. " <>
         "In a Comma conversation the app shows the user a request card with the reason and an authorize button: do not post the URL there. For an external provider the URL is NOT surfaced automatically: post it to the requester yourself; call the matching im_api.* operation directly when provider/connect/API are known, and use IM discovery/help only when those facts are missing. " <>
         "Returns a deferred result with the provider binding when completed. " <>
         "Use the resulting provider and alias in a credential_env entry on compute.exec, process.start, or env.exec, with env_var and value. " <>
         "The credential belongs to the person who asked: only work done for them can use it. Pass shared: true only for an account the whole group is meant to use.",
       &__MODULE__.request_oauth_authorization/2, @user_interaction_auto_wait_seconds,
       @visible_request_opts},
      {"oauth.login_card", "Used by the sandbox's login tool: do not call it yourself.",
       &__MODULE__.login_card/2, @normal_auto_wait_seconds, @visible_request_opts},
      {"oauth.complete_authorization",
       "Verify the outcome of an authorization flow previously started by oauth.request_authorization.\n\n" <>
         "Returns status=completed with the (provider, alias) once the user finishes the browser flow, status=pending if they have not finished yet, or status=failed/expired with an error reason. " <>
         "Idempotent: completed/failed flows return the same result on subsequent calls until the auth state row is purged.",
       &__MODULE__.complete_oauth_authorization/2, @normal_auto_wait_seconds},
      {"oauth.define_provider",
       "Define this Workspace's own OAuth provider as custom.<key>, for a service Comma has no built-in provider for: its client id and standard OAuth 2.0 endpoints. " <>
         "Then use it with oauth.request_authorization; the person registers the redirect_uri this returns with the service. " <>
         "A client secret never goes in arguments: the person enters it first as a secret (oauth.request_authorization with provider secret), and client_secret_alias names that credential.",
       &__MODULE__.define_provider/2, @normal_auto_wait_seconds, @visible_request_opts},
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
              |> Enum.map(&credential_entry(&1, OAuthCredentials.acting_for(ctx)))
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

  defp credential_entry(binding, acting_for) do
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
    |> Map.put("personal", binding["owner"] not in [nil, ""])
    |> Map.put("usable", OAuthCredentials.usable_by?(binding, acting_for))
    |> put_scopes(binding["scopes"])
    |> put_fields(binding["fields"])
  end

  # A secret with fields: what each is called (its credential_env value) and
  # whether it is a secret. Never a value.
  defp put_fields(%{"usage" => _} = map, [_ | _] = fields) do
    map
    |> Map.put("fields", Enum.map(fields, &Map.take(&1, ["name", "secret"])))
    |> Map.put("usage", fields_usage_hint(map["provider"], map["alias"], fields))
  end

  defp put_fields(map, [_ | _] = fields),
    do: Map.put(map, "fields", Enum.map(fields, &Map.take(&1, ["name", "secret"])))

  defp put_fields(map, _fields), do: map

  defp fields_usage_hint(provider, alias_, fields) do
    entries =
      Enum.map(fields, fn %{"name" => name} ->
        %{
          "env_var" => String.upcase(name),
          "provider" => provider,
          "alias" => alias_,
          "value" => name
        }
      end)

    "credential_env for compute.exec, process.start, or env.exec, one entry per field, its name as value: " <>
      Jason.encode!(entries)
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

  # A credential is the person's who asked for it unless the request shares it
  # with the group; no person to own it means it has to say so.
  defp requested_owner!(args, ctx) do
    cond do
      raw(args, "shared") == true ->
        nil

      owner = OAuthCredentials.acting_for(ctx) ->
        owner

      true ->
        raise "no person asked for this authorization, so it has no owner; pass shared: true for a credential the whole group may use"
    end
  end

  # Authorizing an alias replaces its connection and revokes the old one, so
  # nobody takes over another person's alias.
  defp ensure_alias_free!(group_id, provider, alias_, owner) do
    case OAuthStore.bindings_for_group(group_id) do
      {:ok, bindings} ->
        taken =
          Enum.find(bindings, fn binding ->
            to_string(binding["provider"]) == provider and to_string(binding["alias"]) == alias_
          end)

        if taken && not OAuthCredentials.usable_by?(taken, owner) do
          raise "alias #{alias_} is another person's credential; choose another alias"
        end

      {:error, reason} ->
        raise "list oauth bindings: #{format_reason(reason)}"
    end
  end

  @doc false
  def define_provider(args, ctx) do
    key = args |> required_arg("key") |> String.downcase()
    provider = "custom." <> key
    {tenant, _group_id} = oauth_context!(ctx.agent_id)

    attrs =
      args
      |> Map.take(
        ~w(client_id authorize_url token_url device_authorization_url scopes client_auth)
      )
      |> maybe_put_client_secret(args, ctx)

    case OAuthStore.define_provider(tenant, provider, attrs) do
      {:ok, defined} ->
        Jason.encode!(%{
          "provider" => defined["provider"],
          "redirect_uri" => redirect_uri!(provider)
        })

      {:error, {:bad_request, message}} ->
        raise message

      {:error, why} ->
        raise "define provider: #{format_reason(why)}"
    end
  end

  defp maybe_put_client_secret(attrs, args, ctx) do
    case arg_or_nil(args, "client_secret_alias") do
      nil ->
        attrs

      secret_alias ->
        reference = %{
          "env_var" => "CLIENT_SECRET",
          "provider" => "secret",
          "alias" => secret_alias,
          "value" => "access_token"
        }

        case OAuthCredentials.resolve_for_call(ctx, ctx.agent_id, [reference]) do
          {:ok, %{"CLIENT_SECRET" => secret}} -> Map.put(attrs, "client_secret", secret)
          {:error, message} -> raise message
        end
    end
  end

  defp arg_or_nil(args, key) do
    case raw(args, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp redirect_uri!(provider) do
    base = String.trim(to_string(OAuthStore.public_base_url() || ""))

    if base == "" do
      raise "public_base_url is not configured; an admin needs to set the server's public base URL before OAuth flows can run"
    end

    # willow buildOAuthRedirectURI: base path + /v1/oauth/{provider}/callback.
    String.trim_trailing(base, "/") <> "/v1/oauth/" <> provider <> "/callback"
  end

  @doc false
  def request_oauth_authorization(args, ctx) do
    provider = args |> required_arg("provider") |> String.downcase()
    alias_ = required_arg(args, "alias")
    required_arg(args, "reason")

    {_tenant, group_id} = oauth_context!(ctx.agent_id)
    owner = requested_owner!(args, ctx)
    ensure_alias_free!(group_id, provider, alias_, owner)

    if raw(args, "flow") == "device",
      do: request_device_authorization(args, ctx, provider, alias_, owner),
      else: request_browser_authorization(args, ctx, provider, alias_, owner)
  end

  # There is no callback to wait for: the person confirms on the provider's
  # page, and oauth.complete_authorization asks the provider once per call.
  defp request_device_authorization(args, ctx, provider, alias_, owner) do
    {tenant, group_id} = oauth_context!(ctx.agent_id)
    app = provider_app!(tenant, provider)
    scopes = clean_scopes(raw(args, "scopes"))

    adapter =
      case adapters_fn().(provider) do
        {:ok, adapter} -> adapter
        {:error, _} -> raise "oauth provider #{inspect(provider)} is not supported"
      end

    unless Code.ensure_loaded?(adapter) and function_exported?(adapter, :device_authorize, 2) do
      raise "oauth provider #{provider} has no device flow; omit flow"
    end

    device =
      case adapter.device_authorize(app, %{"scopes" => scopes}) do
        {:ok, device} -> device
        {:error, why} -> raise "start device authorization: #{format_reason(why)}"
      end

    state = random_token()
    now = SystemsClock.system_time(:millisecond)

    expires_at =
      now +
        min(int_seconds(device["expires_in"]) || @default_timeout_seconds, @max_timeout_seconds) *
          1000

    :ok =
      AuthState.create(%{
        "state" => state,
        "tenant" => tenant,
        "group_id" => group_id,
        "agent_id" => ctx.agent_id,
        "session_id" => request_session_id(ctx),
        "provider" => provider,
        "alias" => alias_,
        "owner" => owner,
        "scopes" => scopes,
        "device_code" => device["device_code"],
        "origin" => "agent",
        "status" => "pending",
        "expires_at" => expires_at,
        "created_at" => now
      })

    Jason.encode!(%{
      "status" => "pending",
      "state" => state,
      "user_code" => device["user_code"],
      "verification_uri" => device["verification_uri"],
      "verification_uri_complete" => device["verification_uri_complete"],
      "instructions" =>
        "Send the verification link and user code to the person. After they say they confirmed, call oauth.complete_authorization with state."
    })
  end

  defp int_seconds(value) when is_integer(value) and value > 0, do: value
  defp int_seconds(_value), do: nil

  defp request_browser_authorization(args, ctx, provider, alias_, owner) do
    reason = required_arg(args, "reason")
    scopes = clean_scopes(raw(args, "scopes"))

    {tenant, group_id} = oauth_context!(ctx.agent_id)
    surface = conversation_surface(ctx)
    redirect_uri = redirect_uri!(provider)
    fields = requested_fields!(args, provider)
    input = if fields == [], do: request_input(args, tenant, provider, surface, redirect_uri)

    timeout_seconds =
      case raw(args, "timeout_seconds") do
        nil when is_map(input) -> @input_timeout_seconds
        seconds -> timeout_seconds(seconds)
      end

    app = if input["kind"] == "app", do: %{}, else: provider_app!(tenant, provider)

    state = random_token()
    code_verifier = random_token()
    code_challenge = Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)

    adapter =
      case adapters_fn().(provider) do
        {:ok, adapter} -> adapter
        {:error, _} -> raise "oauth provider #{inspect(provider)} is not supported"
      end

    # With no app yet there is no page: the card asks for the app, then has one.
    authorization_url =
      if input["kind"] == "app" do
        nil
      else
        case adapter.authorization_url(app, %{
               "redirect_uri" => redirect_uri,
               "state" => state,
               "scopes" => scopes,
               "code_challenge" => code_challenge
             }) do
          {:ok, url} -> url
          {:error, why} -> raise "build authorization url: #{format_reason(why)}"
        end
      end

    now = SystemsClock.system_time(:millisecond)
    expires_at = now + timeout_seconds * 1000

    record = %{
      "state" => state,
      "tenant" => tenant,
      "group_id" => group_id,
      "agent_id" => ctx.agent_id,
      "session_id" => request_session_id(ctx),
      "provider" => provider,
      "alias" => alias_,
      "owner" => owner,
      "fields" => fields,
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
        create_capability_request!(
          %{
            "tenant_id" => tenant,
            "group_id" => group_id,
            "source_agent_id" => ctx.agent_id,
            "source_session_id" => record["session_id"],
            "tool_call_id" => tool_call_id,
            "request_type" => "oauth_authorization",
            "request_payload" => %{
              "oauth_authorization" =>
                %{
                  "provider" => provider,
                  "alias" => alias_,
                  "state" => state,
                  "reason" => reason,
                  "scopes" => scopes
                }
                |> put_present("authorization_url", authorization_url)
                |> then(&if(input, do: Map.put(&1, "input", input), else: &1))
                |> then(&if(station_call?(ctx), do: Map.put(&1, "station_call", true), else: &1))
            },
            "expires_at" => div(expires_at, 1000)
          }
          |> Map.merge(surface || %{})
        )

      if station_call?(ctx) do
        await_station_request(request, state, provider, alias_)
      else
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
            "instructions" => authorization_instructions(surface)
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
        |> public_link(ctx)
      end
    end
  end

  # A Worker in a station has no Session here to be told later: its call waits
  # for the person, with the card in its Task. Still unanswered when the call
  # must return, the Worker ends its turn and looks again when it next runs.
  defp await_station_request(request, state, provider, alias_) do
    case OAuthStore.await_request(request, @station_wait_ms) do
      {:ok, %{"result" => %{"content" => content}}} when is_binary(content) ->
        content

      _still_waiting ->
        Jason.encode!(%{
          "status" => "pending",
          "provider" => provider,
          "alias" => alias_,
          "state" => state,
          "message" =>
            "The card is still waiting for the person. End your turn with need_human; when you run again, call oauth.complete_authorization with this state."
        })
    end
  end

  defp station_call?(ctx), do: is_binary(ctx[:task_conversation_id])

  @doc """
  The card of a CLI login that runs in a Task's sandbox (the station's
  `logins/tool.ts`): put up or changed as the login goes, and ended with it. It
  is a request to connect an account whose `input` says what the person does, so
  a client that does not draw it still offers the page. The login's id is the
  flow's `state`, and makes this the one card of that login.
  """
  def login_card(args, ctx) do
    unless station_call?(ctx), do: raise("only a sandbox's login tool puts up this card")
    {tenant, group_id} = oauth_context!(ctx.agent_id)
    login = required_arg(args, "login")
    program = required_arg(args, "program")

    case arg_or_nil(args, "ended") do
      nil ->
        input =
          cond do
            raw(args, "paste") == true -> %{"kind" => "paste"}
            is_binary(arg_or_nil(args, "code")) -> %{"kind" => "device", "code" => args["code"]}
            true -> %{"kind" => "open"}
          end

        request =
          create_capability_request!(
            %{
              "tenant_id" => tenant,
              "group_id" => group_id,
              "source_agent_id" => ctx.agent_id,
              "source_session_id" => SalixStore.Ids.new_session_id(),
              "tool_call_id" => "login:" <> login,
              "request_id" => "cap-login-" <> login,
              "request_type" => "oauth_authorization",
              "request_payload" => %{
                "oauth_authorization" =>
                  %{
                    "provider" => "cli",
                    "alias" => program,
                    "state" => login,
                    "login" => login,
                    "owner" => OAuthCredentials.acting_for(ctx),
                    "reason" => required_arg(args, "reason"),
                    "scopes" => [],
                    "station_call" => true,
                    "input" => input
                  }
                  |> put_present("authorization_url", https_url(arg_or_nil(args, "url")))
              },
              "expires_at" => div(SystemsClock.system_time(:millisecond), 1000) + 15 * 60
            }
            |> Map.merge(conversation_surface(ctx))
          )

        Jason.encode!(%{"request" => request["request_id"]})

      "done" ->
        {:ok, _ended} =
          SalixAgent.CapabilityRequests.complete_oauth_authorization(group_id, tenant, %{
            "state" => login
          })

        Jason.encode!(%{"ended" => true})

      _failed ->
        _ =
          SalixAgent.CapabilityRequests.fail_login(group_id, "cap-login-" <> login, tenant)

        Jason.encode!(%{"ended" => true})
    end
  end

  # A station's call has no Session of its own in Salix.
  defp request_session_id(ctx) do
    if station_call?(ctx), do: SalixStore.Ids.new_session_id(), else: session_id(ctx)
  end

  # The values a secret asks for by name. A card has one input, so a request
  # with fields has no input: every surface gives the link to Salix's form.
  defp requested_fields!(args, provider) do
    case {raw(args, "fields"), provider} do
      {nil, _provider} ->
        []

      {fields, "secret"} ->
        case SalixStore.OAuth.Adapters.Secret.fields(fields) do
          {:ok, fields} -> fields
          {:error, message} -> raise message
        end

      {_fields, _provider} ->
        raise "fields is only for provider secret"
    end
  end

  # What the person's card asks them to fill in, before anything else happens.
  # Only a card asks for an app: a link in a provider chat proves no one's
  # standing in the Workspace (`CommaWeb.AgentRequestEndpoints`).
  defp request_input(args, _tenant, "secret", surface, _redirect_uri) when is_map(surface) do
    %{"kind" => "secret"}
    |> put_present("label", arg_or_nil(args, "label"))
    |> put_present("help_url", https_url(arg_or_nil(args, "help_url")))
  end

  defp request_input(args, tenant, provider, surface, redirect_uri)
       when is_map(surface) and is_map_key(@own_app_consoles, provider) do
    wanted =
      if raw(args, "own_app") == true,
        do: not OAuthStore.own_provider_app?(tenant, provider),
        else: match?({:error, :not_configured}, OAuthStore.provider_app(tenant, provider))

    if wanted do
      %{
        "kind" => "app",
        "help_url" => @own_app_consoles[provider],
        "redirect_uri" => redirect_uri
      }
    end
  end

  defp request_input(_args, _tenant, _provider, _surface, _redirect_uri), do: nil

  defp https_url("https://" <> _ = url), do: url
  defp https_url(_url), do: nil

  # Silent for a session that is not labelling, as `SalixAgent.IFC.ConnectorLabels` is.
  defp public_link({content, events} = result, ctx) do
    if is_map(Map.get(ctx, :ifc)) do
      {:tool_ifc, content, events, %{"label" => Codec.encode_label(Label.new([:public]))}}
    else
      result
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

  defp poll_device_once(%{"status" => "pending", "device_code" => code} = record)
       when is_binary(code) and code != "" do
    case OAuthStore.poll_device(record) do
      {:ok, polled} -> polled
      {:error, why} -> raise "check device authorization: #{format_reason(why)}"
    end
  end

  defp poll_device_once(record), do: record

  defp provider_app!(_tenant, "secret"), do: %{}

  defp provider_app!(tenant, "custom." <> _ = provider) do
    case OAuthStore.provider_app(tenant, provider) do
      {:ok, %{} = app} -> app
      {:error, :not_configured} -> raise "#{provider} is not defined; call oauth.define_provider"
      {:error, why} -> raise "load provider app: #{format_reason(why)}"
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
  defp random_token, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)

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

    record = poll_device_once(record)
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

      %{"binding_id" => binding_id} = binding ->
        unless OAuthCredentials.usable_by?(binding, OAuthCredentials.acting_for(ctx)) do
          raise "this credential belongs to another person; only they can delete it"
        end

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
    SystemsRuntime.get_env(
      :salix_agent,
      :oauth_adapters_fn,
      &SalixStore.OAuth.Adapters.for_provider/1
    )
  end

  # A request from a Comma conversation is shown there as a card, under the reply to the message the turn serves.
  # A station's call has no message of its own: its card goes with the Task's
  # latest, so its receipt has a reply to stay under once it ends.
  @doc false
  def conversation_surface(%{task_conversation_id: conversation_id} = ctx)
      when is_binary(conversation_id) and conversation_id != "" do
    %{
      "surface_kind" => "conversation",
      "surface_ref" =>
        %{"conversation_id" => conversation_id}
        |> put_present("message_id", latest_task_message(ctx, conversation_id))
    }
  end

  def conversation_surface(ctx) do
    case Map.get(ctx, :trusted_origin) do
      %{"provider" => "internal", "conversation_id" => conversation_id} = origin
      when is_binary(conversation_id) and conversation_id != "" ->
        %{
          "surface_kind" => "conversation",
          "surface_ref" =>
            %{"conversation_id" => conversation_id}
            |> put_present("message_id", origin["message_id"])
        }

      _ ->
        nil
    end
  end

  defp latest_task_message(ctx, conversation_id) do
    {_tenant, group_id} = oauth_context!(ctx.agent_id)
    OAuthStore.latest_message(group_id, conversation_id)
  end

  defp authorization_instructions(nil),
    do:
      "Post the authorization_url to the requester yourself through the current visible reply path; it is not delivered automatically. " <>
        "The link carries nothing from the conversation, so send it with ifc sources []. " <>
        "Call the matching im_api.* operation directly when provider/connect/API are known; use IM discovery/help only when those facts are missing. " <>
        "Ask the user to complete the browser flow, then call oauth.complete_authorization with this state to verify the outcome."

  defp authorization_instructions(_surface),
    do:
      "The Comma app shows the user a card for this request, with your reason and an authorize button; do not post the authorization_url yourself. " <>
        "This call returns when the user connects the account or declines."

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

  defp random_id, do: SystemsRuntime.Proc.random_bytes(8) |> Base.encode16(case: :lower)

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
