defmodule SalixStore.ConvergenceWorkerColdImpl do
  @moduledoc """
  Worker-test consumer compiled to a real .beam under _build (test/support),
  so tests can :code.delete/:code.purge it and exercise the cold-BEAM path
  where the module is on the code path but not yet loaded.
  """
  @behaviour SalixStore.Convergence

  @impl true
  def name, do: "test_worker_cold"
  @impl true
  def source_prefix, do: "ctl/test_worker_cold_source/"
  @impl true
  def marker_key, do: "ctl/test_worker_cold_marker.json"
  @impl true
  def reconcile_ms, do: 40
  @impl true
  def converge_record(_key), do: :changed
end

defmodule SalixStore.ConvergenceWorkerBlockingImpl do
  @moduledoc """
  Worker-test consumer whose record callback blocks on a test-owned gate
  process (`:convergence_blocking_gate`), so tests can make a pass
  arbitrarily slow and control exactly when it completes.
  """
  @behaviour SalixStore.Convergence

  @impl true
  def name, do: "test_worker_blocking"
  @impl true
  def source_prefix, do: "ctl/test_worker_blocking_source/"
  @impl true
  def marker_key, do: "ctl/test_worker_blocking_marker.json"
  @impl true
  def reconcile_ms, do: 600

  @impl true
  def converge_record(_key) do
    case Process.whereis(:convergence_blocking_gate) do
      nil ->
        :changed

      gate ->
        send(gate, {:blocked, self()})

        receive do
          :release -> :changed
        after
          5_000 -> :changed
        end
    end
  end
end

defmodule SalixStore.ConvergenceWorkerFastImpl do
  @moduledoc false
  @behaviour SalixStore.Convergence

  @impl true
  def name, do: "test_worker_fast"
  @impl true
  def source_prefix, do: "ctl/test_worker_fast_source/"
  @impl true
  def marker_key, do: "ctl/test_worker_fast_marker.json"
  @impl true
  def reconcile_ms, do: 2_000

  @impl true
  def converge_record(key) do
    case SalixStore.S3.get(key) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"id" => id} = rec} ->
            case SalixStore.CasDirectory.get("ctl/test_worker_fast_dir.json", id) do
              {:ok, ^rec} ->
                :unchanged

              _ ->
                case SalixStore.CasDirectory.put("ctl/test_worker_fast_dir.json", id, rec) do
                  {:ok, _} -> :changed
                  {:error, reason} -> {:error, reason}
                end
            end

          _ ->
            :skip
        end

      {:error, :not_found} ->
        :skip

      {:error, reason} ->
        {:error, reason}
    end
  end
end
