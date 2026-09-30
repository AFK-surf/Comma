defmodule SalixAnalytics.SlackMessageSearchIndexer do
  @moduledoc """
  Complete, sequence-fenced search components over canonical Slack source.

  A text job handles at most sixteen 400-codepoint slices (40 overlap). The
  next slice is a separate durable job, so text beyond 8,000 characters is not
  silently omitted or trapped in a job that can never meet its deadline.
  One attachment is inserted only after the existing extraction stream has
  completed and validated every unit. MessageSearchBuild.tla models this seam.
  """
  alias SalixAnalytics.{SlackMessageSearchIndex, SlackSemanticIndex}
  alias SalixStore.SlackSearchSources
  @slices_per_job 16
  @step 360
  @width 400

  def text(scope, timestamp, start, opts \\ []) when is_integer(start) and start >= 0 do
    with :ok <- valid_scope(scope),
         {:ok, indexed} <- SlackMessageSearchIndex.indexed_components(scope, timestamp),
         {:ok, captured} <- SlackSearchSources.capture(scope, timestamp),
         build = %{"build_sequence" => captured.build_sequence},
         {:ok, rows} <-
           SlackMessageSearchIndex.source(scope, timestamp, start, @step * @slices_per_job + 40) do
      case rows do
        [] ->
          :ok

        [source] ->
          with :ok <- ensure_document(scope, source, indexed, captured) do
            if source["deleted"] do
              :ok
            else
              with :ok <- text_slices(scope, source, indexed, captured, build, start, opts) do
                next = start + @step * @slices_per_job
                if next < source["source_characters"], do: {:continue, next}, else: :ok
              end
            end
          end
      end
    end
  end

  def file(scope, timestamp, file_id, opts \\ []) do
    extractor = Application.get_env(:salix_analytics, :slack_semantic_file_source)

    with :ok <- valid_scope(scope),
         {:ok, indexed} <- SlackMessageSearchIndex.indexed_components(scope, timestamp),
         {:ok, captured} <- SlackSearchSources.capture(scope, timestamp, file_id),
         build = %{"build_sequence" => captured.build_sequence},
         {:ok, rows} <- SlackMessageSearchIndex.source(scope, timestamp, 0, 0) do
      case rows do
        [%{"deleted" => false} = source] ->
          component = "file:#{file_id}"
          old = indexed[component]

          with :ok <- ensure_document(scope, source, indexed, captured),
               {:ok, files} <- Jason.decode(source["source_files"]),
               file when is_map(file) <- Enum.find(files, &(&1["id"] == file_id)) do
            cond do
              captured.file_deleted ->
                store(scope, source, captured, build, component, file_id, [])

              current?(old, source, captured) and old["file_epoch"] == captured.file_epoch and
                  (not editable?(file) or old["refresh_due"] in [false, 0]) ->
                publish_existing(scope, source, old)

              true ->
                with {:ok, units} <-
                       extractor.extract(
                         scope,
                         file_id,
                         &SlackSemanticIndex.media(&1, &2, opts),
                         opts
                       ) do
                  store(scope, source, captured, build, component, file_id, units)
                end
            end
          else
            nil -> :ok
            error -> error
          end

        [%{"deleted" => true} = source] ->
          ensure_document(scope, source, indexed, captured)

        _ ->
          :ok
      end
    end
  end

  defp ensure_document(scope, source, indexed, captured) do
    if current?(indexed["lexical"], source, captured),
      do: publish_existing(scope, source, indexed["lexical"]),
      else: SlackMessageSearchIndex.document(scope, source, captured)
  end

  defp text_slices(scope, source, indexed, captured, build, start, opts) do
    points = String.codepoints(source["source_text"])
    cancelled = Keyword.get(opts, :cancelled, fn -> false end)

    0..(@slices_per_job - 1)
    |> Enum.reduce_while(:ok, fn number, :ok ->
      offset = number * @step
      text = points |> Enum.slice(offset, @width) |> Enum.join()
      component = "text:#{start + offset}"
      old = indexed[component]

      result =
        cond do
          cancelled.() ->
            {:error, :preempted}

          start + offset >= source["source_characters"] ->
            :ok

          current?(old, source, captured) ->
            publish_existing(scope, source, old)

          String.trim(text) == "" ->
            :ok

          true ->
            with {:ok, vector} <-
                   SlackSemanticIndex.embed(text,
                     background: true,
                     live: Keyword.get(opts, :live, false)
                   ) do
              unit = %{
                "text" => text,
                "embedding" => vector,
                "content_kind" => "message_text",
                "page" => 0,
                "segment_start_ms" => 0,
                "segment_end_ms" => 0
              }

              store(scope, source, captured, build, component, "", [unit])
            end
        end

      case result do
        :ok ->
          {:cont, :ok}

        {:error, reason} when reason in [:source_changed, :source_pending, :superseded_build] ->
          {:halt, :ok}

        error ->
          {:halt, error}
      end
    end)
  end

  defp current?(old, source, captured) when is_map(old),
    do:
      old["change_epoch"] == captured.change_epoch and
        old["message_identity"] == source["message_identity"] and
        old["payload_identity"] == source["payload_identity"]

  defp current?(_, _, _), do: false

  defp publish_existing(scope, source, old),
    do: scope |> Map.merge(source) |> Map.merge(old) |> SlackSearchSources.publish()

  defp store(scope, source, captured, build, component, file_id, units) do
    # The sequence is allocated before the source read. Every complete component
    # in this job gets its own non-reused build ID; transport never retries a
    # different body under that ID. A rescued job allocates a fresh sequence.
    row =
      scope
      |> Map.take(~w(tenant_id group_id connect_id connect_generation workspace_id channel_id))
      |> Map.put("connect_generation", scope["connect_generation"] || "")
      |> Map.merge(
        Map.take(
          source,
          ~w(message_ts_us message_ts thread_ts actor_id actor_kind source_version payload_version message_identity payload_identity)
        )
      )
      |> Map.merge(%{
        "event_date" =>
          source["message_ts_us"]
          |> DateTime.from_unix!(:microsecond)
          |> DateTime.to_date()
          |> Date.to_iso8601(),
        "component" => component,
        "file_id" => file_id,
        "file_epoch" => if(file_id == "", do: 0, else: captured.file_epoch),
        "change_epoch" => captured.change_epoch,
        "build_id" => Ecto.UUID.generate(),
        "build_sequence" => build["build_sequence"],
        "chunks" => Enum.map(units, & &1["text"]),
        "embeddings" => Enum.map(units, & &1["embedding"]),
        "kinds" => Enum.map(units, & &1["content_kind"]),
        "pages" => Enum.map(units, & &1["page"]),
        "starts" => Enum.map(units, & &1["segment_start_ms"]),
        "ends" => Enum.map(units, & &1["segment_end_ms"])
      })

    with :ok <- SlackSemanticIndex.insert_search_component(row),
         do: SlackSearchSources.publish(row)
  end

  defp editable?(file),
    do:
      file["editable"] == true or file["mode"] in ["post", "snippet"] or
        file["mimetype"] == "application/vnd.slack-docs"

  defp valid_scope(scope) do
    if Enum.all?(
         ~w(tenant_id group_id connect_id workspace_id channel_id),
         &(is_binary(scope[&1]) and scope[&1] != "")
       ), do: :ok, else: {:cancel, :search_scope_unavailable}
  end
end
