defmodule SalixSignal.Test.FakeCdsi do
  @moduledoc false
  # A fake contact discovery service for SalixSignal.ContactDiscovery tests,
  # written from CRS-11. One TLS server (the FakeChat test chain) answers
  # `GET /v2/directory/auth` with a credential and upgrades
  # `/v1/<mrenclave>/discovery` to a socket that plays the enclave:
  # attestation, Noise NKhfs responder, token response, results, close 1000.
  #
  # Each step is reported to the test process as `{:fake_cdsi, event, ...}`.
  # `script` options change the enclave's behavior:
  #
  #   * `:results` - `%{e164 => {pni_bytes, aci_bytes}}` for found numbers
  #   * `:close_after_request` - `{code, reason}` instead of the token response
  #   * `:upgrade` - `{:reject, status, headers}` instead of the upgrade
  #   * `:token` - the token of the first response (default 20 bytes)

  @username "0123456789abcdef0123"
  @password "1790294400:0123456789abcdef0123"

  def credentials, do: {@username, @password}

  def bandit_options(test_pid, chain, enclave) do
    [
      plug: {__MODULE__.Router, Map.put(enclave, :test, test_pid)},
      scheme: :https,
      ip: :loopback,
      port: 0,
      thousand_island_options: [transport_options: chain.server ++ [versions: [:"tlsv1.3"]]]
    ]
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    alias SalixSignal.Test.FakeCdsi

    @impl true
    def init(state), do: state

    @impl true
    def call(%{request_path: "/v2/directory/auth"} = conn, state) do
      send(state.test, {:fake_cdsi, :auth, get_req_header(conn, "authorization")})
      {username, password} = FakeCdsi.credentials()

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{"username" => username, "password" => password}))
    end

    def call(%{request_path: "/v1/" <> rest} = conn, state) do
      send(state.test, {:fake_cdsi, :upgrade, rest, get_req_header(conn, "authorization")})

      case Map.get(state, :upgrade) do
        {:reject, status, headers} ->
          conn |> merge_resp_headers(headers) |> send_resp(status, "") |> halt()

        nil ->
          conn |> WebSockAdapter.upgrade(FakeCdsi.Enclave, state, []) |> halt()
      end
    end
  end

  defmodule Enclave do
    @moduledoc false
    @behaviour WebSock

    alias SalixSignalProto.ContactDiscovery.{Lookup, Noise}
    alias SalixSignalProto.ContactDiscovery.Lookup.Wire
    alias SalixSignalProto.Crypto.X25519

    @impl true
    def init(state) do
      {:push, {:binary, state.attestation}, Map.put(state, :step, :handshake)}
    end

    @impl true
    def handle_in({bytes, opcode: :binary}, %{step: :handshake} = state) do
      send(state.test, {:fake_cdsi, :handshake, byte_size(bytes)})
      {:ok, "", handshake} = Noise.responder_read(state.static_private, bytes)

      {:ok, message2, noise} =
        Noise.responder_write(handshake,
          ephemeral: X25519.generate_private_key(),
          kem_randomness: :crypto.strong_rand_bytes(32)
        )

      {:push, {:binary, message2}, %{state | step: :request} |> Map.put(:noise, noise)}
    end

    def handle_in({bytes, opcode: :binary}, %{step: :request} = state) do
      {:ok, request, noise} = Noise.open(state.noise, bytes)
      send(state.test, {:fake_cdsi, :request, request})

      case Map.get(state, :close_after_request) do
        {code, reason} ->
          {:stop, :normal, {code, reason}, state}

        nil ->
          token = Map.get(state, :token, :binary.copy(<<0x5A>>, 20))

          {:ok, sealed, noise} =
            Noise.seal(noise, Wire.Response.encode(%Wire.Response{token: token}))

          {:push, {:binary, sealed},
           %{state | noise: noise, step: :ack} |> Map.put(:request, request)}
      end
    end

    def handle_in({bytes, opcode: :binary}, %{step: :ack} = state) do
      {:ok, ack, noise} = Noise.open(state.noise, bytes)
      send(state.test, {:fake_cdsi, :ack, ack})
      records = records(state.request, Map.get(state, :results, %{}))
      response = Wire.Response.encode(%Wire.Response{records: records, permits_used: 1})
      {:ok, sealed, noise} = Noise.seal(noise, response)
      {:stop, :normal, {1000, ""}, [{:binary, sealed}], %{state | noise: noise, step: :done}}
    end

    def handle_in(frame, state) do
      send(state.test, {:fake_cdsi, :unexpected, frame})
      {:ok, state}
    end

    @impl true
    def handle_info(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    # One record per requested number, found or not (CRS-11 §6.2).
    defp records(request, results) do
      wire = Wire.Request.decode(request)
      numbers = wire.previous_numbers <> wire.new_numbers

      for <<number::binary-size(8) <- numbers>>, into: <<>> do
        e164 = Lookup.decode_e164(number)

        case Map.get(results, e164) do
          {pni, aci} -> number <> pni <> aci
          nil -> number <> <<0::256>>
        end
      end
    end
  end
end
