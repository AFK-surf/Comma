defmodule SalixAnalytics.SlackSemanticJob do
  @moduledoc """
  Reference-only Oban work. Live observations never coalesce, including while
  an old executor has been rescued: old completion cannot remove a new job.
  Modeled in tla/salix/SemanticIndexScheduling.tla.
  """
  use Oban.Worker, max_attempts: 20
  alias SalixAnalytics.{SlackSemanticIndex, SlackMessageSearchIndexer, SlackSemanticQueue}

  @impl true
  def perform(%Oban.Job{args: args} = job) do
    started = System.monotonic_time()
    result = execute(args)

    operation =
      if args["kind"] == "text", do: "slack_semantic_index", else: "slack_semantic_file_index"

    outcome =
      case result do
        :ok -> "ok"
        {:cancel, _} -> "cancelled"
        {:snooze, 1} -> "partial"
        _ -> "error"
      end

    SlackSemanticIndex.observe(operation, started, outcome)
    if result == :ok, do: report_completion(job)
    result
  end

  defp execute(args) do
    scope = args["scope"]
    timestamp = args["timestamp"]
    live = args["live"]
    cancelled = fn -> not live and SlackSemanticQueue.pending_live?() end

    result =
      cond do
        not SlackSemanticIndex.active?() ->
          {:cancel, :indexing_disabled}

        cancelled.() ->
          {:snooze, 1}

        args["kind"] == "text" ->
          text(scope, timestamp, args["text_start"] || 0, live, cancelled)

        args["kind"] == "enumerate" ->
          enumerate(scope, timestamp, live, cancelled)

        args["kind"] == "file" ->
          SlackMessageSearchIndexer.file(scope, timestamp, args["file_id"], cancelled: cancelled)
      end

    case result do
      {:error, reason}
      when reason in [:source_pending, :source_changed, :file_changed, :superseded_build] ->
        {:snooze, 1}

      {:error, :source_initializing} ->
        {:snooze, 30}

      {:error, :preempted} ->
        {:snooze, 1}

      {:error, reason} when reason in [:semantic_unavailable, :semantic_attachment_unavailable] ->
        {:snooze, 5}

      {:error, :unsupported_attachment} ->
        {:cancel, :unsupported_attachment}

      {:error, :attachment_inaccessible} ->
        {:cancel, :attachment_inaccessible}

      result ->
        result
    end
  end

  defp text(scope, timestamp, start, live, cancelled) do
    result =
      SlackMessageSearchIndexer.text(scope, timestamp, start, live: live, cancelled: cancelled)

    with :ok <- enqueue_text_continuation(result, scope, timestamp, live),
         {:ok, _} <-
           if(start == 0,
             do: SlackSemanticQueue.enqueue(scope, timestamp, "enumerate", live),
             else: {:ok, nil}
           ) do
      :ok
    end
  end

  defp enqueue_text_continuation(:ok, _scope, _timestamp, _live), do: :ok

  defp enqueue_text_continuation({:continue, next}, scope, timestamp, live) do
    with {:ok, _} <- SlackSemanticQueue.enqueue(scope, timestamp, "text", live, nil, next),
         do: :ok
  end

  defp enqueue_text_continuation(error, _scope, _timestamp, _live), do: error

  defp report_completion(job) do
    age = max(DateTime.diff(DateTime.utc_now(), job.inserted_at, :millisecond), 0) / 1000

    :telemetry.execute([:salix, :semantic_queue, :complete], %{age_seconds: age}, %{
      lane: if(job.args["live"], do: "live", else: "history"),
      kind: job.args["kind"]
    })
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp enumerate(scope, timestamp, live, cancelled) do
    with {:ok, rows} <- SlackSemanticIndex.source_document(scope, timestamp) do
      rows
      |> Enum.flat_map(fn row ->
        files = row["source_files"] || "[]"
        if byte_size(files) <= 65536, do: Jason.decode!(files), else: []
      end)
      |> Enum.map(& &1["id"])
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) in 1..128))
      |> Enum.uniq()
      |> Enum.reduce_while(:ok, fn id, _ ->
        if cancelled.() do
          {:halt, {:error, :preempted}}
        else
          case SlackSemanticQueue.enqueue(scope, timestamp, "file", live, id) do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end
        end
      end)
    end
  end
end
