defmodule SalixSignal.Test.FakeSfu do
  @moduledoc false
  # A fake Signal calling server (SFU) for group-call tests, written from
  # CRS-14 sections 5 to 7 and 10. It serves the peek and join API over TLS
  # with the FakeChat test chain and runs the media side itself:
  #
  #   * PUT and GET /v2/conference/participants check the Authorization
  #     header of section 4.2 for the configured token. A join answers with a
  #     demux ID, this server's UDP host candidates, fresh ICE credentials and
  #     an X25519 key, and adds the device to the peek.
  #   * An ICE agent in the controlled role accepts the client's checks
  #     (the client's address is learned peer-reflexively, section 6.1).
  #   * SRTP uses the AEAD_AES_128_GCM keys of section 6.2, derived from this
  #     side's private key.
  #
  # Every RTP packet from the client is decrypted and sent to the test
  # process as `{:fake_sfu, :rtp, %Rtp{}}`; RTCP as `{:fake_sfu, :rtcp,
  # plain}`. The test injects packets from other devices with `send_rtp/2`
  # and changes the call with `put_devices/2`. `hold_peeks/1` makes peeks
  # wait until `release_peeks/1` answers them with the devices of that time.
  # Requests are reported as `{:fake_sfu, method}`.

  use GenServer

  alias SalixSignalProto.CallMedia.{Rtp, Srtp}
  alias SalixSignalProto.Crypto.X25519
  alias SalixSignalProto.GroupCall

  def start_link({test_pid, token, opts}),
    do: GenServer.start_link(__MODULE__, {test_pid, token, opts})

  def bandit_options(sfu, chain) do
    [
      plug: {__MODULE__.Router, sfu},
      scheme: :https,
      ip: :loopback,
      port: 0,
      thousand_island_options: [transport_options: chain.server]
    ]
  end

  @doc "Replaces the other devices in the peek: `[{demux_id, opaque_user_id}]`."
  def put_devices(sfu, devices), do: GenServer.call(sfu, {:put_devices, devices})

  @doc "Holds peek answers until `release_peeks/1`."
  def hold_peeks(sfu), do: GenServer.call(sfu, :hold_peeks)

  @doc "Answers the held peeks and stops holding."
  def release_peeks(sfu), do: GenServer.call(sfu, :release_peeks)

  @doc "Protects and sends one plain RTP packet to the client."
  def send_rtp(sfu, packet), do: GenServer.call(sfu, {:send_rtp, packet})

  @doc "The joined client's demux ID."
  def client_demux(sfu), do: GenServer.call(sfu, :client_demux)

  @impl GenServer
  def init({test_pid, token, opts}) do
    Process.flag(:trap_exit, true)

    {:ok, ice} =
      ExICE.ICEAgent.start_link(
        role: :controlled,
        ip_filter: fn ip -> tuple_size(ip) == 4 end,
        on_new_candidate: self(),
        on_connection_state_change: self(),
        on_gathering_state_change: self(),
        on_data: self()
      )

    :ok = ExICE.ICEAgent.gather_candidates(ice)
    {:ok, ufrag, pwd} = ExICE.ICEAgent.get_local_credentials(ice)

    {:ok,
     %{
       test: test_pid,
       token: token,
       era_id: Keyword.get(opts, :era_id, "0123456789abcdef"),
       client_demux: Keyword.get(opts, :client_demux, 0x10),
       ice: ice,
       ice_state: :new,
       ufrag: ufrag,
       pwd: pwd,
       candidates: [],
       gathered: false,
       waiting: [],
       devices: [],
       client_joined: false,
       held_peeks: nil,
       tx: nil,
       rx: nil
     }}
  end

  @impl GenServer
  def handle_call({:put_devices, devices}, _from, state),
    do: {:reply, :ok, %{state | devices: devices}}

  def handle_call(:client_demux, _from, state), do: {:reply, state.client_demux, state}

  def handle_call(:hold_peeks, _from, state), do: {:reply, :ok, %{state | held_peeks: []}}

  def handle_call(:release_peeks, _from, state) do
    for from <- Enum.reverse(state.held_peeks || []),
        do: GenServer.reply(from, {200, JSON.encode!(peek(state))})

    {:reply, :ok, %{state | held_peeks: nil}}
  end

  def handle_call({:send_rtp, packet}, _from, %{tx: tx} = state) when tx != nil do
    {:ok, protected, tx} = Srtp.protect(tx, packet)
    ExICE.ICEAgent.send_data(state.ice, protected)
    {:reply, :ok, %{state | tx: tx}}
  end

  def handle_call({:http, method, authorization, body}, from, state) do
    send(state.test, {:fake_sfu, method})

    cond do
      authorization != expected_authorization(state.token) ->
        {:reply, {401, ""}, state}

      method == "GET" and state.held_peeks != nil ->
        {:noreply, %{state | held_peeks: [from | state.held_peeks]}}

      method == "GET" ->
        {:reply, {200, JSON.encode!(peek(state))}, state}

      method == "PUT" and not state.gathered ->
        {:noreply, %{state | waiting: [{from, body} | state.waiting]}}

      method == "PUT" ->
        {reply, state} = join(state, body)
        {:reply, reply, state}
    end
  end

  @impl GenServer
  def handle_info({:ex_ice, _ice, {:new_candidate, candidate}}, state),
    do: {:noreply, %{state | candidates: state.candidates ++ [candidate]}}

  def handle_info({:ex_ice, _ice, {:gathering_state_change, :complete}}, state) do
    state = %{state | gathered: true}

    state =
      Enum.reduce(Enum.reverse(state.waiting), %{state | waiting: []}, fn {from, body}, state ->
        {reply, state} = join(state, body)
        GenServer.reply(from, reply)
        state
      end)

    {:noreply, state}
  end

  def handle_info({:ex_ice, _ice, {:connection_state_change, ice_state}}, state) do
    send(state.test, {:fake_sfu, :ice, ice_state})
    {:noreply, %{state | ice_state: ice_state}}
  end

  def handle_info({:ex_ice, _ice, {:data, packet}}, %{rx: rx} = state) when rx != nil do
    cond do
      not Rtp.rtp_or_rtcp?(packet) ->
        {:noreply, state}

      Rtp.rtcp?(packet) ->
        {:ok, plain, rx} = Srtp.unprotect_rtcp(rx, packet)
        send(state.test, {:fake_sfu, :rtcp, plain})
        {:noreply, %{state | rx: rx}}

      true ->
        {:ok, plain, rx} = Srtp.unprotect(rx, packet)
        {:ok, rtp} = Rtp.decode(plain)
        send(state.test, {:fake_sfu, :rtp, rtp})
        {:noreply, %{state | rx: rx}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp join(state, body) do
    request = JSON.decode!(body)
    {sfu_public, sfu_private} = X25519.keypair()
    client_public = Base.decode16!(request["dhePublicKey"], case: :lower)
    extra = Base.decode16!(request["hkdfExtraInfo"], case: :lower)
    # The SFU derives the same 56 bytes; the first pair protects media from
    # the client, the second media to it.
    {:ok, keys} = GroupCall.srtp_keys(sfu_private, client_public, extra)

    :ok = ExICE.ICEAgent.set_remote_credentials(state.ice, request["iceUfrag"], request["icePwd"])
    send(state.test, {:fake_sfu, :join_request, request})

    addresses =
      for candidate <- state.candidates do
        [_foundation, _component, _transport, _priority, ip, port | _] = String.split(candidate)
        "#{ip}:#{port}"
      end

    response = %{
      "demuxId" => state.client_demux,
      "udpAddresses" => addresses,
      "iceUfrag" => state.ufrag,
      "icePwd" => state.pwd,
      "dhePublicKey" => Base.encode16(sfu_public, case: :lower),
      "callCreator" => "creator",
      "conferenceId" => state.era_id,
      "clientStatus" => "ACTIVE"
    }

    state = %{
      state
      | client_joined: true,
        rx: Srtp.new(keys.send.key, keys.send.salt),
        tx: Srtp.new(keys.receive.key, keys.receive.salt)
    }

    {{200, JSON.encode!(response)}, state}
  end

  defp peek(state) do
    own =
      if state.client_joined,
        do: [%{"demuxId" => state.client_demux, "opaqueUserId" => "self"}],
        else: []

    %{
      "conferenceId" => state.era_id,
      "maxDevices" => 16,
      "creator" => "creator",
      "participants" =>
        own ++
          Enum.map(state.devices, fn {demux, user} ->
            %{"demuxId" => demux, "opaqueUserId" => user}
          end)
    }
  end

  defp expected_authorization(token) do
    {:ok, header} = GroupCall.authorization(token)
    header
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(sfu), do: sfu

    @impl true
    def call(%{request_path: "/v2/conference/participants"} = conn, sfu) do
      {:ok, body, conn} = read_body(conn)
      authorization = conn |> get_req_header("authorization") |> List.first()
      {status, body} = GenServer.call(sfu, {:http, conn.method, authorization, body}, 10_000)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end

    def call(conn, _sfu), do: send_resp(conn, 404, "")
  end
end
