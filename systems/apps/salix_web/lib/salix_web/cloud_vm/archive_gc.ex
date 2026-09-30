defmodule SalixWeb.CloudVM.ArchiveGC do
  @moduledoc """
  Deletes only archive generations retired by their owning Group Workload.

  Each pass deletes at most one page. The Workload intent remains durable until
  every object under that exact generation prefix is gone.
  """

  use GenServer
  require Logger

  alias SalixStore.{Compute, S3}
  alias SalixWeb.CloudVM.ArchiveR2
  alias SalixWeb.CloudVM.DurableArchive

  @interval_ms 15_000
  @page_size 50

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule(1_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, state) do
    result = run_once()

    next_state =
      case result do
        {:error, reason} when state != reason ->
          Logger.warning("Cloud VM archive cleanup failed: #{inspect(reason)}")
          reason

        {:error, reason} ->
          reason

        _ ->
          nil
      end

    schedule(@interval_ms)
    {:noreply, next_state}
  end

  @doc "Process one bounded page of one retired generation."
  def run_once do
    case Compute.next_group_archive_gc() do
      :none -> :idle
      {:ok, group_id, entry} -> delete_page(group_id, entry)
      {:error, _} = error -> error
    end
  end

  defp delete_page(group_id, entry) do
    operation = if is_map(entry), do: entry["operation"], else: entry
    storage = if is_map(entry), do: entry["storage"], else: "salix_s3"
    prefix = DurableArchive.chunk_prefix(group_id, operation)

    with {:ok, %{keys: keys, complete: complete}} <- list_keys(storage, prefix),
         true <- Enum.all?(keys, &String.starts_with?(&1, prefix)),
         :ok <- delete_objects(storage, keys) do
      if complete,
        do: Compute.finish_group_archive_gc(group_id, entry),
        else: {:ok, :partial}
    else
      false -> {:error, :invalid_archive_gc_page}
      {:error, _} = error -> error
      _ -> {:error, :invalid_archive_gc_page}
    end
  end

  defp list_keys("r2", prefix), do: ArchiveR2.list(prefix, @page_size)

  defp list_keys("salix_s3", prefix) do
    case S3.list(prefix, max_keys: @page_size) do
      {:ok, %{objects: objects, next: next}} ->
        {:ok, %{keys: Enum.map(objects, & &1.key), complete: is_nil(next)}}

      error ->
        error
    end
  end

  defp list_keys(_, _), do: {:error, :invalid_archive_gc_storage}

  defp delete_objects(storage, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      result = if storage == "r2", do: ArchiveR2.delete(key), else: S3.delete(key)

      case result do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp schedule(after_ms), do: Process.send_after(self(), :tick, after_ms)
end
