defmodule SalixAgent.SessionHistory.Episodes do
  @moduledoc """
  Compaction summaries kept as Session history.

  Each compaction replaces the summary in model context. The summary commit
  also appends one `compaction_summary` Session fact with a redacted copy.
  The fact never enters model context. `history.list` and `history.get` replay
  every summary by seq; `history.search` lists summaries that a later
  compaction replaced as episodes.

  The fact carries the join of the labels of what the summary covers: the
  compacted messages and the previous summary. Content with no label, and a
  previous summary with no fact, count as agent-private.
  """

  alias SalixAgent.IFC.{Context, FileLabels}
  alias SalixAgent.InternalSession
  alias SalixIFC.{Codec, Label}

  @kind "compaction_summary"
  @recovery_marker "System recovery summary:"
  @redacted "[redacted]"
  @limit 3
  @scan 32
  @snippet 400
  @context 120

  def kind, do: @kind

  @doc """
  The fact to commit with a compaction's events over `state`: none when the
  events hold no model-written summary (a provider compaction or a recovery
  summary).
  """
  def facts(events, state, created_at) when is_list(events) do
    case Enum.find(events, &summary_event?/1) do
      %{"summary" => summary} = event ->
        [
          %{
            "type" => "session_event",
            "session_id" => event["session_id"],
            "event_id" => "#{@kind}:#{event["summary_sequence"]}:#{event["compacted_through"]}",
            "kind" => @kind,
            "source" => "compaction",
            "event" => %{
              "summary" => redact(unwrap(summary)),
              "compacted_through" => event["compacted_through"],
              "summary_sequence" => event["summary_sequence"],
              "label" => summary_label(state, event["compacted_through"])
            },
            "created_at" => created_at
          }
        ]

      nil ->
        []
    end
  end

  # The join of the compacted messages' labels and the previous summary's.
  defp summary_label(state, through) do
    through = if is_integer(through), do: through, else: 0

    messages =
      (InternalSession.get(state, :messages) || [])
      |> Enum.filter(&(field(&1, :role) != "event" and (field(&1, :id) || 0) <= through))
      |> Enum.map(&message_label/1)

    (messages ++ previous_label(state))
    |> Label.join_all()
    |> Codec.encode_label()
  end

  # The record's own IFC block, else the one sealed onto its trusted origin
  # (the same order as the kernel's provenance query).
  defp message_label(message) do
    origin = field(message, :trusted_origin)

    block =
      Enum.find([field(message, :ifc), is_map(origin) && field(origin, :ifc)], &is_map/1)

    raw = if block, do: field(block, :label)
    Codec.decode_label(raw, Context.private())
  end

  defp previous_label(state) do
    summary = InternalSession.get(state, :summary)
    provider = InternalSession.get(state, :provider_compaction)

    if (is_binary(summary) and String.trim(summary) != "") or
         (is_map(provider) and map_size(provider) > 0) do
      # Only the fact of the summary now in context counts: a provider or
      # recovery compaction since then wrote none, and fails closed.
      sequence = InternalSession.get(state, :summary_sequence)

      previous =
        (InternalSession.get(state, :events) || [])
        |> Enum.reverse()
        |> Enum.find(
          &(is_map(&1) and &1["kind"] == @kind and
              get_in(&1, ["event", "summary_sequence"]) == sequence)
        )

      case previous do
        nil -> [Context.private()]
        fact -> [Codec.decode_label(get_in(fact, ["event", "label"]), Context.private())]
      end
    else
      []
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  @doc "The encoded label a summary fact record carries, or nil."
  def label(%{data: data}) when is_map(data) do
    case get_in(data, ["event", "label"]) do
      [_ | _] = label -> label
      _ -> nil
    end
  end

  def label(_record), do: nil

  defp summary_event?(%{"type" => "compaction", "summary" => summary}) when is_binary(summary),
    do: not String.contains?(summary, @recovery_marker)

  defp summary_event?(_event), do: false

  defp unwrap(summary) do
    summary
    |> String.replace("<compacted-context>", "")
    |> String.replace("</compacted-context>", "")
    |> String.trim()
  end

  # Values that look like credentials. Summaries quote tool output, so an API
  # key or token can reach them; the fact keeps the surrounding text.
  @patterns [
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/s,
    ~r/\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{20,}/,
    ~r/\bxox[abprs]-[A-Za-z0-9-]{10,}/,
    ~r/\bglpat-[A-Za-z0-9_-]{16,}/,
    ~r/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/,
    # A Telegram bot token: bot id, colon, secret.
    ~r/\b\d{8,10}:[A-Za-z0-9_-]{35}\b/,
    ~r/\bAIza[0-9A-Za-z_-]{35}\b/,
    ~r/\b[a-z]{2,8}_sk_[A-Za-z0-9]{16,}/,
    ~r/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
    ~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/-]{16,}=*/,
    # A 32-character hex value: API hashes and MD5-style secrets.
    ~r/(?<![0-9A-Fa-f])[0-9a-f]{32}(?![0-9A-Fa-f])/
  ]

  # A credential name assigned a value: the separator must hold `:`, `=` or
  # `：`, so prose such as "token validation" stays. A value that is a path
  # (`/...` or `~/...`) stays too: summaries keep file paths.
  @named ~r/(?i)\b((?:api[_ -]?(?:key|hash|secret)|secret|token|password|passwd|passphrase|session[_ -]?string|client[_ -]?secret|private[_ -]?key|access[_ -]?key)s?)([`'"*\s]{0,4}[:=：][ \t]*[`'"]?)(?![\/~])([A-Za-z0-9_\-+\/=.]{7,}[A-Za-z0-9_\-+\/=])/u

  def redact(text) when is_binary(text) do
    text = Regex.replace(@named, text, fn _all, name, sep, _value -> name <> sep <> @redacted end)
    Enum.reduce(@patterns, text, fn pattern, acc -> Regex.replace(pattern, acc, @redacted) end)
  end

  @doc "The searchable text of a summary fact record, or nil for any other record."
  def text(%{kind: "fact", data: %{"kind" => @kind, "event" => %{"summary" => summary}}})
      when is_binary(summary),
      do: summary

  def text(_record), do: nil

  @doc "How many summary index rows a search reads before ranking."
  def scan_limit, do: @scan

  @doc """
  Ranks summary rows for folded search terms. The rows of one summary (its
  index parts) count together: summaries matching more distinct terms first,
  then more occurrences, then newer. One hit per summary, with the joined
  label of its rows.
  """
  def rank(rows, terms) do
    rows
    |> Enum.uniq_by(&{&1["seq"], &1["part"]})
    |> Enum.group_by(& &1["seq"])
    |> Enum.map(fn {seq, parts} -> score(seq, Enum.sort_by(parts, & &1["part"]), terms) end)
    |> Enum.filter(fn {matched, _count, _seq, _best, _label} -> matched > 0 end)
    |> Enum.sort_by(fn {matched, count, seq, _best, _label} -> {-matched, -count, -seq} end)
    |> Enum.take(@limit)
    |> Enum.map(fn {matched, _count, seq, best, label} ->
      %{
        "seq" => seq,
        "matched_terms" => matched,
        "snippet" => snippet(best["text"], terms),
        "label" => label
      }
    end)
  end

  defp score(seq, parts, terms) do
    scored = Enum.map(parts, fn row -> {Enum.map(terms, &occurrences(row["text"], &1)), row} end)

    matched =
      terms
      |> Enum.with_index()
      |> Enum.count(fn {_term, i} -> Enum.any?(scored, fn {c, _} -> Enum.at(c, i) > 0 end) end)

    count = scored |> Enum.map(fn {c, _} -> Enum.sum(c) end) |> Enum.sum()

    {_, best} =
      Enum.min_by(scored, fn {c, row} ->
        {-Enum.count(c, &(&1 > 0)), -Enum.sum(c), row["part"]}
      end)

    label =
      parts
      |> Enum.map(&(&1["label"] || Codec.encode_label(Context.private())))
      |> Enum.reduce(&FileLabels.join_encoded(&2, &1))

    {matched, count, seq, best, label}
  end

  defp occurrences(text, term), do: length(:binary.matches(text, term))

  # The line with the most distinct terms (then most occurrences, then the
  # first), whole when it fits, with bounded context around it.
  defp snippet(text, terms) do
    lines = String.split(text, "\n")

    {line, index} =
      lines
      |> Enum.with_index()
      |> Enum.max_by(fn {line, i} ->
        counts = Enum.map(terms, &occurrences(line, &1))
        {Enum.count(counts, &(&1 > 0)), Enum.sum(counts), -i}
      end)

    if String.length(line) >= @snippet do
      pos = first_hit(line, terms)
      String.slice(line, max(0, pos - 80), @snippet)
    else
      room = min(@context, @snippet - String.length(line) - 1)

      before =
        case index > 0 and room > 0 and Enum.at(lines, index - 1) do
          previous when is_binary(previous) ->
            length = String.length(previous)
            [String.slice(previous, max(length - room, 0), room)]

          _ ->
            []
        end

      (before ++ [line] ++ Enum.slice(lines, index + 1, 1))
      |> Enum.join("\n")
      |> String.slice(0, @snippet)
    end
  end

  defp first_hit(line, terms) do
    terms
    |> Enum.flat_map(fn term ->
      case :binary.match(line, term) do
        {byte, _} -> [byte]
        :nomatch -> []
      end
    end)
    |> Enum.min(fn -> 0 end)
    |> then(&(binary_part(line, 0, &1) |> String.length()))
  end
end
