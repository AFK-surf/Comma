defmodule SystemsRuntimeTest do
  use ExUnit.Case, async: true

  alias SystemsRuntime.Test, as: Bindings

  setup do
    key = :"probe_#{System.unique_integer([:positive])}"
    on_exit(fn -> Application.delete_env(:systems_runtime, key) end)
    %{key: key}
  end

  test "an unbound key reads the application environment", %{key: key} do
    assert SystemsRuntime.get_env(:systems_runtime, key, :default) == :default
    Application.put_env(:systems_runtime, key, :configured)
    assert SystemsRuntime.get_env(:systems_runtime, key) == :configured
    assert SystemsRuntime.fetch_env(:systems_runtime, key) == {:ok, :configured}
  end

  test "a binding reaches the test's tasks and children, not other processes", %{key: key} do
    Application.put_env(:systems_runtime, key, :configured)
    :ok = Bindings.put_env(:systems_runtime, key, :bound)

    assert SystemsRuntime.get_env(:systems_runtime, key) == :bound

    assert Task.await(
             Task.async(fn -> SystemsRuntime.get_env(:systems_runtime, key) end),
             :infinity
           ) ==
             :bound

    child = start_supervised!({Agent, fn -> nil end})
    assert Agent.get(child, fn _ -> SystemsRuntime.get_env(:systems_runtime, key) end) == :bound

    assert read_elsewhere(key) == :configured
  end

  test "a deleted binding reads as not configured", %{key: key} do
    Application.put_env(:systems_runtime, key, :configured)
    :ok = Bindings.delete_env(:systems_runtime, key)

    assert SystemsRuntime.fetch_env(:systems_runtime, key) == :error
    assert SystemsRuntime.get_env(:systems_runtime, key, :default) == :default
  end

  test "a binding ends when its owner exits", %{key: key} do
    test = self()
    reader = start_reader(key)

    owner =
      spawn(fn ->
        :ok = Bindings.put_env(:systems_runtime, key, :bound)
        :ok = Bindings.allow(reader)
        send(test, :bound)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :bound
    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}

    send(reader, {:read, self()})
    assert_receive {:read, :unset}
  end

  test "an allowed process reads the caller's bindings, including later ones", %{key: key} do
    reader = start_reader(key)
    :ok = Bindings.allow(reader)
    :ok = Bindings.put_env(:systems_runtime, key, :bound)

    send(reader, {:read, self()})
    assert_receive {:read, :bound}
  end

  defp read_elsewhere(key) do
    reader = start_reader(key)
    send(reader, {:read, self()})
    assert_receive {:read, value}
    value
  end

  # A process with no `$callers` or `$ancestors` link to the test.
  defp start_reader(key) do
    spawn(fn ->
      receive do
        {:read, to} -> send(to, {:read, SystemsRuntime.get_env(:systems_runtime, key, :unset)})
      end
    end)
  end
end

defmodule SystemsRuntime.SharedTest do
  use ExUnit.Case, async: false

  alias SystemsRuntime.Test, as: Bindings

  test "shared bindings reach every process until their owner exits" do
    test = self()

    owner =
      spawn(fn ->
        :ok = Bindings.shared()
        :ok = Bindings.put_env(:systems_runtime, :shared_probe_key, :bound)
        send(test, :bound)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :bound
    assert SystemsRuntime.get_env(:systems_runtime, :shared_probe_key) == :bound
    assert_raise ArgumentError, &Bindings.shared/0

    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, _}
    assert SystemsRuntime.get_env(:systems_runtime, :shared_probe_key) == nil
  end
end
