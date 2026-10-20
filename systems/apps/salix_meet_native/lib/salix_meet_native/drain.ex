defmodule SalixMeetNative.Drain do
  @moduledoc false

  @wait_ms 20_000

  @spec drain(keyword()) :: :ok | {:error, {:meetings_remaining, pos_integer()}}
  def drain(opts \\ []) do
    monitors =
      SalixMeetNative.SessionSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.flat_map(fn
        {_, pid, _, _} when is_pid(pid) ->
          send(pid, :drain)
          [Process.monitor(pid)]

        _ ->
          []
      end)
      |> MapSet.new()

    deadline =
      SystemsClock.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @wait_ms)

    case await(monitors, deadline) do
      0 -> :ok
      n -> {:error, {:meetings_remaining, n}}
    end
  end

  defp await(monitors, deadline) do
    if MapSet.size(monitors) == 0 do
      0
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} ->
          if MapSet.member?(monitors, ref),
            do: await(MapSet.delete(monitors, ref), deadline),
            else: await(monitors, deadline)
      after
        SystemsClock.timeout(max(deadline - SystemsClock.monotonic_time(:millisecond), 0)) ->
          Enum.each(monitors, &Process.demonitor(&1, [:flush]))
          MapSet.size(monitors)
      end
    end
  end
end
