defmodule SalixAgent.Decide.Limits do
  @moduledoc "Node-local per-Tenant/Group request budgets shared by decide callers. DependencyAdmission bounds in-flight work."
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def admit(tenant, group), do: request(tenant, group, nil)

  # Wait before provider admission. No provider work, charge, or in-flight slot
  # exists while a bounded background caller waits for this shared budget.
  def admit_until(tenant, group, deadline) when is_integer(deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      case request(tenant, group, deadline) do
        {:wait, delay} ->
          remaining = deadline - System.monotonic_time(:millisecond)

          if delay < remaining do
            Process.sleep(delay)
            admit_until(tenant, group, deadline)
          else
            {:error, :timeout}
          end

        :ok ->
          if System.monotonic_time(:millisecond) < deadline, do: :ok, else: {:error, :timeout}

        result ->
          result
      end
    end
  end

  defp request(tenant, group, deadline) do
    timeout =
      if is_integer(deadline),
        do: max(deadline - System.monotonic_time(:millisecond), 1),
        else: 200

    GenServer.call(__MODULE__, {:admit, tenant, group, deadline}, timeout)
  catch
    :exit, {:timeout, _} when is_integer(deadline) -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:admit, tenant, group, deadline}, _from, state) do
    now = System.monotonic_time(:millisecond)

    if is_integer(deadline) and now >= deadline do
      {:reply, {:error, :timeout}, state}
    else
      reserve(tenant, group, now, deadline, state)
    end
  end

  defp reserve(tenant, group, now, deadline, state) do
    buckets = [
      {{{tenant, group}, Integer.floor_div(now, 60_000), :minute}, 60, 60_000},
      {{{tenant, group}, Integer.floor_div(now, 1_000), :second}, 4, 1_000}
    ]

    if Enum.all?(buckets, fn {key, limit, _} -> Map.get(state, key, 0) < limit end) do
      state =
        Enum.reduce(buckets, state, fn {key, _, ttl}, acc ->
          if not Map.has_key?(acc, key), do: Process.send_after(self(), {:expire, key}, ttl * 2)
          Map.update(acc, key, 1, &(&1 + 1))
        end)

      {:reply, :ok, state}
    else
      delay =
        buckets
        |> Enum.filter(fn {key, limit, _} -> Map.get(state, key, 0) >= limit end)
        |> Enum.map(fn {{_, window, _}, _, period} -> (window + 1) * period - now end)
        |> Enum.max()

      {:reply, if(deadline, do: {:wait, delay}, else: {:error, :rate_limited}), state}
    end
  end

  @impl true
  def handle_info({:expire, key}, state), do: {:noreply, Map.delete(state, key)}
end
