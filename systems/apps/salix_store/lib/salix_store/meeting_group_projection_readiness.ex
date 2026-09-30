defmodule SalixStore.MeetingGroupProjectionReadiness do
  @moduledoc """
  Process-local proof that the meeting group projection backfill is sealed.

  The release marker is checked off the request path. Bounded meeting reads
  fail closed until this proof is true, while general Salix pod readiness stays
  independent so the projection-first fleet can roll before a later online
  backfill release.
  """

  use GenServer

  alias SalixStore.MeetingGroupProjections

  @name __MODULE__
  @retry_ms 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @spec ready?() :: boolean()
  def ready? do
    case Process.whereis(@name) do
      nil -> false
      pid -> GenServer.call(pid, :ready?)
    end
  catch
    :exit, _reason -> false
  end

  @doc false
  def refresh do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> GenServer.call(pid, :refresh)
    end
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(_opts), do: {:ok, check(%{ready?: false})}

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.ready?, state}

  def handle_call(:refresh, _from, state) do
    state = check(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:recheck, state), do: {:noreply, check(state)}

  defp check(state) do
    ready? = MeetingGroupProjections.ready?()
    unless ready?, do: Process.send_after(self(), :recheck, @retry_ms)
    %{state | ready?: ready?}
  end
end
