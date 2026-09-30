defmodule SalixAnalytics.SlackSemanticIndexer do
  @moduledoc """
  Bounded canonical reconciliation into Oban plus complete-document indexing.
  One timer pages one exact scope per turn; no message path calls this process.
  Text and file jobs execute independently and history yields to live work.
  Model: tla/salix/SlackSemanticIndex.tla.
  Scheduling: tla/salix/SemanticIndexScheduling.tla.
  Full-history paging: tla/salix/SemanticHistoryPaging.tla.
  """
  alias SalixAnalytics.SlackSemanticIndex, as: Index
  alias SalixAnalytics.SlackSemanticQueue, as: Queue
  use GenServer
  @window_us 14 * 86_400 * 1_000_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :tick, Keyword.get(opts, :start_delay_ms, 1000))
    {:ok, %{discovery: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    source = Application.get_env(:salix_analytics, :slack_semantic_scope_source)
    latest = System.os_time(:microsecond)
    started = System.monotonic_time()

    result =
      try do
        with {:ok, scope, discovery} <- source.next(state.discovery) do
          if scope do
            with {:ok, cursor} <- Queue.history_cursor(scope),
                 {:ok, rows} <-
                   Index.message_page(scope, if(cursor == 0, do: latest, else: cursor)),
                 {:ok, _} <- Queue.enqueue_history_page(scope, cursor, rows) do
              {:ok, discovery}
            else
              _ -> {:skip, discovery}
            end
          else
            {:ok, discovery}
          end
        end
      rescue
        _ -> {:error, :semantic_unavailable}
      catch
        _, _ -> {:error, :semantic_unavailable}
      end

    Index.observe(
      "slack_semantic_reconcile",
      started,
      if(match?({:ok, _}, result), do: "ok", else: "error")
    )

    discovery =
      case result do
        {status, next} when status in [:ok, :skip] -> next
        _ -> state.discovery
      end

    Process.send_after(self(), :tick, if(match?({:ok, _}, result), do: 1000, else: 5000))
    {:noreply, %{state | discovery: discovery}}
  end

  @doc false
  def index_message(scope, timestamp, opts \\ []) do
    with {:ok, rows} <- Index.missing_documents(scope, timestamp, timestamp + 1) do
      Enum.reduce_while(rows, :ok, fn row, _ ->
        parts = chunks(row["source_text"])

        with {:ok, vectors} <-
               encode(parts, System.monotonic_time(:millisecond) + 220_000, 0, opts),
             :ok <- publish(row, parts, vectors) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  def index_file(scope, timestamp, file_id, opts \\ []) do
    source = Application.get_env(:salix_analytics, :slack_semantic_file_source)

    if is_nil(source) or is_nil(scope["group_id"]) or is_nil(scope["connect_id"]) do
      {:cancel, :attachment_source_unconfigured}
    else
      with {:ok, rows} <- Index.missing_files(scope, timestamp, timestamp + 1, file_id) do
        Enum.reduce_while(rows, :ok, fn row, _ ->
          with {:ok, units} <- source.extract(scope, file_id, &Index.media(&1, &2, opts), opts),
               :ok <- publish_file(row, units) do
            {:cont, :ok}
          else
            error -> {:halt, error}
          end
        end)
      end
    end
  end

  @doc false
  def run(scopes, opts \\ []) do
    if not valid_scopes?(scopes), do: raise(ArgumentError, "require one to eight exact scopes")
    latest = Keyword.get(opts, :latest, System.os_time(:microsecond))
    deadline = Keyword.get(opts, :deadline, System.monotonic_time(:millisecond) + 220_000)

    report = %{
      documents: 0,
      chunks: 0,
      files: 0,
      media_units: 0,
      scopes: 0,
      outcome: "complete_pass"
    }

    Enum.reduce_while(scopes, {:ok, report}, fn scope, {:ok, report} ->
      if expired?(deadline) do
        {:halt, {:ok, %{report | outcome: "budget_exhausted"}}}
      else
        with {:ok, rows} <- Index.missing_documents(scope, latest - @window_us, latest),
             {:ok, report} <-
               index_rows(rows, %{report | scopes: report.scopes + 1}, deadline, opts),
             {:ok, file_report} <- index_files(scope, latest, opts) do
          report = %{
            report
            | files: report.files + file_report.files,
              media_units: report.media_units + file_report.media_units
          }

          if report.outcome == "budget_exhausted",
            do: {:halt, {:ok, report}},
            else: {:cont, {:ok, report}}
        else
          error -> {:halt, error}
        end
      end
    end)
  end

  defp index_files(scope, latest, opts) do
    # A configured exact connect is needed only for attachment acquisition.
    # Download/upload and extraction have separate finite budgets; only this
    # process awaits them. No mainline caller communicates with this mailbox.
    source =
      Keyword.get(
        opts,
        :file_source,
        Application.get_env(:salix_analytics, :slack_semantic_file_source)
      )

    if is_nil(source) or is_nil(scope["group_id"]) or is_nil(scope["connect_id"]) do
      {:ok, %{files: 0, media_units: 0}}
    else
      with {:ok, rows} <- Index.missing_files(scope, latest - @window_us, latest) do
        Enum.reduce_while(rows, {:ok, %{files: 0, media_units: 0}}, fn row, {:ok, report} ->
          with {:ok, units} <- source.extract(scope, row["file_id"], &Index.media/2),
               :ok <- publish_file(row, units) do
            {:cont,
             {:ok, %{files: report.files + 1, media_units: report.media_units + length(units)}}}
          else
            error -> {:halt, error}
          end
        end)
      end
    end
  end

  defp publish_file(row, units) do
    date =
      row["message_ts_us"]
      |> DateTime.from_unix!(:microsecond)
      |> DateTime.to_date()
      |> Date.to_iso8601()

    row
    |> Map.take(
      ~w(tenant_id workspace_id channel_id message_ts_us source_version payload_version source_files file_id)
    )
    |> Map.merge(%{
      "event_date" => date,
      "chunks" => Enum.map(units, & &1["text"]),
      "kinds" => Enum.map(units, & &1["content_kind"]),
      "pages" => Enum.map(units, & &1["page"]),
      "starts" => Enum.map(units, & &1["segment_start_ms"]),
      "ends" => Enum.map(units, & &1["segment_end_ms"]),
      "embeddings" => Enum.map(units, & &1["embedding"])
    })
    |> Index.insert(:files)
  end

  defp index_rows(rows, report, deadline, opts) do
    Enum.reduce_while(rows, {:ok, report}, fn row, {:ok, report} ->
      parts = chunks(row["source_text"])

      if report.documents >= 64 or report.chunks + length(parts) > 128 or expired?(deadline) do
        {:halt, {:ok, %{report | outcome: "budget_exhausted"}}}
      else
        with {:ok, vectors} <- encode(parts, deadline, Keyword.get(opts, :pace_ms, 0), opts),
             :ok <- publish(row, parts, vectors) do
          {:cont,
           {:ok,
            %{report | documents: report.documents + 1, chunks: report.chunks + length(parts)}}}
        else
          {:error, :deadline} -> {:halt, {:ok, %{report | outcome: "budget_exhausted"}}}
          error -> {:halt, error}
        end
      end
    end)
  end

  # At most 23 chunks, 400 Unicode codepoints each, 40 overlap. Even four
  # byte tokens per codepoint leave headroom under the origin's token ceiling.
  @doc false
  def chunks(text) when is_binary(text) do
    points = String.codepoints(text)
    if length(points) > 8000, do: raise(ArgumentError, "source text exceeds bound")
    points |> Enum.chunk_every(400, 360, []) |> Enum.map(&Enum.join/1)
  end

  defp encode(parts, deadline, pace, opts) do
    cancelled = Keyword.get(opts, :cancelled, fn -> false end)

    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, vectors} ->
      cond do
        cancelled.() ->
          {:halt, {:error, :preempted}}

        expired?(deadline) ->
          {:halt, {:error, :deadline}}

        true ->
          case Index.embed(part, background: true, live: Keyword.get(opts, :live, false)) do
            {:ok, vector} ->
              Process.sleep(pace)
              {:cont, {:ok, [vector | vectors]}}

            error ->
              {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, vectors} -> {:ok, Enum.reverse(vectors)}
      error -> error
    end
  end

  defp publish(row, parts, vectors) do
    date =
      row["message_ts_us"]
      |> DateTime.from_unix!(:microsecond)
      |> DateTime.to_date()
      |> Date.to_iso8601()

    row
    |> Map.take(
      ~w(tenant_id workspace_id channel_id message_ts_us source_version payload_version source_text)
    )
    |> Map.merge(%{"event_date" => date, "chunks" => parts, "embeddings" => vectors})
    |> Index.insert()
  end

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp valid_scopes?(scopes) when is_list(scopes) and length(scopes) in 1..8 do
    Enum.all?(scopes, fn scope ->
      is_map(scope) and Enum.all?(~w(channel_id tenant_id workspace_id), &Map.has_key?(scope, &1)) and
        Map.keys(scope) -- ~w(channel_id tenant_id workspace_id group_id connect_id) == [] and
        Enum.all?(Map.values(scope), &(is_binary(&1) and byte_size(&1) in 1..128))
    end)
  end

  defp valid_scopes?(_), do: false
end
