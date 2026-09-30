defmodule SalixAnalytics.EventArchive.Completeness do
  @moduledoc """
  Gap analysis over the plaintext header columns. **Needs no key.**

  Every item carries a per-stream `seq`, so a reader can state what is missing
  *between two items it can see*.

  ## What this cannot see, stated first

  An earlier revision of this design claimed loss is always detectable and that
  silent loss was eliminated. That claim was false, and it is withdrawn:

    * **Tail loss is invisible.** A run that stored seq 1 while 2 and 3 were
      allocated and lost is byte-identical, from here, to a run whose only item
      was seq 1. Nothing records how far a run got, so the analysis cannot know
      an item was ever expected. Closing this needs a durable per-run high-water
      mark, which does not exist.
    * **Loss before the query window is invisible**, and worse, a run that began
      before the window would otherwise be reported as missing everything up to
      its first in-window seq. That false positive is suppressed (see
      `leading_gap?/2`), at the cost of not reporting a genuine missing head
      when the window happens to start mid-run.
    * **A whole run lost is invisible.** If every item of a `(stream, writer)`
      run failed to land, there is no row to group by and nothing to report.

  What it does prove is narrower and still worth having: **within a run this
  analysis can see, every interior gap is reported exactly.**

  Two distinct findings, deliberately not conflated:

    * a **gap** — the run skips forward, so items were admitted at a boundary
      and never reached storage (a full buffer, a failed insert, a lost node).

    * a **reset** — a stream has more than one writer epoch. Counters are
      per-node ETS, so a node restart or an actor moving between nodes starts a
      new run. That is expected and is NOT loss; reporting it as a gap would
      train readers to ignore the signal.

  ## What the writer epoch changed

  The object-storage version had no writer identity, so it INFERRED a reset from
  a second occurrence of seq 1 and then had to carve out a "restart span" of
  low seqs that were allowed to repeat without being called duplicates. That
  heuristic was wrong in both directions: a stream whose run restarted after a
  genuine duplicate hid the duplicate, and a restart that lost its first items
  (so seq 1 never landed twice) was reported as a plain gap.

  With `writer` on every row, `(stream, writer)` is the run. Gaps are seq breaks
  within a run, a reset is simply more than one run on a stream, and a duplicate
  is a real duplicate. All three are observed rather than guessed, and the
  heuristic is deleted.

  ## Aggregation happens in ClickHouse

  `report/1` sends one aggregate query. It returns one row per `(stream,
  writer)` — item count, min/max seq, distinct seq count, time range — which is
  bounded by the number of runs, not by the number of archived events. The
  previous implementation could only analyze what a reader had already
  downloaded, so "verify the archive" meant "verify the segments I happened to
  fetch". This verifies the whole window.

  `analyze/2` remains available for rows already in hand — tests, and anything
  holding an exported JSONL dump — and produces exactly the same findings.
  """

  alias SalixAnalytics.EventArchive.Sink

  @type finding ::
          %{
            kind: :gap,
            stream: String.t(),
            writer: String.t(),
            after_seq: non_neg_integer(),
            before_seq: pos_integer(),
            missing: pos_integer()
          }
          | %{kind: :reset, stream: String.t(), writers: pos_integer()}
          | %{
              kind: :duplicate,
              stream: String.t(),
              writer: String.t(),
              seq: pos_integer(),
              count: pos_integer()
            }
          | %{
              kind: :unresolved,
              stream: String.t(),
              writer: String.t(),
              missing: non_neg_integer()
            }

  @type report :: %{
          items: non_neg_integer(),
          runs: non_neg_integer(),
          streams: non_neg_integer(),
          findings: [finding()],
          missing_total: non_neg_integer()
        }

  @doc """
  Analyze the archive over a window, aggregating in ClickHouse.

  Options: `:from` and `:to` (ISO dates, inclusive), `:tenant_id`, `:stream`.

  Gaps are derived from the run's span versus its distinct-seq count, so the
  query stays an aggregate: a run of N distinct seqs spanning `min..max` is
  complete exactly when `max - min + 1 == N` and `min == 1`. When a run is
  incomplete the exact missing ranges are fetched for that run alone, which is
  the only place a per-seq read happens.
  """
  @spec report(keyword()) :: {:ok, report()} | {:error, term()}
  def report(opts \\ []) do
    with {:ok, runs} <- run_summaries(opts),
         {:ok, gap_findings} <- gap_details(Enum.filter(runs, &incomplete_run?/1), opts),
         {:ok, dup_findings} <- duplicate_details(Enum.filter(runs, &duplicated_run?/1), opts) do
      findings = gap_findings ++ reset_findings(runs) ++ dup_findings

      {:ok,
       %{
         items: runs |> Enum.map(& &1.items) |> Enum.sum(),
         runs: length(runs),
         streams: runs |> Enum.map(& &1.stream) |> Enum.uniq() |> length(),
         findings: findings,
         missing_total: findings |> Enum.map(&Map.get(&1, :missing, 0)) |> Enum.sum()
       }}
    end
  end

  defp run_summaries(opts) do
    sql = """
    SELECT
      stream,
      writer,
      count() AS items,
      uniqExact(seq) AS distinct_seqs,
      min(seq) AS min_seq,
      max(seq) AS max_seq
    FROM #{Sink.table(opts)} FINAL
    WHERE #{where(opts)}
    GROUP BY stream, writer
    ORDER BY stream, writer
    """

    case Sink.query(sql, opts) do
      {:ok, rows} -> {:ok, Enum.map(rows, &summary/1)}
      {:error, _} = error -> error
    end
  end

  defp summary(row) do
    %{
      stream: row["stream"],
      writer: row["writer"],
      items: integer(row["items"]),
      distinct_seqs: integer(row["distinct_seqs"]),
      min_seq: integer(row["min_seq"]),
      max_seq: integer(row["max_seq"])
    }
  end

  # ClickHouse returns UInt64 as a JSON string to survive the 2^53 barrier, so
  # every count and seq arrives as a binary and must be parsed rather than
  # pattern-matched as an integer.
  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp integer(_), do: 0

  defp incomplete_run?(run) do
    run.min_seq != 1 or run.max_seq - run.min_seq + 1 != run.distinct_seqs
  end

  defp duplicated_run?(run), do: run.items > run.distinct_seqs

  # How many items the AGGREGATE says are missing from a run's interior. Used
  # only as the fallback when the per-seq walk cannot account for them.
  defp aggregate_missing(run) do
    max(run.max_seq - run.min_seq + 1 - run.distinct_seqs, 0)
  end

  # A leading gap is only meaningful when the caller analyzed everything, not a
  # date window that could have cut the run's head off. `analyze/2` operates on
  # rows the caller already holds, so it opts in by default.
  defp leading_gap?(opts), do: Keyword.get(opts, :complete_history?, false)

  # Only for runs the aggregate already proved incomplete. Reads the run's seqs
  # and walks them; bounded by that one run, never by the archive.
  defp gap_details([], _opts), do: {:ok, []}

  defp gap_details(runs, opts) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
      sql = """
      SELECT DISTINCT seq
      FROM #{Sink.table(opts)} FINAL
      WHERE #{where(opts)} AND stream = #{quoted(run.stream)} AND writer = #{quoted(run.writer)}
      ORDER BY seq
      """

      case Sink.query(sql, opts) do
        {:ok, rows} ->
          seqs = Enum.map(rows, &integer(&1["seq"]))
          {:cont, {:ok, acc ++ gaps(run, seqs, opts)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Which seqs actually repeat, rather than a guess. The aggregate can only say
  # HOW MANY extra rows a run holds; it cannot say where they are, and the
  # previous version filled that in with `min_seq` and a count of
  # `items - distinct + 1` — both wrong the moment two different seqs each
  # repeat. Bounded by the number of repeating seqs, which under the dedup key
  # should be zero.
  defp duplicate_details([], _opts), do: {:ok, []}

  defp duplicate_details(runs, opts) do
    Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
      sql = """
      SELECT seq, count() AS copies
      FROM #{Sink.table(opts)} FINAL
      WHERE #{where(opts)} AND stream = #{quoted(run.stream)} AND writer = #{quoted(run.writer)}
      GROUP BY seq
      HAVING copies > 1
      ORDER BY seq
      """

      case Sink.query(sql, opts) do
        {:ok, rows} ->
          found = Enum.map(rows, &duplicate(run, integer(&1["seq"]), integer(&1["copies"])))
          {:cont, {:ok, acc ++ resolved_duplicates(run, found)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp duplicate(run, seq, copies) do
    %{kind: :duplicate, stream: run.stream, writer: run.writer, seq: seq, count: copies}
  end

  # The aggregate proved extra rows exist. If the detail query names none, do
  # NOT report a clean run — say the detail could not be resolved.
  defp resolved_duplicates(run, []) do
    [
      %{
        kind: :unresolved,
        stream: run.stream,
        writer: run.writer,
        missing: 0,
        detail: {:duplicates, run.items - run.distinct_seqs}
      }
    ]
  end

  defp resolved_duplicates(_run, found), do: found

  defp gaps(run, seqs, opts) do
    # A run whose first visible seq is > 1 has either lost its head or simply
    # started before the query window. Those are indistinguishable from here, so
    # the finding is only emitted when the window cannot be the explanation —
    # otherwise every routine windowed query would report a fabricated gap
    # covering the entire earlier life of the stream.
    leading =
      case seqs do
        [first | _] when first > 1 ->
          if leading_gap?(opts), do: [gap(run, 0, first)], else: []

        _ ->
          []
      end

    interior =
      seqs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn [previous, current] ->
        if current == previous + 1, do: [], else: [gap(run, previous, current)]
      end)

    resolved(run, leading ++ interior)
  end

  # The aggregate said this run is incomplete, so the walk must account for it.
  # If it does not — the detail query matched nothing, most plainly because the
  # run's own identifiers did not survive being quoted back into the WHERE
  # clause — reporting an empty finding list would turn a proven gap into a
  # clean bill of health. Say what the aggregate knows instead.
  defp resolved(run, []) do
    case aggregate_missing(run) do
      0 -> []
      missing -> [%{kind: :unresolved, stream: run.stream, writer: run.writer, missing: missing}]
    end
  end

  defp resolved(_run, findings), do: findings

  defp gap(run, after_seq, before_seq) do
    %{
      kind: :gap,
      stream: run.stream,
      writer: run.writer,
      after_seq: after_seq,
      before_seq: before_seq,
      missing: before_seq - after_seq - 1
    }
  end

  defp reset_findings(runs) do
    runs
    |> Enum.group_by(& &1.stream)
    |> Enum.filter(fn {_stream, stream_runs} -> length(stream_runs) > 1 end)
    |> Enum.map(fn {stream, stream_runs} ->
      %{kind: :reset, stream: stream, writers: length(stream_runs)}
    end)
    |> Enum.sort_by(& &1.stream)
  end

  defp where(opts) do
    [
      date_clause(opts),
      opts[:tenant_id] && "tenant_id = #{quoted(opts[:tenant_id])}",
      opts[:stream] && "stream = #{quoted(opts[:stream])}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" AND ")
  end

  defp date_clause(opts) do
    from = opts[:from] || Date.utc_today() |> Date.add(-7) |> Date.to_iso8601()
    to = opts[:to] || Date.utc_today() |> Date.to_iso8601()
    "event_date BETWEEN #{quoted(from)} AND #{quoted(to)}"
  end

  # Every interpolated value reaches the query through here. Identifiers in this
  # table come from outside (a session_id is archived before validation), so
  # they are escaped rather than trusted, and control characters are stripped
  # so a value cannot break the statement apart.
  defp quoted(value) do
    escaped =
      value
      |> to_string()
      |> String.replace(~r/[[:cntrl:]]/, "")
      |> String.replace("\\", "\\\\")
      |> String.replace("'", "\\'")

    "'" <> escaped <> "'"
  end

  @doc """
  Analyze rows already in hand. Same findings as `report/1`.

  Used by tests and by `mix salix.archive.verify --input`; the runtime does not
  call it.
  """
  @spec analyze(Enumerable.t(), keyword()) :: report()
  def analyze(rows, opts \\ []) do
    # The caller handed us the rows, so there is no query window that could
    # have cut a run's head off: a run starting above seq 1 really is missing
    # its head. Pass `complete_history?: false` if the rows are themselves a
    # windowed subset.
    opts = Keyword.put_new(opts, :complete_history?, true)

    runs =
      rows
      |> Enum.group_by(&{&1["stream"] || "unknown", &1["writer"] || ""})
      |> Enum.map(fn {{stream, writer}, run_rows} ->
        seqs = run_rows |> Enum.map(&integer(&1["seq"])) |> Enum.filter(&(&1 > 0))
        distinct = seqs |> Enum.uniq() |> Enum.sort()

        {%{
           stream: stream,
           writer: writer,
           items: length(seqs),
           distinct_seqs: length(distinct),
           min_seq: List.first(distinct) || 0,
           max_seq: List.last(distinct) || 0
         }, distinct}
      end)
      |> Enum.sort_by(fn {run, _} -> {run.stream, run.writer} end)

    gap_findings =
      Enum.flat_map(runs, fn {run, seqs} ->
        if incomplete_run?(run), do: gaps(run, seqs, opts), else: []
      end)

    summaries = Enum.map(runs, &elem(&1, 0))
    findings = gap_findings ++ reset_findings(summaries) ++ duplicates_in_hand(rows, summaries)

    %{
      items: summaries |> Enum.map(& &1.items) |> Enum.sum(),
      runs: length(summaries),
      streams: summaries |> Enum.map(& &1.stream) |> Enum.uniq() |> length(),
      findings: findings,
      missing_total: findings |> Enum.map(&Map.get(&1, :missing, 0)) |> Enum.sum()
    }
  end

  # The in-hand equivalent of `duplicate_details/2`: count copies per
  # (stream, writer, seq) and name each repeat, rather than inferring one from
  # the run totals.
  defp duplicates_in_hand(rows, summaries) do
    by_run = Map.new(summaries, &{{&1.stream, &1.writer}, &1})

    rows
    |> Enum.group_by(fn row ->
      {row["stream"] || "unknown", row["writer"] || "", integer(row["seq"])}
    end)
    |> Enum.filter(fn {{_stream, _writer, seq}, copies} -> seq > 0 and length(copies) > 1 end)
    |> Enum.sort_by(fn {key, _copies} -> key end)
    |> Enum.flat_map(fn {{stream, writer, seq}, copies} ->
      case Map.fetch(by_run, {stream, writer}) do
        {:ok, run} -> [duplicate(run, seq, length(copies))]
        :error -> []
      end
    end)
  end

  @doc "Render a report as human-readable lines."
  @spec format(report()) :: [String.t()]
  def format(report) do
    header = [
      "items: #{report.items}",
      "streams: #{report.streams}",
      "runs (stream x writer): #{report.runs}",
      "missing items: #{report.missing_total}"
    ]

    findings =
      Enum.map(report.findings, fn
        %{kind: :gap} = f ->
          "GAP       #{f.stream} [#{short(f.writer)}]: #{f.missing} item(s) missing between seq #{f.after_seq} and #{f.before_seq}"

        %{kind: :reset} = f ->
          "RESET     #{f.stream}: #{f.writers} writer epochs (expected on node restart, not loss)"

        %{kind: :duplicate} = f ->
          "DUPLICATE #{f.stream} [#{short(f.writer)}]: seq #{f.seq} has #{f.count} rows — unexpected under the dedup key"

        %{kind: :unresolved} = f ->
          "UNRESOLVED #{f.stream} [#{short(f.writer)}]: #{unresolved_detail(f)}, but the per-item query could not locate them"
      end)

    header ++ findings
  end

  defp unresolved_detail(%{detail: {:duplicates, extra}}),
    do: "the aggregate counts #{extra} extra row(s)"

  defp unresolved_detail(%{missing: missing}),
    do: "the aggregate counts #{missing} missing item(s)"

  defp short(""), do: "?"
  defp short(writer), do: String.slice(to_string(writer), 0, 8)
end
