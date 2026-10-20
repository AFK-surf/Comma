defmodule SalixAgent.SSH.Connection do
  require SystemsRuntime.Proc

  @moduledoc """
  Opens one outbound OTP SSH connection for a Group.

  The host must pass the public-destination policy
  (`SalixAgent.Egress.Destination`); the connection is made to an address
  resolved there, so DNS cannot move it afterwards. The Group key
  authenticates (`publickey` only, Ed25519 only, no user interaction), and
  host keys are trusted on first use (`SalixAgent.SSH.KeyCallback`). After
  first use the host key algorithm is pinned to the stored key type.

  A spec with `tailcat:` (a tailcat address, or a DNS name with a
  `tailcat=` TXT record) dials through the node's Tailcat gateway
  (`SalixAgent.SSH.TailcatGateway`) instead. The gateway uses a new
  ephemeral Tailcat node key for each connection. The Tailcat tunnel
  authenticates the server's node key, so the known_hosts name is
  `tailcat:<nodekey>`, not the address: the address also carries a
  pre-shared key and the relay.

  A spec with `via_device_id:` dials `host` from that gateway device's network
  (`SalixAgent.SSH.DeviceRelay`). The address is neither checked nor
  resolved here. The same name can mean different hosts on different
  networks, so the known_hosts name is `device:<device_id>:<host>`.

  A spec with `via_tailnet: true` dials `host` in the Group's tailnet
  (`SalixAgent.Tailnet`). The tailnet node resolves `host` from its own
  network map and reaches only peers and approved subnet routes. The
  known_hosts name is `tailnet:<tailnet>:<host>`.

  SSH authentication and host key trust are the same for every transport.

  Failures return a diagnostic map for the Agent: a stable `code`, a
  `message`, and the facts it needs to recover (fingerprints, the public key
  to install, the address tried).
  """

  alias SalixAgent.Egress.Destination
  alias SalixAgent.SSH.{DeviceRelay, Identity, KeyCallback, KnownHosts, TailcatGateway}
  alias SalixAgent.Tailnet
  alias SalixAgent.Tools.LanGateway

  @connect_timeout_ms 10_000
  @negotiation_timeout_ms 20_000
  # The gateway pings for up to 10 s, then dials the port. With negotiation,
  # an open stays inside the 40 s wait of `SalixAgent.SSH.Sessions.open/1`.
  @tailcat_dial_timeout_ms 15_000
  # The gateway dials for at most 15 s; a dial and negotiation stay inside
  # the open wait as for Tailcat.
  @device_dial_timeout_ms 15_000
  # The tailnet node may need a few seconds to start on its owner.
  @tailnet_dial_timeout_ms 15_000
  @keepalive %{count_max: 3, interval: 30_000}

  @type spec :: %{
          required(:group_id) => String.t(),
          required(:agent_id) => String.t(),
          required(:host) => String.t(),
          required(:port) => pos_integer(),
          required(:user) => String.t(),
          optional(:tailcat) => String.t() | nil,
          optional(:via_device_id) => String.t() | nil,
          optional(:via_tailnet) => boolean()
        }

  @doc """
  Connect and authenticate. The calling process owns the connection and
  receives `{ref, {:disconnected, reason}}` when it ends.

  Returns the spec as connected: for Tailcat, `host` is the known_hosts host
  `tailcat:<nodekey>`; through a gateway device, `device:<device_id>:<host>`;
  through the Group's tailnet, `tailnet:<tailnet>:<host>`.
  """
  @spec connect(spec(), reference()) ::
          {:ok, pid(), %{String.t() => term()}, spec()} | {:error, %{String.t() => term()}}
  def connect(spec, ref) do
    started = SystemsClock.monotonic_time()
    result = do_connect(spec, ref)
    emit(result, operation(spec), SystemsClock.monotonic_time() - started)
    result
  end

  @doc "The known_hosts host for a Tailcat server's node key."
  @spec tailcat_host(String.t()) :: String.t()
  def tailcat_host("nodekey:" <> _ = node_key), do: "tailcat:" <> node_key

  @doc "The known_hosts host for a host reached through a gateway device."
  @spec device_host(String.t(), String.t()) :: String.t()
  def device_host(device_id, host), do: "device:#{device_id}:#{host}"

  defp operation(%{tailcat: target}) when is_binary(target), do: "ssh_connect_tailcat"
  defp operation(%{via_device_id: device_id}) when is_binary(device_id), do: "ssh_connect_device"
  defp operation(%{via_tailnet: true}), do: "ssh_connect_tailnet"
  defp operation(_spec), do: "ssh_connect"

  defp do_connect(%{tailcat: target} = spec, ref) when is_binary(target) do
    with {:ok, identity} <- identity(spec.group_id),
         {:ok, socket, node_key} <- tailcat_dial(target, spec.port, @tailcat_dial_timeout_ms),
         spec = %{spec | host: tailcat_host(node_key)},
         {:ok, known} <- known_host(spec) |> close_on_error(socket) do
      options = options(spec, identity, known, ref)

      socket
      |> connect_socket(spec, identity, options, ref)
      |> explain_pin(known)
      |> with_spec(spec)
    end
  end

  defp do_connect(%{via_device_id: device_id} = spec, ref) when is_binary(device_id) do
    with {:ok, identity} <- identity(spec.group_id),
         {:ok, target} <- gateway(spec),
         dial_host = spec.host,
         spec = %{spec | host: device_host(device_id, dial_host)},
         {:ok, known} <- known_host(spec),
         {:ok, socket} <- device_dial(spec, target, dial_host) do
      options = options(spec, identity, known, ref)

      socket
      |> connect_socket(spec, identity, options, ref)
      |> explain_pin(known)
      |> with_spec(spec)
    end
  end

  defp do_connect(%{via_tailnet: true} = spec, ref) do
    with {:ok, identity} <- identity(spec.group_id),
         dial_host = spec.host,
         {:ok, socket, tailnet} <- tailnet_dial(spec, dial_host),
         spec = %{spec | host: "tailnet:#{tailnet}:#{dial_host}"},
         {:ok, known} <- known_host(spec) |> close_on_error(socket) do
      options = options(spec, identity, known, ref)

      socket
      |> connect_socket(spec, identity, options, ref)
      |> explain_pin(known)
      |> with_spec(spec)
    end
  end

  defp do_connect(spec, ref) do
    with {:ok, identity} <- identity(spec.group_id),
         {:ok, known} <- known_host(spec),
         {:ok, addresses} <- resolve(spec.host) do
      options = options(spec, identity, known, ref)
      # Two addresses (IPv4 first) keep a failing open within its wait.
      addresses
      |> Enum.take(2)
      |> connect_addresses(spec, identity, options, ref, nil)
      |> explain_pin(known)
      |> with_spec(spec)
    end
  end

  defp with_spec({:ok, conn, host_key}, spec), do: {:ok, conn, host_key, spec}
  defp with_spec(error, _spec), do: error

  defp close_on_error({:ok, _} = ok, _socket), do: ok

  defp close_on_error(error, socket) do
    :gen_tcp.close(socket)
    error
  end

  defp tailcat_dial(target, port, timeout_ms) do
    with :ok <- tailcat_name_allowed(target) do
      case TailcatGateway.dial(target, port, timeout_ms) do
        {:ok, socket, node_key} -> {:ok, socket, node_key}
        {:error, error} -> {:error, Map.put(error, "port", port)}
      end
    end
  end

  defp gateway(spec) do
    case LanGateway.resolve_gateway(spec.agent_id, spec.via_device_id, ["lan_tcp_dial"]) do
      {:ok, target, _gateway, _method} ->
        {:ok, target}

      {:error, code, message} ->
        {:error, diagnostic(code, message, %{"via_device_id" => spec.via_device_id})}
    end
  end

  defp device_dial(spec, target, host) do
    case DeviceRelay.dial(spec.agent_id, target, host, spec.port, @device_dial_timeout_ms) do
      {:ok, socket, _result} ->
        {:ok, socket}

      {:error, reason} ->
        {:error,
         diagnostic(
           "connect_failed",
           "The gateway could not connect to #{host} port #{spec.port}.",
           %{
             "host" => host,
             "port" => spec.port,
             "via_device_id" => spec.via_device_id,
             "reason" => device_reason(reason)
           }
         )}
    end
  end

  defp tailnet_dial(spec, host) do
    case Tailnet.dial(spec.group_id, host, spec.port, @tailnet_dial_timeout_ms) do
      {:ok, socket, reply} ->
        # OTP ssh takes over a socket only in list mode.
        :ok = :inet.setopts(socket, [:list])
        {:ok, socket, reply["tailnet"] || ""}

      {:error, error} ->
        {:error, Map.merge(error, %{"host" => host, "port" => spec.port})}
    end
  end

  defp device_reason(:timeout), do: "timeout"
  defp device_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 300)
  defp device_reason(reason), do: inspect(reason)

  # A DNS name is looked up for its `tailcat=` TXT record; the name policy
  # keeps the lookup off internal names.
  defp tailcat_name_allowed(target) do
    if String.contains?(target, ".") and Destination.blocked_name?(target) do
      {:error,
       diagnostic("blocked_destination", "#{target} is not a public name.", %{
         "reason" => "private_name"
       })}
    else
      :ok
    end
  end

  # The gateway socket is already connected; OTP ssh negotiates on it.
  defp connect_socket(socket, spec, identity, options, ref) do
    result = :ssh.connect(socket, options, @negotiation_timeout_ms)
    host_key = receive_host_key(ref)

    case {result, host_key} do
      {{:ok, conn}, {:ok, status, entry}} ->
        {:ok, conn, host_key_info(entry, status)}

      {{:ok, conn}, _missing} ->
        :ssh.close(conn)
        {:error, diagnostic("negotiation_failed", "The host key was not verified.", %{})}

      {{:error, reason}, nil} ->
        :gen_tcp.close(socket)

        {:error,
         diagnostic("negotiation_failed", "SSH negotiation with #{spec.host} failed.", %{
           "host" => spec.host,
           "port" => spec.port,
           "reason" => reason_text(reason)
         })}

      {{:error, _reason}, {:error, {:host_key_mismatch, stored, presented}}} ->
        {:error, mismatch(spec, stored, presented)}

      {{:error, _reason}, {:error, reason}} ->
        {:error, known_hosts_error(reason)}

      {{:error, reason}, {:ok, status, entry}} ->
        {:error, auth_failed(spec, identity, reason, host_key_info(entry, status))}
    end
  end

  # A host that no longer offers the stored key type fails negotiation rather
  # than presenting a different key.
  defp explain_pin({:error, %{"code" => "negotiation_failed"} = diagnostic}, %{"key_type" => type}) do
    {:error,
     Map.merge(diagnostic, %{
       "pinned_host_key_type" => type,
       "message" =>
         diagnostic["message"] <>
           " The Group trusts a #{type} host key for this host. If the host no longer offers that key type, confirm the new host key with the user, then call ssh.known_hosts.remove."
     })}
  end

  defp explain_pin(result, _known), do: result

  defp identity(group_id) do
    case Identity.fetch(group_id) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, reason} ->
        {:error,
         diagnostic("identity_unavailable", "The Group SSH key could not be loaded.", %{
           "reason" => inspect(reason)
         })}
    end
  end

  defp known_host(spec) do
    case KnownHosts.get(spec.group_id, spec.host, spec.port) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, known_hosts_error(reason)}
    end
  end

  defp resolve(host) do
    allow_private = SystemsRuntime.get_env(:salix_agent, :ssh_allow_private_hosts, false) == true

    case Destination.resolve(host, allow_private: allow_private) do
      {:ok, addresses} ->
        {:ok, addresses}

      {:error, {:blocked_name, _}} ->
        {:error,
         diagnostic("blocked_destination", "#{host} is not a public destination.", %{
           "host" => host,
           "reason" => "private_name"
         })}

      {:error, {:blocked_address, _, address}} ->
        {:error,
         diagnostic(
           "blocked_destination",
           "#{host} resolves to #{:inet.ntoa(address)}, which is not a public address. SSH to private, loopback, link-local and cluster networks is refused.",
           %{
             "host" => host,
             "address" => to_string(:inet.ntoa(address)),
             "reason" => "private_address"
           }
         )}

      {:error, {:unresolved, _}} ->
        {:error,
         diagnostic("connect_failed", "Could not resolve host #{host}.", %{
           "host" => host,
           "reason" => "nxdomain"
         })}
    end
  end

  defp options(spec, identity, known, ref) do
    owner = SystemsRuntime.Proc.self()

    pinned =
      case KnownHosts.pinned_algorithms(known) do
        nil -> []
        algorithms -> [preferred_algorithms: [public_key: algorithms]]
      end

    [
      user: String.to_charlist(spec.user),
      user_interaction: false,
      silently_accept_hosts: false,
      save_accepted_host: false,
      auth_methods: ~c"publickey",
      pref_public_key_algs: [:"ssh-ed25519"],
      key_cb:
        {KeyCallback,
         [
           group_id: spec.group_id,
           host: spec.host,
           port: spec.port,
           agent_id: spec.agent_id,
           owner: owner,
           ref: ref,
           public_key: identity.public_key,
           private_key: identity.private_key
         ]},
      connect_timeout: @connect_timeout_ms,
      idle_time: :infinity,
      alive: @keepalive,
      disconnectfun: fn reason ->
        SystemsRuntime.Proc.send(owner, {ref, {:disconnected, reason}})
      end
    ] ++ pinned
  end

  defp connect_addresses([], _spec, _identity, _options, _ref, last_error),
    do: {:error, last_error}

  defp connect_addresses([address | rest], spec, identity, options, ref, _last_error) do
    # The fourth argument bounds key exchange and authentication.
    result = :ssh.connect(address, spec.port, options, @negotiation_timeout_ms)
    host_key = receive_host_key(ref)

    case {result, host_key} do
      {{:ok, conn}, {:ok, status, entry}} ->
        {:ok, conn, host_key_info(entry, status)}

      {{:ok, conn}, _missing} ->
        :ssh.close(conn)
        {:error, diagnostic("negotiation_failed", "The host key was not verified.", %{})}

      {{:error, reason}, nil} when is_atom(reason) ->
        # A transport failure before key exchange; the next address may work.
        error =
          diagnostic("connect_failed", "Could not connect to #{spec.host} port #{spec.port}.", %{
            "host" => spec.host,
            "port" => spec.port,
            "address" => to_string(:inet.ntoa(address)),
            "reason" => to_string(reason)
          })

        connect_addresses(rest, spec, identity, options, ref, error)

      {{:error, reason}, nil} ->
        {:error,
         diagnostic("negotiation_failed", "SSH negotiation with #{spec.host} failed.", %{
           "host" => spec.host,
           "port" => spec.port,
           "address" => to_string(:inet.ntoa(address)),
           "reason" => reason_text(reason)
         })}

      {{:error, _reason}, {:error, {:host_key_mismatch, stored, presented}}} ->
        {:error, mismatch(spec, stored, presented)}

      {{:error, _reason}, {:error, reason}} ->
        {:error, known_hosts_error(reason)}

      {{:error, reason}, {:ok, status, entry}} ->
        {:error, auth_failed(spec, identity, reason, host_key_info(entry, status))}
    end
  end

  # KeyCallback runs inside the connection process and reports here before
  # `:ssh.connect/4` returns.
  defp receive_host_key(ref) do
    SystemsRuntime.Proc.receive do
      {^ref, {:host_key, result}} -> result
    after
      0 -> nil
    end
  end

  defp host_key_info(entry, status) do
    %{
      "status" => to_string(status),
      "key_type" => entry["key_type"],
      "fingerprint" => entry["fingerprint"],
      "first_seen_at" => entry["first_seen_at"]
    }
  end

  defp mismatch(spec, stored, presented) do
    diagnostic(
      "host_key_mismatch",
      "The host key for #{KnownHosts.name(spec.host, spec.port)} changed. The connection was refused before authentication. This can mean the host was rebuilt or that someone is intercepting the connection. Confirm the new fingerprint with the user; if the change is expected, call ssh.known_hosts.remove for this host and open the session again.",
      %{
        "host" => spec.host,
        "port" => spec.port,
        "known_hosts_name" => KnownHosts.name(spec.host, spec.port),
        "stored_key_type" => stored["key_type"],
        "stored_fingerprint" => stored["fingerprint"],
        "presented_key_type" => presented["key_type"],
        "presented_fingerprint" => presented["fingerprint"],
        "first_seen_at" => stored["first_seen_at"],
        "first_seen_by_agent_id" => stored["first_seen_by_agent_id"]
      }
    )
  end

  defp auth_failed(spec, identity, reason, host_key) do
    diagnostic(
      "auth_failed",
      "#{spec.host} did not accept the Group SSH key for user #{spec.user}. Ask the user to add the public key below to ~#{spec.user}/.ssh/authorized_keys on that host, then open the session again.",
      %{
        "host" => spec.host,
        "port" => spec.port,
        "user" => spec.user,
        "client_key_fingerprint" => identity.fingerprint,
        "public_key" => identity.public_key_line,
        "reason" => reason_text(reason),
        "host_key" => host_key
      }
    )
  end

  defp known_hosts_error({:known_hosts_full, max}) do
    diagnostic(
      "known_hosts_full",
      "The Group trusts the maximum of #{max} hosts. Remove unused hosts with ssh.known_hosts.remove.",
      %{"max_hosts" => max}
    )
  end

  defp known_hosts_error(reason) do
    diagnostic(
      "known_hosts_unavailable",
      "The Group host key database could not be read or updated, so the connection was refused.",
      %{"reason" => inspect(reason)}
    )
  end

  defp reason_text(reason) when is_list(reason), do: List.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp emit(result, operation, duration) do
    outcome =
      case result do
        {:ok, _conn, _host_key, _spec} ->
          "ok"

        {:error, %{"code" => code}}
        when code in [
               "host_key_mismatch",
               "auth_failed",
               "blocked_destination",
               "not_a_lan_gateway",
               "operations_not_allowed",
               "tailcat_blocked_relay",
               "tailcat_invalid_address",
               "tailnet_not_configured",
               "tailnet_needs_login",
               "tailnet_destination_not_allowed",
               "tailnet_host_unknown"
             ] ->
          "rejected"

        {:error, %{"code" => code}}
        when code in [
               "identity_unavailable",
               "known_hosts_unavailable",
               "known_hosts_full",
               "tailcat_unavailable",
               "tailcat_relay_unavailable",
               "tailnet_unavailable",
               "tailnet_starting",
               "gateway_offline",
               "device_not_found",
               "device_lookup_failed"
             ] ->
          "unavailable"

        {:error, %{"reason" => "timeout"}} ->
          "timeout"

        {:error, _diagnostic} ->
          "failed"
      end

    Salix.Telemetry.emit_operation("salix_agent", operation, "salix", outcome, duration)
  end

  @doc false
  def diagnostic(code, message, details),
    do: Map.merge(%{"code" => code, "message" => message}, details)
end
