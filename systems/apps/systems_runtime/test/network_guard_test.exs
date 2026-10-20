defmodule SystemsRuntime.NetworkGuardTest do
  # take_blocked/1 reads the whole run's records.
  use ExUnit.Case, async: false

  alias SystemsRuntime.NetworkGuard
  alias SystemsRuntime.NetworkGuard.Blocked

  test "this machine is local and other hosts are not" do
    for address <-
          ["localhost", ~c"localhost", "nohost", "app-shell.localhost", "127.0.0.1", "::1"] ++
            [{127, 0, 0, 2}, {0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}],
        do: assert(NetworkGuard.local?(address), inspect(address))

    for address <- ["registry.npmjs.org", ~c"api.openai.com", "8.8.8.8", {1, 1, 1, 1}],
        do: refute(NetworkGuard.local?(address), inspect(address))
  end

  test "localhost resolves while the hosts file reads as empty" do
    hosts_file = :inet_db.res_option(:hosts_file)
    :ok = :inet_db.res_option(:hosts_file, ~c"")

    try do
      assert {:ok, {127, 0, 0, 1}} = :inet.getaddr(~c"localhost", :inet)
      assert {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} = :inet.getaddr(~c"localhost", :inet6)
    after
      :ok = :inet_db.res_option(:hosts_file, hosts_file)
    end
  end

  test "a connection to this machine goes through" do
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, port} = :inet.port(listener)
    assert {:ok, socket} = :gen_tcp.connect(~c"localhost", port, active: false)
    assert {:ok, _} = :gen_tcp.accept(listener)
    :gen_tcp.close(socket)
  end

  test "a test that connects to another host fails, naming the host and the test" do
    {pid, ref} =
      spawn_monitor(fn ->
        Process.set_label({__MODULE__, :"test reaches the internet"})
        :gen_tcp.connect(~c"registry.npmjs.org", 443, [])
      end)

    # Waits for the message, not for an amount of time.
    assert {%Blocked{} = blocked, _stacktrace} = down(ref, pid)

    assert Exception.message(blocked) =~
             ~s(SystemsRuntime.NetworkGuardTest "test reaches the internet" connected to registry.npmjs.org)

    assert NetworkGuard.take_blocked("registry.npmjs.org") == [
             [{__MODULE__, :"test reaches the internet"}]
           ]
  end

  test "a process working for a test fails that test" do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.set_label({__MODULE__, :"test calls a provider"})

        Task.start(fn ->
          send(parent, {:connect, :gen_tcp.connect({1, 1, 1, 1}, 443, [])})
        end)

        receive do
          :never -> :ok
        end
      end)

    assert {%Blocked{host: "1.1.1.1"}, [_ | _]} = reason = down(ref, pid)

    assert Exception.format_exit(reason) =~
             ~s{(SystemsRuntime.NetworkGuard.Blocked) tests must not use the real network: } <>
               ~s{SystemsRuntime.NetworkGuardTest "test calls a provider" connected to 1.1.1.1}

    receive do
      {:connect, result} -> assert result == {:error, :eacces}
    end

    assert NetworkGuard.take_blocked("1.1.1.1") == [[{__MODULE__, :"test calls a provider"}]]
  end

  test "a lookup outside this machine fails at once and fails the test that made it" do
    for {label, lookup} <- [
          {:"test connects over IPv6",
           fn -> :gen_tcp.connect(~c"api.example.com", 443, [:inet6]) end},
          {:"test resolves a provider", fn -> :inet.getaddrs(~c"api.example.com", :inet) end},
          {:"test asks a name server", fn -> :inet_res.resolve(~c"api.example.com", :in, :a) end}
        ] do
      {result, reason} = lookup_for_test(label, lookup)
      assert {:error, _} = result
      assert {%Blocked{host: "api.example.com"}, [_ | _]} = reason
      assert NetworkGuard.take_blocked("api.example.com") == [[{__MODULE__, label}]]
    end

    assert {:ok, {127, 0, 0, 1}} = :inet.getaddr(~c"localhost", :inet)
    assert {:ok, _} = :inet.getaddrs(~c"localhost", :inet)
    assert NetworkGuard.take_blocked("localhost") == []
  end

  # Runs `lookup` in a process working for the test `label`. The process
  # waits until the test has failed, so the lookup is attributed while the
  # process still lives. Returns the lookup's result and the test's exit reason.
  defp lookup_for_test(label, lookup) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.set_label({__MODULE__, label})

        Task.start(fn ->
          send(parent, {:looked_up, self(), lookup.()})

          receive do
            :done -> :ok
          end
        end)

        receive do
          :never -> :ok
        end
      end)

    receive do
      {:looked_up, worker, result} ->
        reason = down(ref, pid)
        send(worker, :done)
        {result, reason}
    end
  end

  defp down(ref, pid) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    end
  end
end
