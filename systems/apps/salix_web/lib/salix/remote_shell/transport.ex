defmodule Salix.RemoteShell.Transport do
  @moduledoc """
  OTP SSH over an authenticated CP WebSocket. A private loopback socket pair
  adapts OTP's existing TCP transport; its listener closes before SSH starts.
  The target offers PTY shell, not SSH exec. Each call is a new shell and is
  never replayed. Only an SSH exit-status followed by channel close is success.
  """
  alias Salix.RemoteShell.{Gateway, HostKey}

  def pin(handle, device, timeout) do
    bounded(timeout, fn ->
      connected(handle, device, :learn, fn _ssh, ref ->
        receive do
          {^ref, key} -> {:ok, key}
        after
          0 -> {:error, :host_key_missing}
        end
      end)
    end)
  end

  def run(handle, device, command, timeout) do
    bounded(timeout, fn ->
      connected(handle, device, device.host_key, fn ssh, _ref ->
        with {:ok, channel} <- :ssh_connection.session_channel(ssh, 65536, 32768, 10_000),
             :success <-
               :ssh_connection.ptty_alloc(
                 ssh,
                 channel,
                 [term: ~c"dumb", pty_opts: [echo: 0, icanon: 0]],
                 10_000
               ),
             :ok <- :ssh_connection.shell(ssh, channel),
             :ok <- :ssh_connection.send(ssh, channel, shell_input(command), 10_000) do
          collect(ssh, channel, [], 0, nil)
        else
          _ -> {:error, :ssh_session_failed}
        end
      end)
    end)
  end

  defp bounded(timeout, fun) when timeout > 0 do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :transport_failed}
        catch
          _, _ -> {:error, :transport_failed}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :command_timeout_or_disconnect}
    end
  end

  defp bounded(_, _), do: {:error, :expired_target}

  defp connected(handle, device, expected, fun) do
    with {:ok, {local, relay}} <- socket_pair() do
      try do
        with {:ok, gateway} <- Gateway.open(handle, device, relay) do
          try do
            ref = make_ref()

            options = [
              user: ~c"comma",
              auth_methods: ~c"",
              user_interaction: false,
              silently_accept_hosts: false,
              save_accepted_host: false,
              key_cb: {HostKey, [expected: expected, owner: self(), ref: ref]}
            ]

            # OTP's hello-line state expects list mode; it selects binary mode after KEX.
            :ok = :inet.setopts(local, mode: :list)

            case :ssh.connect(local, options, 15_000) do
              {:ok, ssh} ->
                try do
                  fun.(ssh, ref)
                after
                  :ssh.close(ssh)
                end

              _ ->
                {:error, :ssh_authentication_or_connect_failed}
            end
          after
            Process.exit(gateway, :kill)
          end
        end
      after
        :gen_tcp.close(local)
        :gen_tcp.close(relay)
      end
    end
  end

  defp socket_pair do
    opts = [
      :binary,
      active: false,
      ip: {127, 0, 0, 1},
      packet: :raw,
      buffer: 65536,
      recbuf: 65536,
      sndbuf: 65536,
      send_timeout: 5000,
      send_timeout_close: true
    ]

    with {:ok, listener} <- :gen_tcp.listen(0, opts) do
      try do
        with {:ok, {_, port}} <- :inet.sockname(listener),
             {:ok, local} <- :gen_tcp.connect({127, 0, 0, 1}, port, opts, 5000) do
          case :gen_tcp.accept(listener, 5000) do
            {:ok, relay} ->
              # Never accept a raced local connection instead of our own peer.
              if :inet.peername(relay) == :inet.sockname(local) do
                {:ok, {local, relay}}
              else
                :gen_tcp.close(local)
                :gen_tcp.close(relay)
                {:error, :local_transport_failed}
              end

            _ ->
              :gen_tcp.close(local)
              {:error, :local_transport_failed}
          end
        end
      after
        :gen_tcp.close(listener)
      end
    end
  end

  @doc false
  def shell_input(command) do
    # Base64 protects PTY line discipline from newlines/control bytes in input.
    # The command runs once in a child bash, then the outer login shell exits
    # with that child's status. This is not a shell sandbox.
    encoded = Base.encode64(command)
    " /bin/bash --noprofile --norc -c \"$(printf %s '#{encoded}' | base64 -d)\"; exit $?\n"
  end

  defp collect(ssh, channel, output, size, status) do
    receive do
      {:ssh_cm, ^ssh, {:data, ^channel, _, bytes}} ->
        if size + byte_size(bytes) > 1_048_576 do
          {:error, :output_limit}
        else
          :ssh_connection.adjust_window(ssh, channel, byte_size(bytes))
          collect(ssh, channel, [bytes | output], size + byte_size(bytes), status)
        end

      {:ssh_cm, ^ssh, {:exit_status, ^channel, code}} ->
        collect(ssh, channel, output, size, code)

      {:ssh_cm, ^ssh, {:closed, ^channel}} when is_integer(status) ->
        bytes = output |> Enum.reverse() |> IO.iodata_to_binary()

        {:ok,
         %{
           exit_code: status,
           output_base64: Base.encode64(bytes),
           output: String.replace_invalid(bytes),
           terminal: true
         }}

      {:ssh_cm, ^ssh, {:eof, ^channel}} ->
        collect(ssh, channel, output, size, status)

      {:ssh_cm, ^ssh, _} ->
        {:error, :command_disconnected}
    end
  end
end
