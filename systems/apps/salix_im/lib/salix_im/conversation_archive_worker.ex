defmodule SalixIM.ConversationArchiveWorker do
  @moduledoc false
  use SystemsRuntime.Server

  alias SalixIM.{ConversationPGStore, ConversationServer}

  @page_size 16
  @batch_size 256
  @idle_ms 30_000
  @interval_ms 1_000

  def start_link(opts \\ []),
    do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  def sweep(after_key \\ nil, now \\ SystemsClock.system_time(:millisecond)) do
    with {:ok, %{rows: rows}} <-
           ConversationPGStore.archive_work_page(
             after_key,
             @page_size,
             now - @idle_ms,
             @batch_size
           ) do
      results =
        for [group, conversation, true] <- rows do
          {group, conversation, archive(group, conversation)}
        end

      next = if rows == [], do: nil, else: Enum.take(List.last(rows), 2)
      {:ok, next, results}
    end
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, after_key) do
    next =
      case sweep(after_key) do
        {:ok, next, _results} -> next
        {:error, _} -> after_key
      end

    schedule()
    {:noreply, next}
  end

  defp archive(group, conversation) do
    ConversationServer.archive_messages(group, conversation)
  rescue
    _ -> {:error, :archive_failed}
  catch
    :exit, _ -> {:error, :archive_failed}
  end

  defp schedule,
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, @interval_ms)
end
