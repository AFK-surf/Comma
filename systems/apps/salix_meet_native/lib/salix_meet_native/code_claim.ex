defmodule SalixMeetNative.CodeClaim do
  @moduledoc false
  use GenServer

  @spec claim(term(), pid()) :: {:ok, pid()} | {:taken, pid() | :undefined}
  def claim(key, runtime) do
    case GenServer.start(__MODULE__, runtime, name: {:global, key}) do
      {:ok, claim} -> {:ok, claim}
      {:error, {:already_started, holder}} -> {:taken, owner(holder)}
    end
  end

  @spec owner(pid()) :: pid() | :undefined
  def owner(claim) do
    SystemsClock.call(claim, :owner, 5_000)
  catch
    :exit, _ -> :undefined
  end

  def release(claim), do: GenServer.stop(claim, :normal, 5_000)

  @impl true
  def init(runtime) do
    Process.monitor(runtime)
    {:ok, runtime}
  end

  @impl true
  def handle_call(:owner, _from, runtime), do: {:reply, runtime, runtime}

  @impl true
  def handle_info({:DOWN, _ref, :process, runtime, _reason}, runtime),
    do: {:stop, :normal, runtime}
end
