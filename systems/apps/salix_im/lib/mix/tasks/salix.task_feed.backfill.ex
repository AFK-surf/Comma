defmodule Mix.Tasks.Salix.TaskFeed.Backfill do
  use Mix.Task

  @shortdoc "Opens and runs the Task Feed backfill on a node without a release runner"
  @moduledoc """
  A deployed release needs none of this: after core rollout success the
  release opens the backfill (`SalixIM.TaskFeed.open_after_rollout/1`), and
  every Pod drains it (`SalixIM.TaskFeedBackfill`). A local stack opens it
  here and runs its pages until it completes:

      mix salix.task_feed.backfill
      mix salix.task_feed.backfill --max-pages 10

  Each page reads at most 25 Tasks and 500 Messages and records its position
  in the marker `task_feed_v1`, so a later run resumes there.
  """

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [max_pages: :integer])
    max_pages = Keyword.get(opts, :max_pages, 1_000)

    unless positional == [] and invalid == [] and max_pages in 1..100_000//1 do
      Mix.raise("provide at most --max-pages 1..100000")
    end

    Mix.Task.run("app.start")

    case SalixIM.TaskFeed.open_after_rollout("mix salix.task_feed.backfill") do
      {:ok, state} -> Mix.shell().info(Jason.encode!(%{opened: state}))
      {:error, reason} -> Mix.raise("Task feed backfill did not open: #{inspect(reason)}")
    end

    Enum.reduce_while(1..max_pages//1, 0, fn _page, total ->
      case SalixIM.TaskFeed.backfill_page() do
        {:ok, :complete} ->
          Mix.shell().info(Jason.encode!(%{processed: total, done: true}))
          {:halt, total}

        {:ok, %{processed: processed, done: done}} ->
          total = total + processed
          Mix.shell().info(Jason.encode!(%{processed: total, done: done}))
          if done, do: {:halt, total}, else: {:cont, total}

        {:ok, :closed} ->
          Mix.raise("Task feed backfill is not open")

        {:error, reason} ->
          Mix.raise("Task feed backfill stopped: #{inspect(reason)}")
      end
    end)
  end
end
