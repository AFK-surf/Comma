defmodule SalixAgent.Decide.Limits do
  @moduledoc "Node-local per-Tenant/Group request budgets for decide callers. All callers share one budget, except the Condensed Workspace check, which has its own. DependencyAdmission bounds in-flight work."
  use SystemsRuntime.Server

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  def admit(tenant, group), do: request(tenant, group, nil)

  @doc """
  Admits one request against a caller's own budget instead of the shared one.
  It never waits: an exhausted budget returns `{:error, :rate_limited}`.
  """
  def admit_scope(tenant, group, :condensed_workspace = scope),
    do: request(tenant, group, nil, scope)

  # Wait before provider admission. No provider work, charge, or in-flight slot
  # exists while a bounded background caller waits for this shared budget.
  def admit_until(tenant, group, deadline) when is_integer(deadline) do
    if SystemsClock.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      case request(tenant, group, deadline) do
        {:wait, delay} ->
          remaining = deadline - SystemsClock.monotonic_time(:millisecond)

          if delay < remaining do
            SystemsClock.sleep(delay)
            admit_until(tenant, group, deadline)
          else
            {:error, :timeout}
          end

        :ok ->
          if SystemsClock.monotonic_time(:millisecond) < deadline,
            do: :ok,
            else: {:error, :timeout}

        result ->
          result
      end
    end
  end

  defp request(tenant, group, deadline, scope \\ :shared) do
    timeout =
      if is_integer(deadline),
        do: max(deadline - SystemsClock.monotonic_time(:millisecond), 1),
        else: 200

    SystemsClock.call(
      __MODULE__,
      {:admit, tenant, group, deadline, scope},
      SystemsClock.timeout(timeout)
    )
  catch
    :exit, {:timeout, _} when is_integer(deadline) -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:admit, tenant, group, deadline, scope}, _from, state) do
    now = SystemsClock.monotonic_time(:millisecond)

    if is_integer(deadline) and now >= deadline do
      {:reply, {:error, :timeout}, state}
    else
      reserve(tenant, group, scope, now, deadline, state)
    end
  end

  defp reserve(tenant, group, scope, now, deadline, state) do
    {per_minute, per_second} = limits(scope)
    owner = if scope == :shared, do: {tenant, group}, else: {tenant, group, scope}

    buckets = [
      {{owner, Integer.floor_div(now, 60_000), :minute}, per_minute, 60_000},
      {{owner, Integer.floor_div(now, 1_000), :second}, per_second, 1_000}
    ]

    if Enum.all?(buckets, fn {key, limit, _} -> Map.get(state, key, 0) < limit end) do
      state =
        Enum.reduce(buckets, state, fn {key, _, ttl}, acc ->
          if not Map.has_key?(acc, key),
            do: SystemsClock.send_after(SystemsRuntime.Proc.self(), {:expire, key}, ttl * 2)

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

  # A Group with several busy Sessions makes one check per tool round in each.
  defp limits(:condensed_workspace), do: {120, 8}
  defp limits(:shared), do: {60, 4}

  @impl true
  def handle_info({:expire, key}, state), do: {:noreply, Map.delete(state, key)}
end
