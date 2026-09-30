defmodule SalixEnv.VM.Providers.Cloudflare.Attachments do
  @moduledoc """
  Per-node Cloudflare VM attachment supervisor.
  """

  use DynamicSupervisor

  alias SalixEnv.VM.Providers.Cloudflare.Attachment
  @behaviour SalixEnv.VM.Attachment

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @impl true
  def ensure(opts) do
    case DynamicSupervisor.start_child(__MODULE__, {Attachment, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def whereis(env_id) do
    case Registry.lookup(SalixEnv.VM.Providers.Cloudflare.AttachmentRegistry, env_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @impl true
  def stop(env_id) do
    case whereis(env_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  @spec stop_all() :: map()
  def stop_all do
    stop_children(DynamicSupervisor.which_children(__MODULE__))
  catch
    :exit, reason -> %{completed: 0, timeout: 0, error: 1, errors: [reason]}
  end

  defp stop_children(children) do
    Enum.reduce(children, %{completed: 0, timeout: 0, error: 0, errors: []}, fn
      {_, pid, _, _}, acc when is_pid(pid) ->
        stop_child(pid, acc)

      _child, acc ->
        acc
    end)
  end

  defp stop_child(pid, acc) do
    case GenServer.stop(pid, :normal, 5_000) do
      :ok ->
        Map.update!(acc, :completed, &(&1 + 1))
    end
  catch
    :exit, {:timeout, _} ->
      acc
      |> Map.update!(:timeout, &(&1 + 1))
      |> Map.update!(:errors, &[{:timeout, pid} | &1])

    :exit, reason ->
      acc
      |> Map.update!(:error, &(&1 + 1))
      |> Map.update!(:errors, &[{pid, reason} | &1])
  end
end
