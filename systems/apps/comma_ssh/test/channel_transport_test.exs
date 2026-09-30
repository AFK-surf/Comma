defmodule CommaSSH.ChannelTransportTest.HostKey do
  @behaviour :ssh_server_key_api
  def host_key(:"ssh-ed25519", options), do: {:ok, options[:key_cb_private][:key]}
  def host_key(_, _), do: {:error, :unsupported}
  def is_auth_key(_, _, _), do: false
end

defmodule CommaSSH.ChannelTransportTest.Shell do
  @behaviour :ssh_server_channel
  # Isolate the real terminal channel from account/storage services. Enrollment
  # and canonical chat have separate coverage in ssh_transport_test.exs.
  def init([mode]) do
    {:ok, state} = CommaSSH.Channel.init([])
    {:ok, Map.put(state, :test_mode, mode)}
  end

  def handle_msg(message, state), do: CommaSSH.Channel.handle_msg(message, state)

  def handle_ssh_msg({:ssh_cm, _, {:shell, _, reply}}, state) do
    :ssh_connection.reply_request(state.connection, reply, :success, state.channel)
    :ssh_connection.send(state.connection, state.channel, CommaTUI.Screen.enter())

    timer =
      if state.test_mode == :timeout, do: :erlang.start_timer(100, self(), :operation_timeout)

    lines =
      case state.test_mode do
        :navigation ->
          Enum.map(1..30, &"line #{&1}")

        :long_navigation ->
          CommaSSH.Chat.transcript(
            Enum.map(1..100, fn n ->
              %{
                "actor_type" => "agent",
                "content" => "message #{n} " <> String.duplicate("x", 7980)
              }
            end)
          )

        _ ->
          []
      end

    {model, []} = CommaSSH.Model.update({:chat, "Test", lines}, state.model)
    model = %{model | busy: timer != nil}
    owner = self()

    backend =
      spawn(fn ->
        Process.monitor(owner)
        test_backend(owner, lines)
      end)

    send(self(), :render)

    if state.test_mode == :task_count do
      send(
        self(),
        {:ui,
         {:task_count,
          CommaSSH.Chat.task_count(%{
            "data" => [
              %{"kind" => "agent_task", "status" => "active"},
              %{"kind" => "agent_task", "status" => "active"}
            ],
            "has_more" => false
          })}}
      )
    end

    {:ok, %{state | started: true, pending: timer, model: model, backend: backend}}
  end

  def handle_ssh_msg(message, state), do: CommaSSH.Channel.handle_ssh_msg(message, state)
  def terminate(reason, state), do: CommaSSH.Channel.terminate(reason, state)

  defp test_backend(owner, lines) do
    receive do
      {:"$gen_cast", {:submit, :chat, text}} ->
        lines =
          lines ++
            CommaSSH.Chat.transcript([
              %{"actor_type" => "user", "content" => text},
              %{"actor_type" => "agent", "content" => "Sent: " <> text}
            ])

        send(owner, {:ui, {:chat, "Test", lines}})

        send(
          owner,
          {:ui, {:task_count, CommaSSH.Chat.task_count(%{"data" => [], "has_more" => false})}}
        )

        send(owner, :done)
        test_backend(owner, lines)

      {:DOWN, _, :process, ^owner, _} ->
        :ok
    end
  end
end

defmodule CommaSSH.ChannelTransportTest do
  use ExUnit.Case, async: false

  test "real PTY remains responsive after a wheel burst over a full transcript" do
    {ssh, channel} = connect(:long_navigation)
    read_until(ssh, channel, "Enter send", "", 30_000)

    :ok =
      :ssh_connection.send(ssh, channel, String.duplicate("\e[<64;10;5M", 120) <> "responsive")

    assert read_until(ssh, channel, "> responsive") =~ "> responsive"

    :ok =
      :ssh_connection.send(ssh, channel, String.duplicate("\e[M" <> <<97, 42, 37>>, 120) <> "!")

    assert read_until(ssh, channel, "> responsive!") =~ "> responsive!"
    :ok = :ssh_connection.send(ssh, channel, "\x04")
    assert read_until(ssh, channel, "\e[?1049l") =~ "\e[?1000l"
  end

  test "real PTY shows workspace running counts and updates them without erasing the draft" do
    {ssh, channel} = connect(:task_count)
    assert read_until(ssh, channel, "2 running") =~ "\e[90m2 running"
    :ok = :ssh_connection.send(ssh, channel, "hello\rdraft")
    assert read_until(ssh, channel, "0 running") =~ "0 running"
    :ok = :ssh_connection.send(ssh, channel, "!")
    assert read_until(ssh, channel, "> draft!") =~ "> draft!"
    :ok = :ssh_connection.window_change(ssh, channel, 20, 8)
    assert read_until(ssh, channel, "0 running") =~ "0 running"
  end

  test "real PTY scrolls with the mouse and restores terminal modes on exit" do
    {ssh, channel} = connect(:navigation)
    output = read_until(ssh, channel, "Enter send")
    assert output =~ "line 30"
    :ok = :ssh_connection.send(ssh, channel, "\e[<64;10;")
    :ok = :ssh_connection.send(ssh, channel, "5M")
    assert read_until(ssh, channel, "line 9") =~ "line 9"
    assert output =~ "\e[?1000h"
    assert output =~ "\e[?1006h"
    :ok = :ssh_connection.send(ssh, channel, String.duplicate("\e[<64;10;5M", 20))
    assert read_until(ssh, channel, "line 1\e") =~ "line 1\e"
    :ok = :ssh_connection.send(ssh, channel, "\e[<65;10;5M")
    assert read_until(ssh, channel, "line 4\e") =~ "line 4\e"
    :ok = :ssh_connection.send(ssh, channel, String.duplicate("\e[<65;10;5M", 20))
    assert read_until(ssh, channel, "line 30") =~ "line 30"
    :ok = :ssh_connection.send(ssh, channel, "\x04")
    output = read_until(ssh, channel, "\e[?1049l")
    assert output =~ "\e[?1000l"
    assert output =~ "\e[?1006l"
  end

  test "real PTY recalls submitted input without losing the draft" do
    {ssh, channel} = connect(:interactive)
    assert read_until(ssh, channel, "Enter send") =~ "\e[90mTasks unavailable · Enter send"
    :ok = :ssh_connection.send(ssh, channel, "previous input\r")
    output = read_until(ssh, channel, "Sent: previous input")
    assert output =~ "\e[36mYou\e[0m"
    assert output =~ "\e[32mComma\e[0m"
    :ok = :ssh_connection.send(ssh, channel, "unfinished\e[A")
    assert read_until(ssh, channel, "> previous input") =~ "> previous input"
    :ok = :ssh_connection.send(ssh, channel, "\e[B")
    assert read_until(ssh, channel, "> unfinished") =~ "> unfinished"
  end

  test "a real SSH timeout restores the terminal and explains uncertain delivery" do
    {ssh, channel} = connect(:timeout)
    output = read_until(ssh, channel, "accepted work may continue.")
    assert output =~ "Operation timed out"
    assert output =~ "check history before resending"
    assert [_, explanation] = String.split(output, CommaTUI.Screen.leave(), parts: 2)
    assert explanation =~ "Comma: Operation timed out"
  end

  test "real PTY handles multiline editing, local command errors and narrow help" do
    {ssh, channel} = connect(:interactive)
    read_until(ssh, channel, "Enter send")
    :ok = :ssh_connection.send(ssh, channel, "alpha\e\rbeta\e[A!")
    assert read_until(ssh, channel, "alph!a") =~ "alph!a"
    :ok = :ssh_connection.send(ssh, channel, "\x03/helpp\r")
    assert read_until(ssh, channel, "Unknown command") =~ "Unknown command"
    :ok = :ssh_connection.send(ssh, channel, "/stop\r")
    assert read_until(ssh, channel, "Stop is not supported") =~ "Stop is not supported"
    :ok = :ssh_connection.window_change(ssh, channel, 42, 12)
    :ok = :ssh_connection.send(ssh, channel, "/help\r")
    assert read_until(ssh, channel, "/quit - disconnect") =~ "/quit - disconnect"
  end

  defp connect(mode) do
    {:ok, _} = Application.ensure_all_started(:ssh)
    key = :public_key.generate_key({:namedCurve, :ed25519})

    {:ok, daemon} =
      :ssh.daemon(0,
        auth_methods: ~c"password",
        pwdfun: fn _, password -> password == ~c"test-only" end,
        key_cb: {CommaSSH.ChannelTransportTest.HostKey, [key: key]},
        ssh_cli: {CommaSSH.ChannelTransportTest.Shell, [mode]},
        shell: :disabled,
        exec: :disabled
      )

    on_exit(fn -> :ssh.stop_daemon(daemon) end)
    {:ok, info} = :ssh.daemon_info(daemon)

    {:ok, ssh} =
      :ssh.connect(~c"localhost", info[:port],
        user: ~c"test",
        password: ~c"test-only",
        user_interaction: false,
        silently_accept_hosts: true,
        save_accepted_host: false
      )

    on_exit(fn -> :ssh.close(ssh) end)
    {:ok, channel} = :ssh_connection.session_channel(ssh, 5_000)
    :success = :ssh_connection.ptty_alloc(ssh, channel, term: ~c"xterm", width: 80, height: 24)
    :ok = :ssh_connection.shell(ssh, channel)
    {ssh, channel}
  end

  defp read_until(ssh, channel, expected, output \\ "", timeout \\ 5_000) do
    if String.contains?(output, expected) do
      output
    else
      receive do
        {:ssh_cm, ^ssh, {:data, ^channel, _, bytes}} ->
          read_until(ssh, channel, expected, output <> bytes, timeout)

        {:ssh_cm, ^ssh, {:closed, ^channel}} ->
          flunk("SSH closed before #{inspect(expected)}: #{inspect(output)}")
      after
        timeout -> flunk("Missing #{inspect(expected)}: #{inspect(output)}")
      end
    end
  end
end
