defmodule SalixAgent.OAuthCredentials do
  @moduledoc """
  Exec `credential_env` resolver — the Salix port of willow's
  `internal/oauth/resolver.go` (`Resolver.ResolveAll`, `maybeRefresh`,
  `ResolveExecCredentials`): turns model-authored credential references
  (`{env_var, provider, alias, value}`) into resolved env values usable at
  exec dispatch time. The model never sees secret values; the resolved map is
  merged into the connector exec env and the `credential_env` field is never
  forwarded.

  Refresh is gated by storage CAS, not an in-process mutex: an expiring
  connection goes through `SalixStore.OAuth.valid_token/3`, whose `If-Match`
  write serializes concurrent refreshers across nodes (willow's
  `UpdateOAuthConnectionTokensCAS` + reload-on-CAS-miss). Willow's 60s
  `refreshLeeway` is preserved through `valid_token`'s `leeway_ms`.

  Error strings follow willow's `ResolveError` verbatim:
  `oauth credential {provider}/{alias} for {env_var}: {reason}`.

  ## Intentional divergences from willow

    * The CAS refresh path is `SalixStore.OAuth.valid_token/3` over the S3
      connection record; a refresh response that carries no/blank
      `access_token` still performs a version-bump write of the unchanged
      record (willow skips the write entirely in that case). Refresh fields
      that are nil/blank (`refresh_token`, `token_type`, empty `scopes`) are
      dropped before the merge so authorization-time values are preserved,
      matching willow's token_type/scopes carry-over.
    * Bindings come from the `SalixAgent.OAuthStore` seam
      (`bindings_for_group/1`), which is already tenant-scoped; willow's
      per-binding "binding is not owned by this tenant" check has no
      equivalent and is dropped.
    * Adapters resolve through the `:oauth_adapters_fn` app-env seam
      (default `SalixStore.OAuth.Adapters.for_provider/1`) and the refresh
      call through `:oauth_refresher_fn` (default `adapter.refresh(app,
      conn)`) — test seams willow covers with injected registry/clock.
    * Willow detects `invalid_grant` by string-matching the refresh error;
      Salix adapters signal `{:error, :reauthorization_required}` directly
      (contract C1). The string match is retained as a fallback for binary
      error reasons. On that failure the connection record's `"status"` is
      flipped to `"reauthorization_required"` through
      `SalixStore.OAuth.mark_reauthorization_required/2`, which skips the
      mark when a concurrent refresher already rotated the refresh token.
    * Willow's lazy tenant-config load is replaced by a lazy
      `OAuthStore.provider_app/2` call — only made when an entry actually
      triggers refresh.
  """

  alias SalixAgent.OAuthStore
  alias SalixIFC.Codec

  # willow resolver.go: refreshLeeway = 60 * time.Second.
  @refresh_leeway_ms 60_000
  @redacted "[redacted credential]"
  @remote_mcp "remote_mcp"

  @typedoc "One normalized credential reference."
  @type ref :: %{
          env_var: String.t(),
          provider: String.t(),
          alias: String.t(),
          value: String.t()
        }

  @doc """
  Resolve every `credential_env` entry to a `%{env_var => value}` map.

  `entries` is the raw list the model passed (string- or atom-keyed maps with
  `env_var` / `provider` / `alias` / `value`). On any resolution error the
  partial result is discarded and `{:error, message}` is returned for the
  offending entry (willow: ResolveAll discards partial output).

  Options: `:acting_for` — the encoded person a tool call acts for, or nil for
  none; a binding with an `"owner"` then resolves only for that person. Salix's
  own reads (a Lark connect reading as a signed-in member) pass no `:acting_for`
  and label what they read. `:now` — clock in ms (default
  `SystemsClock.system_time/1`).
  """
  @spec resolve(String.t(), term(), keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def resolve(agent_id, entries, opts \\ [])

  def resolve(_agent_id, entries, _opts) when not is_list(entries),
    do: {:error, "invalid credential_env: must be an array"}

  # Explicitly empty array is a no-op (willow: stripped before forwarding).
  def resolve(_agent_id, [], _opts), do: {:ok, %{}}

  def resolve(agent_id, entries, opts) do
    with {:ok, resolved} <- resolve_entries(agent_id, entries, opts),
         do: {:ok, Map.new(resolved, fn {env_var, value, _secret} -> {env_var, value} end)}
  end

  defp resolve_entries(_agent_id, entries, _opts) when not is_list(entries),
    do: {:error, "invalid credential_env: must be an array"}

  defp resolve_entries(_agent_id, [], _opts), do: {:ok, []}

  defp resolve_entries(agent_id, entries, opts) do
    with {:ok, refs} <- normalize_entries(entries),
         {:ok, %{tenant: tenant, group_id: group_id}} <- agent_context(agent_id),
         {:ok, bindings} <- group_bindings(group_id) do
      Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
        case resolve_one(ref, tenant, bindings, opts) do
          {:ok, value, secret} -> {:cont, {:ok, [{ref.env_var, value, secret} | acc]}}
          {:error, reason} -> {:halt, {:error, resolve_error(ref, reason)}}
        end
      end)
      |> case do
        {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
        error -> error
      end
    end
  end

  @doc """
  `resolve/3` for a tool call that hands the values to a subprocess or a
  request: a personal credential resolves only for its owner.
  """
  @spec resolve_for_call(map(), String.t(), term()) ::
          {:ok, %{String.t() => String.t()}} | {:error, String.t()}
  def resolve_for_call(ctx, agent_id, entries),
    do: resolve(agent_id, entries, acting_for: acting_for(ctx))

  @doc """
  `resolve_for_call/3` for a command whose output reaches the model: also the
  values `redact/2` takes out of it. A secret's field marked not secret (a
  tenant id, a base URL) stays readable in the output.
  """
  @spec resolve_for_command(map(), String.t(), term()) ::
          {:ok, %{String.t() => String.t()}, [String.t()]} | {:error, String.t()}
  def resolve_for_command(ctx, agent_id, entries) do
    with {:ok, resolved} <- resolve_entries(agent_id, entries, acting_for: acting_for(ctx)) do
      {:ok, Map.new(resolved, fn {env_var, value, _secret} -> {env_var, value} end),
       for({_env_var, value, true} <- resolved, do: value)}
    end
  end

  @doc """
  The person a tool call acts for, encoded as a credential's `"owner"` is, or
  nil: an agent, or a delivery no person authored, is nobody's person.
  """
  @spec acting_for(map()) :: String.t() | nil
  def acting_for(ctx) do
    ctx[:trusted_origin] |> SalixAgent.IFC.principal() |> person_ref()
  end

  defp person_ref({:provider_user, _, _} = person), do: Codec.encode_principal!(person)
  defp person_ref({:comma_user, _} = person), do: Codec.encode_principal!(person)
  # A station or a schedule acts for the person it was delegated by.
  defp person_ref({:schedule, _, person}), do: person_ref(person)
  defp person_ref(_), do: nil

  @doc "True when the person `acting_for` (encoded, or nil) may use `binding`."
  @spec usable_by?(map(), String.t() | nil) :: boolean()
  def usable_by?(binding, acting_for) do
    case binding["owner"] do
      owner when owner in [nil, ""] -> true
      owner -> owner == acting_for
    end
  end

  @doc """
  `result` with every credential value in `values` replaced, in each string of
  it. A command can print its environment; what it prints reaches the model and
  the archive.
  """
  @spec redact(term(), [String.t()]) :: term()
  def redact(result, values) do
    case Enum.filter(values, &(is_binary(&1) and &1 != "")) do
      [] -> result
      values -> scrub(result, values)
    end
  end

  defp scrub(text, values) when is_binary(text), do: String.replace(text, values, @redacted)
  defp scrub(list, values) when is_list(list), do: Enum.map(list, &scrub(&1, values))

  defp scrub(%{} = map, values),
    do: Map.new(map, fn {key, value} -> {key, scrub(value, values)} end)

  defp scrub(other, _values), do: other

  # ---- entry normalization (willow ResolveExecCredentials) ----

  defp normalize_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn entry, {:ok, acc, seen} ->
      with {:ok, ref} <- normalize_entry(entry) do
        if MapSet.member?(seen, ref.env_var) do
          {:halt,
           {:error, "oauth credential_env contains duplicate env_var #{inspect(ref.env_var)}"}}
        else
          {:cont, {:ok, [ref | acc], MapSet.put(seen, ref.env_var)}}
        end
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, refs, _seen} -> {:ok, Enum.reverse(refs)}
      {:error, _} = err -> err
    end
  end

  defp normalize_entry(entry) when is_map(entry) do
    env_var = entry |> field("env_var") |> String.trim()

    if env_var == "" do
      {:error, "oauth credential_env contains empty env_var"}
    else
      {:ok,
       %{
         env_var: env_var,
         provider: entry |> field("provider") |> String.trim() |> String.downcase(),
         alias: entry |> field("alias") |> String.trim(),
         value: entry |> field("value") |> String.trim()
       }}
    end
  end

  defp normalize_entry(_entry),
    do: {:error, "invalid credential_env: entries must be objects"}

  defp field(entry, key),
    do: to_string(Map.get(entry, key, Map.get(entry, String.to_atom(key))) || "")

  # ---- group context ----

  defp agent_context(agent_id) do
    case OAuthStore.agent_oauth_context(agent_id) do
      {:ok, %{tenant: _, group_id: group_id} = ctx} ->
        if String.trim(to_string(group_id)) == "" do
          {:error, "agent has no group; cannot resolve oauth credentials"}
        else
          {:ok, ctx}
        end

      {:error, :oauth_store_not_configured} ->
        {:error, "oauth credentials are not configured for this runtime"}

      {:error, reason} ->
        {:error, "load agent: #{format_reason(reason)}"}
    end
  end

  defp group_bindings(group_id) do
    case OAuthStore.bindings_for_group(group_id) do
      {:ok, bindings} -> {:ok, bindings}
      {:error, reason} -> {:error, "list oauth bindings: #{format_reason(reason)}"}
    end
  end

  # ---- per-entry resolution (willow ResolveAll body) ----

  defp resolve_one(ref, tenant, bindings, opts) do
    with :ok <- require_fields(ref),
         {:ok, binding} <- find_binding(bindings, ref),
         :ok <- check_owner(binding, opts),
         :ok <- check_binding_enabled(binding),
         {:ok, conn_id} <- connection_id(binding),
         {:ok, conn} <- load_connection(conn_id),
         :ok <- check_status(conn),
         {:ok, value} <- resolve_conn_value(ref, tenant, conn_id, conn, opts) do
      {:ok, value, secret_value?(ref, conn)}
    end
  end

  defp resolve_conn_value(ref, tenant, conn_id, conn, opts) do
    if ref.provider == @remote_mcp do
      remote_mcp_value(ref, tenant, conn_id)
    else
      with {:ok, adapter} <- adapter_for(ref.provider),
           do: resolve_value(ref, adapter, tenant, conn_id, conn, opts)
    end
  end

  defp secret_value?(%{provider: "secret", value: value}, conn),
    do: SalixStore.OAuth.Adapters.Secret.secret_value?(conn, value)

  defp secret_value?(_ref, _conn), do: true

  # A remote MCP connection has its own client and endpoints, and its owner
  # refreshes it for the MCP gateway too.
  defp remote_mcp_value(%{value: "access_token"}, tenant, conn_id) do
    case OAuthStore.remote_mcp_token(tenant, conn_id) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, "refresh failed: #{format_reason(reason)}"}
    end
  end

  defp remote_mcp_value(%{value: value}, _tenant, _conn_id),
    do: {:error, "remote_mcp: unsupported credential value #{inspect(value)}"}

  # The app's public id: a CLI that takes a token from its environment asks
  # which app the token is for.
  defp resolve_value(%{value: "client_id"} = ref, _adapter, tenant, _conn_id, _conn, _opts) do
    with {:ok, %{"client_id" => client_id}} <- refresh_app(tenant, ref.provider),
         do: {:ok, client_id}
  end

  defp resolve_value(ref, adapter, tenant, conn_id, conn, opts) do
    with :ok <- validate_value(adapter, ref.value, conn),
         {:ok, conn} <- maybe_refresh(adapter, tenant, ref.provider, conn_id, conn, opts) do
      case adapter.resolve_credential_value(conn, ref.value) do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, format_reason(reason)}
      end
    end
  end

  defp require_fields(%{provider: p, alias: a, value: v}) do
    if p == "" or a == "" or v == "" do
      {:error, "provider, alias, and value are required"}
    else
      :ok
    end
  end

  defp adapter_for(provider) do
    case adapters_fn().(provider) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _} -> {:error, "oauth provider #{inspect(provider)} is not supported"}
    end
  end

  defp find_binding(bindings, ref) do
    bindings
    |> Enum.find(fn b -> b["provider"] == ref.provider and b["alias"] == ref.alias end)
    |> case do
      nil -> {:error, "is not bound to this agent group"}
      binding -> {:ok, binding}
    end
  end

  defp check_owner(binding, opts) do
    if not Keyword.has_key?(opts, :acting_for) or usable_by?(binding, opts[:acting_for]),
      do: :ok,
      else:
        {:error,
         "belongs to another person; the person this work is for connects their own account with oauth.request_authorization under another alias"}
  end

  defp check_binding_enabled(binding) do
    if Map.get(binding, "enabled", true) == false do
      {:error, "is disabled"}
    else
      :ok
    end
  end

  defp connection_id(binding) do
    case String.trim(to_string(binding["connection_id"] || "")) do
      "" -> {:error, "binding has no connection"}
      conn_id -> {:ok, conn_id}
    end
  end

  defp load_connection(conn_id) do
    case SalixStore.OAuth.get(conn_id) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "load connection: #{format_reason(reason)}"}
    end
  end

  defp check_status(conn) do
    case conn["status"] do
      "reauthorization_required" -> {:error, "requires reauthorization"}
      "revoked" -> {:error, "is revoked"}
      _ -> :ok
    end
  end

  defp validate_value(adapter, value, conn) do
    case adapter.validate_credential_value(value, conn["scopes"] || []) do
      :ok -> :ok
      {:error, reason} -> {:error, format_reason(reason)}
    end
  end

  # ---- refresh (willow maybeRefresh) ----

  defp maybe_refresh(adapter, tenant, provider, conn_id, conn, opts) do
    now = opts[:now] || SystemsClock.system_time(:millisecond)
    expires_at = conn["expires_at"]

    cond do
      not is_integer(expires_at) or expires_at <= 0 ->
        # No expiry recorded → never refresh (willow: conn.ExpiresAt == nil).
        {:ok, conn}

      now < expires_at - @refresh_leeway_ms ->
        {:ok, conn}

      true ->
        do_refresh(adapter, tenant, provider, conn_id, conn, now)
    end
  end

  defp do_refresh(adapter, tenant, provider, conn_id, conn, now) do
    with {:ok, app} <- connection_app(tenant, provider, conn) do
      refresher = fn record ->
        case refresher_fn().(adapter, app, record) do
          {:ok, tokens} when is_map(tokens) -> {:ok, sanitize_tokens(tokens, record)}
          {:error, _} = err -> err
          other -> {:error, "unexpected refresh result: #{inspect(other)}"}
        end
      end

      # Refresh tokens that expire within the next 60s, matching willow's
      # eager refresh window.
      case SalixStore.OAuth.valid_token(conn_id, refresher,
             now: now,
             leeway_ms: @refresh_leeway_ms
           ) do
        {:ok, _token} ->
          reload_connection(conn_id)

        {:error, :reauthorization_required} ->
          _ = SalixStore.OAuth.mark_reauthorization_required(conn_id, conn)
          {:error, "refresh failed (reauthorization required)"}

        {:error, reason} ->
          if invalid_grant?(reason) do
            _ = SalixStore.OAuth.mark_reauthorization_required(conn_id, conn)
            {:error, "refresh failed (reauthorization required): #{format_reason(reason)}"}
          else
            {:error, "refresh failed: #{format_reason(reason)}"}
          end
      end
    end
  end

  # A grant made with a member's own bot app refreshes with that app, not the
  # tenant's provider app.
  defp connection_app(tenant, provider, %{"app_source" => source}) when is_map(source),
    do: OAuthStore.source_app(tenant, provider, source)

  defp connection_app(tenant, provider, _conn), do: refresh_app(tenant, provider)

  defp refresh_app(tenant, provider) do
    case OAuthStore.provider_app(tenant, provider) do
      {:ok, %{"client_id" => cid, "client_secret" => secret} = app}
      when is_binary(cid) and cid != "" and is_binary(secret) and secret != "" ->
        {:ok, app}

      # A provider a Workspace defined can be a public client.
      {:ok, %{"client_id" => cid} = app} when is_binary(cid) and cid != "" ->
        if SalixStore.OAuth.Adapters.custom?(provider),
          do: {:ok, app},
          else: {:error, "provider app for #{provider} is not configured"}

      _ ->
        {:error, "provider app for #{provider} is not configured"}
    end
  end

  defp reload_connection(conn_id) do
    case SalixStore.OAuth.get(conn_id) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, "reload connection after refresh: #{format_reason(reason)}"}
    end
  end

  # Drop nil/blank refresh fields so Map.merge in the CAS write preserves the
  # authorization-time values (willow: token_type/scopes carry-over, and an
  # unchanged/blank access token leaves the row alone).
  defp sanitize_tokens(tokens, record) do
    access_token = to_string(tokens["access_token"] || "")

    if access_token == "" or access_token == record["access_token"] do
      %{}
    else
      tokens
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()
      |> then(fn m -> if m["scopes"] in [nil, []], do: Map.delete(m, "scopes"), else: m end)
    end
  end

  # willow resolver.go isInvalidGrant.
  defp invalid_grant?(reason) when is_binary(reason) do
    msg = String.downcase(reason)

    String.contains?(msg, "invalid_grant") or String.contains?(msg, "invalid grant") or
      String.contains?(msg, "expired_token")
  end

  defp invalid_grant?(_), do: false

  # ---- error formatting (willow ResolveError.Error) ----

  defp resolve_error(%{provider: p, alias: a, env_var: env_var}, reason)
       when p != "" and a != "" do
    "oauth credential #{p}/#{a} for #{env_var}: #{reason}"
  end

  defp resolve_error(%{env_var: env_var}, reason),
    do: "oauth credential for #{env_var}: #{reason}"

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  # ---- seams ----

  defp adapters_fn do
    SystemsRuntime.get_env(
      :salix_agent,
      :oauth_adapters_fn,
      &SalixStore.OAuth.Adapters.for_provider/1
    )
  end

  defp refresher_fn do
    SystemsRuntime.get_env(:salix_agent, :oauth_refresher_fn, fn adapter, app, conn ->
      adapter.refresh(app, conn)
    end)
  end
end
