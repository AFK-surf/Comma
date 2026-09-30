defmodule SalixWeb.ConnectorTaskAdmission do
  @moduledoc false

  @key {__MODULE__, :counters}
  @lanes [:control, :request, :stream, :external_event]

  def initialize do
    case :persistent_term.get(@key, nil) do
      nil ->
        counters = Map.new(@lanes, &{&1, :atomics.new(1, signed: false)})
        :persistent_term.put(@key, counters)

      counters ->
        missing = @lanes -- Map.keys(counters)

        if missing != [] do
          counters =
            Enum.reduce(missing, counters, fn lane, acc ->
              Map.put(acc, lane, :atomics.new(1, signed: false))
            end)

          :persistent_term.put(@key, counters)
        end
    end

    :ok
  end

  def acquire(lane, owner) when lane in @lanes and is_pid(owner) do
    counter = counter(lane)

    case increment_below(counter, limit(lane)) do
      :ok ->
        {:ok,
         spawn(fn ->
           lease_loop(counter, lane, owner, Process.monitor(owner), nil)
         end)}

      :full ->
        {:error, :overloaded}
    end
  end

  def track(lease, pid) when is_pid(lease) and is_pid(pid) do
    ref = make_ref()
    monitor = Process.monitor(lease)
    send(lease, {:track, pid, self(), ref})

    receive do
      {:connector_task_admission_tracked, ^ref} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^lease, _reason} ->
        Process.exit(pid, :kill)
        {:error, :lease_closed}
    after
      1_000 ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
        send(lease, :release)
        {:error, :track_timeout}
    end
  end

  def track(_lease, pid) when is_pid(pid) do
    Process.exit(pid, :kill)
    {:error, :invalid_lease}
  end

  def track(_lease, _pid), do: {:error, :invalid_task}

  def release(lease) when is_pid(lease), do: send(lease, :release)
  def release(_lease), do: :ok

  def count(lane) when lane in @lanes, do: :atomics.get(counter(lane), 1)

  defp counter(lane) do
    initialize()
    :persistent_term.get(@key) |> Map.fetch!(lane)
  end

  defp increment_below(counter, limit) do
    current = :atomics.get(counter, 1)

    cond do
      current >= limit ->
        :full

      :atomics.compare_exchange(counter, 1, current, current + 1) == :ok ->
        :ok

      true ->
        increment_below(counter, limit)
    end
  end

  defp lease_loop(counter, lane, owner, owner_monitor, tracked) do
    receive do
      {:track, pid, from, ref} ->
        send(from, {:connector_task_admission_tracked, ref})
        lease_loop(counter, lane, owner, owner_monitor, pid)

      :release ->
        decrement(counter, lane, owner)

      {:DOWN, ^owner_monitor, :process, _owner, _reason} ->
        if is_pid(tracked), do: Process.exit(tracked, :kill)
        decrement(counter, lane, owner)
    end
  end

  defp decrement(counter, lane, owner) do
    :atomics.sub(counter, 1, 1)

    if lane == :external_event do
      send(owner, {:connector_task_admission_released, lane})
    end

    :ok
  end

  defp limit(:control),
    do: configured_limit(:connector_control_task_limit, 16)

  defp limit(:request),
    do: configured_limit(:connector_request_task_limit, 64)

  defp limit(:stream),
    do: configured_limit(:connector_stream_task_limit, 32)

  defp limit(:external_event),
    do: configured_limit(:connector_external_event_task_limit, 64)

  defp configured_limit(key, fallback) do
    case Application.get_env(:salix_web, key, fallback) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> fallback
    end
  end
end
