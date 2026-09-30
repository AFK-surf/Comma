defmodule CommaSSH.Listener do
  @moduledoc "Optional OTP SSH listener. No operating-system or Erlang shell is exposed."
  use GenServer
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def fingerprint, do: GenServer.call(__MODULE__, :fingerprint)
  def handle_call(:fingerprint, _from, state), do: {:reply, state.fingerprint, state}

  def init(options) do
    key =
      Keyword.get_lazy(options, :host_key, fn ->
        Comma.SSHHostKey.load_or_create!()
      end)

    port = Keyword.get(options, :port, Application.get_env(:comma_ssh, :port))

    case :ssh.daemon(port, daemon_options(key)) do
      {:ok, daemon} ->
        {:ok,
         %{
           daemon: daemon,
           fingerprint:
             key
             |> :ssh_message.ssh2_pubkey_encode()
             |> Comma.Accounts.SSHIdentities.fingerprint()
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  def daemon_options(key) do
    [
      auth_methods: ~c"publickey",
      key_cb: {CommaSSH.KeyCallback, [host_key: key]},
      connectfun: &CommaSSH.KeyCallback.connected/3,
      ssh_cli: {CommaSSH.Channel, []},
      shell: :disabled,
      exec: :disabled,
      subsystems: [],
      tcpip_tunnel_in: false,
      tcpip_tunnel_out: false,
      max_sessions: 256,
      max_channels: 1,
      parallel_login: true,
      negotiation_timeout: 30_000,
      max_initial_idle_time: 15_000,
      idle_time: 60_000,
      max_log_item_len: 0
    ]
  end

  def terminate(_, state), do: :ssh.stop_daemon(state.daemon)
end
