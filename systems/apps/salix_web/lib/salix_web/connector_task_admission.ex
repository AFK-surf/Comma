defmodule SalixWeb.ConnectorTaskAdmission do
  require SystemsRuntime.Proc

  require SystemsClock

  @moduledoc false

  @key {__MODULE__, :counters}
  @lanes [:control, :request, :stream]

  def initialize do
    case SystemsRuntime.PersistentTerm.get(@key, nil) do
      nil ->
        counters = Map.new(@lanes, &{&1, SystemsRuntime.Atomics.new(1, signed: false)})
        SystemsRuntime.PersistentTerm.put(@key, counters)

      counters ->
        missing = @lanes -- Map.keys(counters)

        if missing != [] do
          counters =
            Enum.reduce(missing, counters, fn lane, acc ->
              Map.put(acc, lane, SystemsRuntime.Atomics.new(1, signed: false))
            end)

          SystemsRuntime.PersistentTerm.put(@key, counters)
        end
    end

    :ok
  end

  def acquire(lane, owner) when lane in @lanes and SystemsRuntime.Proc.is_process(owner) do
    counter = counter(lane)

    case increment_below(counter, limit(lane)) do
      :ok ->
        {:ok,
         SystemsRuntime.Proc.spawn(fn ->
           lease_loop(counter, lane, owner, SystemsRuntime.Proc.monitor(owner), nil)
         end)}

      :full ->
        {:error, :overloaded}
    end
  end

  def track(lease, pid)
      when SystemsRuntime.Proc.is_process(lease) and SystemsRuntime.Proc.is_process(pid) do
    ref = SystemsRuntime.Proc.make_ref()
    monitor = SystemsRuntime.Proc.monitor(lease)
    SystemsRuntime.Proc.send(lease, {:track, pid, SystemsRuntime.Proc.self(), ref})

    SystemsClock.vreceive do
      {:connector_task_admission_tracked, ^ref} ->
        SystemsRuntime.Proc.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^lease, _reason} ->
        SystemsRuntime.Proc.exit(pid, :kill)
        {:error, :lease_closed}
    after
      1_000 ->
        SystemsRuntime.Proc.demonitor(monitor, [:flush])
        SystemsRuntime.Proc.exit(pid, :kill)
        SystemsRuntime.Proc.send(lease, :release)
        {:error, :track_timeout}
    end
  end

  def track(_lease, pid) when SystemsRuntime.Proc.is_process(pid) do
    SystemsRuntime.Proc.exit(pid, :kill)
    {:error, :invalid_lease}
  end

  def track(_lease, _pid), do: {:error, :invalid_task}

  def release(lease) when SystemsRuntime.Proc.is_process(lease),
    do: SystemsRuntime.Proc.send(lease, :release)

  def release(_lease), do: :ok

  def count(lane) when lane in @lanes, do: SystemsRuntime.Atomics.get(counter(lane), 1)

  defp counter(lane) do
    initialize()
    SystemsRuntime.PersistentTerm.get(@key) |> Map.fetch!(lane)
  end

  defp increment_below(counter, limit) do
    current = SystemsRuntime.Atomics.get(counter, 1)

    cond do
      current >= limit ->
        :full

      SystemsRuntime.Atomics.compare_exchange(counter, 1, current, current + 1) == :ok ->
        :ok

      true ->
        increment_below(counter, limit)
    end
  end

  defp lease_loop(counter, lane, owner, owner_monitor, tracked) do
    SystemsRuntime.Proc.receive do
      {:track, pid, from, ref} ->
        SystemsRuntime.Proc.send(from, {:connector_task_admission_tracked, ref})
        lease_loop(counter, lane, owner, owner_monitor, pid)

      :release ->
        decrement(counter, lane, owner)

      {:DOWN, ^owner_monitor, :process, _owner, _reason} ->
        if SystemsRuntime.Proc.is_process(tracked), do: SystemsRuntime.Proc.exit(tracked, :kill)
        decrement(counter, lane, owner)
    end
  end

  defp decrement(counter, _lane, _owner) do
    SystemsRuntime.Atomics.sub(counter, 1, 1)
    :ok
  end

  defp limit(:control),
    do: configured_limit(:connector_control_task_limit, 16)

  defp limit(:request),
    do: configured_limit(:connector_request_task_limit, 64)

  defp limit(:stream),
    do: configured_limit(:connector_stream_task_limit, 32)

  defp configured_limit(key, fallback) do
    case SystemsRuntime.get_env(:salix_web, key, fallback) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> fallback
    end
  end
end
