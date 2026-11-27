defmodule Salix.Control.RemoteMCPDeviceSignIn do
  @moduledoc """
  Personal sign-ins to a remote MCP server through the OAuth device grant
  (RFC 8628), for a binding whose calls run as the person who asked
  (`SalixMCP.HostedServices.per_requester?/1`, `SalixMCP.Provider`).

  A person is a requester key: the encoded principal of the turn that asked
  (a Comma user, or a provider user of one connect). Their sign-in is an OAuth
  connection owned by them and an OAuth binding of the Group whose id comes
  from the MCP binding and the requester key, so it is found without a scan.
  The connection refreshes as remote MCP OAuth connections do; a refused
  refresh or a 401 marks only that person's connection as needing sign-in.

  A sign-in under way is one process per (Group, MCP binding, requester) on a
  node, registered here: a second request while it waits gets the same link.
  It polls the token endpoint every `interval` seconds on `SystemsClock`
  (5 more after `slow_down`) and stops at success, denial or the device
  code's expiry, ending the waiting tool calls it was given
  (`SalixAgent.CapabilityRequests.end_sign_in/4`). It holds the device code in
  memory only: when the node stops, the waiting calls end at their deadline
  and the next call starts a new sign-in. A person has at most one sign-in
  under way per binding per node, so the processes are bounded by the people
  who asked.
  """

  use SystemsRuntime.Server, restart: :temporary

  require Logger

  alias Salix.Control.{OAuthBindings, RemoteMCPOAuth, Store}
  alias SalixStore.{Crypto, Keys, OAuth, S3}

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor
  @device_grant "urn:ietf:params:oauth:grant-type:device_code"
  @min_interval_ms 5_000
  @slow_down_ms 5_000
  @max_lifetime_s 1_800
  @call_ms 30_000

  # ---- the person's credential ----

  @doc "The person's `authorization` header for `binding`, or `:sign_in_required`."
  def requester_headers(binding, requester) do
    with {:ok, sign_in} <- sign_in_record(binding, requester),
         {:ok, token} <-
           RemoteMCPOAuth.connection_token(binding["tenant_id"], sign_in["connection_id"]) do
      {:ok, %{"authorization" => "Bearer " <> token}}
    else
      {:error, :not_found} -> {:error, :sign_in_required}
      {:error, {:reauthorization_required, _message}} -> {:error, :sign_in_required}
      {:error, {:missing_oauth, _message}} -> {:error, :sign_in_required}
      {:error, :reauthorization_required} -> {:error, :sign_in_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The server refused the person's token: they sign in again on their next call."
  def rejected(binding, requester) do
    with {:ok, sign_in} <- sign_in_record(binding, requester) do
      _ = OAuth.mark_reauthorization_required(sign_in["connection_id"])
    end

    :ok
  end

  @doc "Removes one person's sign-in to `mcp_binding_id`, and their sign-in under way."
  def remove_sign_in(tenant_id, group_id, mcp_binding_id, requester) do
    stop_pending(fn {group, binding, person} ->
      group == group_id and binding == mcp_binding_id and person == requester
    end)

    binding_id = sign_in_binding_id(mcp_binding_id, requester)

    case OAuthBindings.get(group_id, binding_id) do
      {:ok, %{"tenant_id" => ^tenant_id} = sign_in} -> delete_sign_in(sign_in)
      {:ok, _other} -> {:error, :not_found}
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes every person's sign-in to an MCP binding that goes away."
  def remove_all(%{"group_id" => group_id, "binding_id" => mcp_binding_id}) do
    stop_pending(fn {group, binding, _person} ->
      group == group_id and binding == mcp_binding_id
    end)

    group_id
    |> OAuthBindings.list_records()
    |> Enum.filter(&(get_in(&1, ["metadata", "sign_in_for"]) == mcp_binding_id))
    |> Enum.reduce_while(:ok, fn sign_in, :ok ->
      case delete_sign_in(sign_in) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sign_in_record(binding, requester) do
    case OAuthBindings.get(
           binding["group_id"],
           sign_in_binding_id(binding["binding_id"], requester)
         ) do
      {:ok, %{"tenant_id" => tenant, "connection_id" => connection_id} = sign_in}
      when is_binary(connection_id) and connection_id != "" ->
        if tenant == binding["tenant_id"] and get_in(sign_in, ["metadata", "owner"]) == requester,
          do: {:ok, sign_in},
          else: {:error, :not_found}

      {:ok, _incomplete} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  defp delete_sign_in(sign_in) do
    with :ok <- OAuthBindings.delete(sign_in["group_id"], sign_in["binding_id"]) do
      _ = S3.delete(Keys.oauth_connection(sign_in["connection_id"]))
      :ok
    end
  end

  defp sign_in_binding_id(mcp_binding_id, requester) do
    "oauth-" <>
      String.slice(Crypto.hex(Jason.encode!(["mcp_requester", mcp_binding_id, requester])), 0, 32)
  end

  # ---- a sign-in under way ----

  @doc """
  Starts the person's sign-in, or joins the one under way, and makes the
  tool call `waiter` (agent_id, session_id, tool_call_id, tool_name) wait for
  it as a capability request. Answers `sign_in_required` with the link and the
  request, or `signed_in` when the sign-in under way ended meanwhile.
  """
  def request(binding, requester, waiter) do
    key = {binding["group_id"], binding["binding_id"], requester}

    with {:ok, pid, link} <- pending(key, binding, requester),
         {:ok, request} <- create_request(binding, link, waiter) do
      case wait(pid, request["request_id"]) do
        :ok ->
          {:ok, %{"status" => "sign_in_required", "sign_in" => link, "request" => request}}

        :ended ->
          _ =
            SalixAgent.CapabilityRequestStore.cancel_capability_request(
              waiter["agent_id"],
              waiter["session_id"],
              waiter["tool_call_id"],
              "the sign-in ended before this call waited for it"
            )

          {:ok, %{"status" => "signed_in"}}
      end
    end
  end

  defp pending(key, binding, requester) do
    case live(key) do
      {:ok, pid} ->
        case link(pid) do
          {:ok, link} -> {:ok, pid, link}
          :ended -> begin(key, binding, requester)
        end

      :none ->
        begin(key, binding, requester)
    end
  end

  defp begin(key, binding, requester) do
    with {:ok, _binding, identity} <-
           RemoteMCPOAuth.discover(
             binding["tenant_id"],
             binding["group_id"],
             binding["binding_id"]
           ),
         {:ok, endpoint} <- endpoint(identity, "device_authorization_endpoint"),
         {:ok, token_endpoint} <- endpoint(identity, "token_endpoint"),
         {:ok, client} <- RemoteMCPOAuth.device_client(binding["tenant_id"], identity),
         {:ok, device} <- device_code(endpoint, client) do
      now = SystemsClock.system_time(:millisecond)
      lifetime_s = min(positive(device["expires_in"]) || @max_lifetime_s, @max_lifetime_s)

      state = %{
        key: key,
        tenant_id: binding["tenant_id"],
        group_id: binding["group_id"],
        mcp_binding_id: binding["binding_id"],
        mcp_alias: binding["alias"],
        mcp_id: binding["mcp_id"],
        requester: requester,
        identity: identity,
        client: client,
        token_endpoint: token_endpoint,
        device_code: device["device_code"],
        interval_ms: max((positive(device["interval"]) || 5) * 1000, @min_interval_ms),
        expires_at_ms: now + lifetime_s * 1000,
        link: %{
          "service" => service_name(binding),
          "link_url" => device["verification_uri_complete"] || device["verification_uri"],
          "user_code" => device["user_code"],
          "expires_at" => div(now, 1000) + lifetime_s
        },
        waiters: [],
        timer: nil
      }

      case SystemsRuntime.DynamicSupervisor.start_child(@supervisor, {__MODULE__, state}) do
        {:ok, pid} ->
          {:ok, pid, state.link}

        # Another call of the same person started one first: theirs is the link.
        {:error, {:already_started, pid}} ->
          case link(pid) do
            {:ok, link} -> {:ok, pid, link}
            :ended -> {:error, "the sign-in could not start; ask again"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, "the sign-in could not start: #{format_reason(reason)}"}
    end
  end

  defp endpoint(identity, name) do
    case get_in(identity, ["authorization_server_metadata", name]) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, "the server's OAuth metadata has no #{name}"}
    end
  end

  defp device_code(endpoint, client) do
    case RemoteMCPOAuth.device_post(endpoint, client, [], "MCP device authorization") do
      {:ok, _status, parsed} ->
        device = RemoteMCPOAuth.unwrap_response(parsed, "device_code")

        if is_binary(device["device_code"]) and device["device_code"] != "" and
             is_binary(device["verification_uri_complete"] || device["verification_uri"]),
           do: {:ok, device},
           else: {:error, "the server gave no device code"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_request(binding, link, waiter) do
    SalixAgent.CapabilityRequestStore.create_capability_request(%{
      "tenant_id" => binding["tenant_id"],
      "group_id" => binding["group_id"],
      "source_agent_id" => waiter["agent_id"],
      "source_session_id" => waiter["session_id"],
      "tool_call_id" => waiter["tool_call_id"],
      "request_type" => "account_link",
      "request_payload" => %{
        "account_link" => %{
          "kind" => "mcp_sign_in",
          "link_url" => link["link_url"],
          "tool_name" => waiter["tool_name"],
          "mcp_binding_id" => binding["binding_id"]
        }
      },
      "expires_at" => link["expires_at"]
    })
  end

  defp service_name(binding) do
    case SalixMCP.Store.get_definition(binding["mcp_id"], binding["tenant_id"]) do
      {:ok, %{"name" => name}} when is_binary(name) and name != "" -> name
      _ -> binding["alias"]
    end
  end

  defp live(key) do
    case SystemsRuntime.Registry.lookup(@registry, key) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :none
    end
  end

  defp link(pid), do: ask(pid, :link)

  defp wait(pid, request_id) do
    case ask(pid, {:wait, request_id}) do
      {:ok, _link} -> :ok
      :ended -> :ended
    end
  end

  defp ask(pid, message) do
    SystemsClock.call(pid, message, @call_ms)
  catch
    :exit, _reason -> :ended
  end

  defp stop_pending(match?) do
    @registry
    |> SystemsRuntime.Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {key, pid} ->
      if match?.(key), do: ask(pid, :removed)
    end)
  end

  def start_link(state),
    do:
      SystemsRuntime.Server.start_link(__MODULE__, state,
        name: {:via, SystemsRuntime.Registry, {@registry, state.key}}
      )

  @impl true
  def init(state), do: {:ok, arm(state, state.interval_ms)}

  @impl true
  def handle_call(:link, _from, state), do: {:reply, {:ok, state.link}, state}

  def handle_call({:wait, request_id}, _from, state),
    do: {:reply, {:ok, state.link}, %{state | waiters: Enum.uniq(state.waiters ++ [request_id])}}

  def handle_call(:removed, _from, state) do
    finish(state, :expired)
    {:stop, :normal, :ended, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{state | timer: nil}

    if SystemsClock.system_time(:millisecond) >= state.expires_at_ms do
      end_with(state, :expired)
    else
      case poll(state) do
        {:ok, token} ->
          case persist(state, token) do
            :ok ->
              end_with(state, :signed_in)

            {:error, reason} ->
              Logger.warning("remote MCP sign-in not stored: #{format_reason(reason)}")
              end_with(state, :expired)
          end

        :pending ->
          {:noreply, arm(state, state.interval_ms)}

        :slow_down ->
          state = %{state | interval_ms: state.interval_ms + @slow_down_ms}
          {:noreply, arm(state, state.interval_ms)}

        :expired ->
          end_with(state, :expired)

        :denied ->
          end_with(state, :denied)
      end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp end_with(state, outcome) do
    finish(state, outcome)
    {:stop, :normal, state}
  end

  # Never past the device code's expiry: the last poll comes at it.
  defp arm(state, ms) do
    left = state.expires_at_ms - SystemsClock.system_time(:millisecond)
    timer = SystemsClock.send_after(SystemsRuntime.Proc.self(), :poll, max(min(ms, left), 0))
    %{state | timer: timer}
  end

  defp finish(state, outcome) do
    Enum.each(state.waiters, fn request_id ->
      case SalixAgent.CapabilityRequests.end_sign_in(
             state.group_id,
             request_id,
             state.tenant_id,
             outcome
           ) do
        {:ok, _ended} -> :ok
        {:error, reason} -> Logger.warning("sign-in request not ended: #{inspect(reason)}")
      end
    end)
  end

  # The server answers pending states in the body, whatever the status
  # (larksuite/meegle-cli `device_flow.go`), flat or inside `data`.
  defp poll(state) do
    form = [{"grant_type", @device_grant}, {"device_code", state.device_code}]

    case RemoteMCPOAuth.device_post(state.token_endpoint, state.client, form, "MCP device token") do
      {:ok, _status, parsed} ->
        body =
          if Map.has_key?(parsed, "access_token") or Map.has_key?(parsed, "error"),
            do: parsed,
            else: RemoteMCPOAuth.unwrap_response(parsed, "access_token")

        case {body["access_token"], body["error"]} do
          {token, _error} when is_binary(token) and token != "" -> {:ok, body}
          {_token, "authorization_pending"} -> :pending
          {_token, "slow_down"} -> :slow_down
          {_token, "expired_token"} -> :expired
          {_token, _denied_or_other} -> :denied
        end

      # The server could not be reached: the next interval asks again.
      {:error, _reason} ->
        :pending
    end
  end

  defp persist(state, token) do
    identity = state.identity
    now = Store.now()
    connection_id = "conn-" <> Store.random_id()
    binding_id = sign_in_binding_id(state.mcp_binding_id, state.requester)
    key = Keys.ctl_oauth_group_binding(state.group_id, binding_id)
    service = state.link["service"]

    connection = %{
      "connection_id" => connection_id,
      "tenant" => state.tenant_id,
      "provider" => "remote_mcp",
      "provider_kind" => "remote_mcp",
      "provider_key" => identity["provider_key"],
      "owner" => state.requester,
      "access_token" => token["access_token"],
      "refresh_token" => blank_to_nil(token["refresh_token"]),
      "token_type" => token["token_type"] || "Bearer",
      "scopes" => scopes(token["scope"]),
      "expires_at" => expires_at_ms(token["expires_in"]),
      "provider_account_id" => identity["resource_server_url"],
      "provider_account_name" => service,
      "metadata" => %{
        "provider_key" => identity["provider_key"],
        "resource_server_url" => identity["resource_server_url"],
        "authorization_issuer" => identity["authorization_issuer"],
        "oauth_resource" => identity["oauth_resource"],
        "mcp_definition_id" => state.mcp_id,
        "mcp_binding_id" => state.mcp_binding_id,
        "client_registration_id" => state.client["client_registration_id"],
        "client_source" => "device",
        "token_endpoint" => state.token_endpoint
      },
      "status" => "active",
      "created_at" => now,
      "updated_at" => now
    }

    sign_in = %{
      "binding_id" => binding_id,
      "tenant_id" => state.tenant_id,
      "group_id" => state.group_id,
      "connection_id" => connection_id,
      "provider" => "remote_mcp",
      "provider_kind" => "remote_mcp",
      "provider_key" => identity["provider_key"],
      "alias" => state.mcp_alias,
      "env_hints" => %{},
      "enabled" => true,
      "metadata" => %{
        "sign_in_for" => state.mcp_binding_id,
        "owner" => state.requester,
        "mcp_definition_id" => state.mcp_id,
        "resource_server_url" => identity["resource_server_url"]
      },
      "created_at" => now,
      "updated_at" => now
    }

    previous =
      case OAuthBindings.get(state.group_id, binding_id) do
        {:ok, %{"connection_id" => id}} -> id
        _ -> nil
      end

    with :ok <- OAuth.put(connection_id, connection),
         {:ok, _sign_in} <-
           Store.upsert_record(key, sign_in, fn existing ->
             sign_in
             |> Map.put("created_at", existing["created_at"] || now)
           end) do
      if is_binary(previous) and previous != connection_id,
        do: S3.delete(Keys.oauth_connection(previous))

      :ok
    else
      {:error, reason} ->
        _ = S3.delete(Keys.oauth_connection(connection_id))
        {:error, reason}
    end
  end

  defp scopes(scope) when is_binary(scope), do: String.split(scope, ~r/[\s,]+/, trim: true)
  defp scopes(scopes) when is_list(scopes), do: Enum.map(scopes, &to_string/1)
  defp scopes(_scope), do: []

  defp expires_at_ms(seconds) when is_number(seconds) and seconds > 0,
    do: SystemsClock.system_time(:millisecond) + trunc(seconds) * 1000

  defp expires_at_ms(_seconds), do: nil

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason({_kind, message}) when is_binary(message), do: message
  defp format_reason(reason), do: inspect(reason)

  @doc false
  def registry, do: @registry
  @doc false
  def supervisor, do: @supervisor
end
