defmodule Comma.SchemaReadiness do
  @moduledoc """
  Comma-owned, process-local proof that the product schema contract is ready.

  The bounded check starts after `Comma.Repo` and remains false until the exact
  migration contract exists. Kubernetes keeps that Pod out of service; request
  handlers never perform migrations or query schema state themselves.
  """

  use GenServer

  @name __MODULE__
  @retry_ms 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def ready? do
    case Process.whereis(@name) do
      nil -> false
      pid -> GenServer.call(pid, :ready?)
    end
  catch
    :exit, _reason -> false
  end

  @impl true
  def init(opts) do
    repo = Keyword.get(opts, :repo, Comma.Repo)
    state = check(%{repo: repo, ready?: false})
    {:ok, state}
  end

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.ready?, state}

  @impl true
  def handle_info(:recheck, state), do: {:noreply, check(state)}

  defp check(state) do
    ready? = Comma.Schema.ready?(state.repo)
    unless ready?, do: Process.send_after(self(), :recheck, @retry_ms)
    %{state | ready?: ready?}
  end
end
