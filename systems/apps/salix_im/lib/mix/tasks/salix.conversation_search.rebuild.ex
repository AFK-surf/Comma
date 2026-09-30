defmodule Mix.Tasks.Salix.ConversationSearch.Rebuild do
  use Mix.Task

  @shortdoc "Runs bounded Conversation-search census, repair, and seal stages"

  @moduledoc """
  Online release and repair task for the rebuildable search projection.

      mix salix.conversation_search.rebuild --begin --generation rollout-2026-08-31-a
      mix salix.conversation_search.rebuild --writer-barrier \
        --generation rollout-2026-08-31-a \
        --authority "release-owner:comma-rollout-123"
      mix salix.conversation_search.rebuild --mark-ready --generation rollout-2026-08-31-a
      mix salix.conversation_search.rebuild --gc --generation rollout-2026-08-24-a \
        --batch-size 100 --max-batches 1

  `--writer-barrier` is the human-owner release decision that the named rollout
  generation is fleet-complete. It resets the permanent canonical discovery
  cursor and records the exact owner/change authority. `--mark-ready` succeeds
  only after that required post-barrier cycle and the matching generation's
  durable queue drain. It is the only transition that publishes reader
  readiness.

  A one-Group scoped repair remains available:

      mix salix.conversation_search.rebuild --group grp_... --limit 100
      mix salix.conversation_search.rebuild --group grp_... --limit 100 \
        --cursor <opaque-next-cursor>

  Each repair invocation queues at most one `--limit`-sized page and prints
  `has_more` plus the opaque `next_cursor`. Run the command again with that
  cursor only when another page should be admitted.

  `--gc` is an operator-only, resumable retired-generation cleanup. Each
  invocation runs a bounded number of small transactions and prints the
  durable phase/cursor. It refuses configured, active, reader-ready, or
  retention-window generations.
  """

  alias SalixIM.ConversationSearchProjection
  alias SalixStore.ConversationSearch

  @switches [
    begin: :boolean,
    writer_barrier: :boolean,
    mark_ready: :boolean,
    gc: :boolean,
    generation: :string,
    authority: :string,
    group: :string,
    limit: :integer,
    cursor: :string,
    batch_size: :integer,
    max_batches: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid conversation-search rebuild arguments")
    end

    Mix.Task.run("app.start")

    case selected_mode(opts) do
      :begin -> begin!(opts)
      :writer_barrier -> writer_barrier!(opts)
      :mark_ready -> mark_ready!(opts)
      :gc -> gc!(opts)
      :group -> rebuild_group!(opts)
    end
  end

  defp selected_mode(opts) do
    modes =
      [
        {opts[:begin], :begin},
        {opts[:writer_barrier], :writer_barrier},
        {opts[:mark_ready], :mark_ready},
        {opts[:gc], :gc},
        {is_binary(opts[:group]), :group}
      ]
      |> Enum.flat_map(fn {selected?, mode} -> if selected?, do: [mode], else: [] end)

    case modes do
      [mode] -> mode
      _other -> Mix.raise("select exactly one release stage or --group repair")
    end
  end

  defp begin!(opts) do
    generation = generation!(opts)

    case ConversationSearch.begin_backfill(generation) do
      :ok ->
        Mix.shell().info("started Conversation search rollout #{generation}")

      {:error, reason} ->
        Mix.raise("cannot begin Conversation search rollout: #{inspect(reason)}")
    end
  end

  defp writer_barrier!(opts) do
    generation = generation!(opts)
    authority = opts[:authority] |> to_string() |> String.trim()

    if authority == "" do
      Mix.raise("--authority must identify the human release owner/change decision")
    end

    case ConversationSearch.record_writer_barrier(
           generation,
           authority
         ) do
      :ok -> Mix.shell().info("recorded writer fleet barrier for #{generation}")
      {:error, reason} -> Mix.raise("writer fleet barrier failed: #{inspect(reason)}")
    end
  end

  defp mark_ready!(opts) do
    generation = generation!(opts)

    case ConversationSearch.seal_backfill(generation) do
      :ok ->
        Mix.shell().info("Conversation search projection #{generation} is ready")

      {:error, reason} ->
        Mix.raise("Conversation search projection is not ready: #{inspect(reason)}")
    end
  end

  defp rebuild_group!(opts) do
    group_id = opts[:group]
    limit = opts[:limit] || 100
    cursor = opts[:cursor]

    case ConversationSearchProjection.rebuild_group(
           group_id,
           limit: limit,
           cursor: cursor
         ) do
      {:ok,
       %{
         "queued" => queued,
         "has_more" => has_more,
         "next_cursor" => next_cursor
       }} ->
        Mix.shell().info(
          "queued #{queued} Conversation search rebuild jobs; " <>
            "has_more=#{has_more}; next_cursor=#{next_cursor || "none"}"
        )

      {:error, reason} ->
        Mix.raise("Conversation search rebuild failed: #{inspect(reason)}")
    end
  end

  defp gc!(opts) do
    generation = opts[:generation] || Mix.raise("--generation is required")
    batch_size = opts[:batch_size] || 100
    max_batches = opts[:max_batches] || 1

    if batch_size not in 1..1_000 or max_batches not in 1..10_000 do
      Mix.raise("--batch-size must be 1..1000 and --max-batches must be 1..10000")
    end

    gc_batches!(generation, batch_size, max_batches, 0)
  end

  defp gc_batches!(_generation, _batch_size, max_batches, max_batches), do: :ok

  defp gc_batches!(generation, batch_size, max_batches, completed) do
    case ConversationSearch.gc_retired_generation(generation, batch_size: batch_size) do
      {:ok, result} ->
        Mix.shell().info(
          "Conversation search GC #{generation}: phase=#{result.phase} " <>
            "deleted=#{result.deleted_in_batch} cursor=#{inspect(result.cursor)} " <>
            "totals=#{result.deleted_documents}/#{result.deleted_states}/#{result.deleted_jobs}"
        )

        if result.done do
          :ok
        else
          gc_batches!(generation, batch_size, max_batches, completed + 1)
        end

      {:error, reason} ->
        Mix.raise("Conversation search GC refused or failed: #{inspect(reason)}")
    end
  end

  defp generation!(opts) do
    generation = opts[:generation] || Mix.raise("--generation is required")

    case ConversationSearch.writer_generation() do
      {:ok, ^generation} -> generation
      {:ok, _other} -> Mix.raise("--generation does not match this writer rollout")
      {:error, _reason} -> Mix.raise("SALIX_CONVERSATION_SEARCH_GENERATION is not configured")
    end
  end
end
