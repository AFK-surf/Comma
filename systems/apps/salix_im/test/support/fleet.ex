defmodule SalixIM.TestSupport.Fleet do
  @moduledoc false

  defmodule Cleanup do
    @moduledoc false
    use GenServer

    # Start after test dependencies. Supervisor shutdown runs this fence before
    # it stops the mocks that Conversation children still use.
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      {:ok, opts}
    end

    @impl true
    def terminate(_reason, opts) do
      SalixIM.TestSupport.Fleet.stop_all!(
        Keyword.get(opts, :supervisor, SalixIM.ConversationFleetSup),
        Keyword.get(opts, :registry, SalixIM.ConversationRegistry)
      )
    end
  end

  @max_attempts 200
  @poll_ms 10
  @stable_empty_observations 2

  def stop_all! do
    stop_all!(SalixIM.ConversationFleetSup, SalixIM.ConversationRegistry)
  end

  def stop_all!(supervisor, registry) do
    quiesce(@max_attempts, 0, supervisor, registry)
  end

  defp quiesce(0, _stable_empty_observations, supervisor, registry) do
    raise """
    conversation fleet did not quiesce after #{@max_attempts} polling attempts \
    (#{@poll_ms}ms interval, excluding synchronous child shutdown time):
    #{inspect(diagnostics(supervisor, registry), pretty: true, limit: :infinity)}
    """
  end

  defp quiesce(attempts_left, stable_empty_observations, supervisor, registry) do
    terminate_children(current_children(supervisor), supervisor)

    case diagnostics(supervisor, registry) do
      %{active: 0, specs: 0, registry_count: 0} ->
        stable_empty_observations = stable_empty_observations + 1

        if stable_empty_observations >= @stable_empty_observations do
          :ok
        else
          Process.sleep(@poll_ms)
          quiesce(attempts_left - 1, stable_empty_observations, supervisor, registry)
        end

      _still_active ->
        Process.sleep(@poll_ms)
        quiesce(attempts_left - 1, 0, supervisor, registry)
    end
  end

  defp terminate_children(children, supervisor) do
    Enum.each(children, fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, reason} -> raise "failed to stop conversation fleet child: #{inspect(reason)}"
        end

      # DynamicSupervisor exposes no addressable pid while a child is restarting.
      # The specs: 0 quiescence fence below keeps polling until it restarts or disappears.
      _restarting_child ->
        :ok
    end)
  end

  defp diagnostics(supervisor, registry) do
    children = current_children(supervisor)
    counts = child_counts(supervisor)

    %{
      active: counts.active,
      specs: counts.specs,
      restarting: counts.specs - counts.active,
      children:
        Enum.map(children, fn {id, pid, type, modules} ->
          %{
            id: id,
            pid: pid,
            alive?: is_pid(pid) and Process.alive?(pid),
            type: type,
            modules: modules,
            registry_keys: if(is_pid(pid), do: registry_keys(registry, pid), else: [])
          }
        end),
      registry_count: registry_count(registry),
      registry_entries: registry_entries(registry)
    }
  rescue
    error in [ArgumentError, ArithmeticError] ->
      # Registry can outlive a partition's ETS table during shutdown or restart.
      # Retry the observation; do not report an unavailable partition as empty.
      %{registry_unavailable: Exception.message(error)}
  end

  defp current_children(supervisor) do
    case Process.whereis(supervisor) do
      nil -> []
      _pid -> DynamicSupervisor.which_children(supervisor)
    end
  end

  defp child_counts(supervisor) do
    case Process.whereis(supervisor) do
      nil -> %{active: 0, specs: 0}
      _pid -> Map.take(DynamicSupervisor.count_children(supervisor), [:active, :specs])
    end
  end

  defp registry_count(registry) do
    case Process.whereis(registry) do
      nil -> 0
      _pid -> Registry.count(registry)
    end
  end

  defp registry_entries(registry) do
    case Process.whereis(registry) do
      nil ->
        []

      _pid ->
        Registry.select(
          registry,
          [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}]
        )
    end
  end

  defp registry_keys(registry, pid) do
    case Process.whereis(registry) do
      nil -> []
      _registry -> Registry.keys(registry, pid)
    end
  end
end
