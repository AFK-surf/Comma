defmodule SalixIM.TaskFeedBackfill do
  @moduledoc """
  Drains the Task Feed backfill (`SalixIM.TaskFeed.backfill_page/0`) once the
  release opens it, then stops. One process per Pod: the marker records each
  page's position, so Pods that run the same page project the same entries and
  one of them records it.

  Bounds: one page (at most 25 Tasks and 500 Messages) per turn; the next turn
  100 ms after a page, 30 s while the release has not opened the backfill, and
  5 s after a failure.
  """
  use SystemsRuntime.Server
  require Logger
  alias SalixIM.TaskFeed

  @page_ms 100
  @closed_ms 30_000
  @retry_ms 5_000

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, schedule(%{timer: nil}, 0)}

  @impl true
  def handle_info(:tick, state) do
    case step() do
      :complete -> {:noreply, %{state | timer: nil}}
      {:again, delay} -> {:noreply, schedule(%{state | timer: nil}, delay)}
    end
  end

  defp step do
    case TaskFeed.backfill_page() do
      {:ok, :complete} -> :complete
      {:ok, %{done: true}} -> :complete
      {:ok, :closed} -> {:again, @closed_ms}
      {:ok, %{done: false}} -> {:again, @page_ms}
      {:error, reason} -> failed(reason)
    end
  rescue
    exception -> failed(Exception.message(exception))
  catch
    :exit, reason -> failed(reason)
  end

  defp failed(reason) do
    Logger.warning("Task feed backfill page failed; retrying: #{inspect(reason)}")
    {:again, @retry_ms}
  end

  defp schedule(state, delay),
    do: %{state | timer: SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, delay)}
end
