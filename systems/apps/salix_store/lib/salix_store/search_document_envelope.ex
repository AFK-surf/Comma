defmodule SalixStore.SearchDocumentEnvelope do
  @moduledoc """
  Application-owned text, query, window, and snippet contract for Comma Task search.

  Canonical text crosses this boundary once. The resulting envelope is the
  only shape accepted by full and incremental projection writers. PostgreSQL
  mirrors `weight_bytes` as a generated column so storage integrity cannot
  drift from this application contract.
  """

  @title_bytes 16_384
  @message_bytes 32_768
  @message_window_bytes 262_144
  @message_slots 64
  @query_min_codepoints 2
  @query_max_codepoints 128
  @snippet_before 48
  @snippet_after 80
  @ellipsis "…"

  @enforce_keys [:kind, :content, :folded_content, :short_grams, :weight_bytes]
  defstruct [:kind, :content, :folded_content, :short_grams, :weight_bytes]

  defmodule Query do
    @moduledoc false

    @enforce_keys [:raw, :folded, :short_grams]
    defstruct [:raw, :folded, :short_grams]
  end

  @type kind :: :title | :message
  @type t :: %__MODULE__{
          kind: kind(),
          content: String.t(),
          folded_content: String.t(),
          short_grams: [String.t()],
          weight_bytes: non_neg_integer()
        }
  @type query :: %Query{raw: String.t(), folded: String.t(), short_grams: [String.t()]}
  @type message_entry :: %{
          id: String.t(),
          seq: pos_integer(),
          created_at: integer() | nil,
          envelope: t()
        }
  @type message_slot :: %{seq: pos_integer(), message: message_entry() | nil}

  @spec max_bytes(kind()) :: pos_integer()
  def max_bytes(:title), do: @title_bytes
  def max_bytes(:message), do: @message_bytes

  @spec message_window_bytes() :: pos_integer()
  def message_window_bytes, do: @message_window_bytes

  @spec message_slots() :: pos_integer()
  def message_slots, do: @message_slots

  @spec build(kind(), term()) :: t()
  def build(kind, value) when kind in [:title, :message] do
    max_bytes = max_bytes(kind)
    content = normalize(value)
    {content, folded_content} = truncate(content, max_bytes)

    %__MODULE__{
      kind: kind,
      content: content,
      folded_content: folded_content,
      short_grams: bigrams(folded_content),
      weight_bytes: max(byte_size(content), byte_size(folded_content))
    }
  end

  @spec valid?(term(), kind() | nil) :: boolean()
  def valid?(envelope, expected_kind \\ nil)

  def valid?(%__MODULE__{kind: kind} = envelope, expected_kind)
      when kind in [:title, :message] do
    (is_nil(expected_kind) or expected_kind == kind) and build(kind, envelope.content) == envelope
  end

  def valid?(_envelope, _expected_kind), do: false

  @spec query(term()) ::
          {:ok, query()} | {:error, :required | :null | :too_short | :too_long | :invalid}
  def query(value) when is_binary(value) do
    raw = String.trim(value)
    raw_codepoints = codepoint_count(raw)

    cond do
      raw == "" ->
        {:error, :required}

      String.contains?(raw, <<0>>) ->
        {:error, :null}

      raw_codepoints < @query_min_codepoints ->
        {:error, :too_short}

      raw_codepoints > @query_max_codepoints ->
        {:error, :too_long}

      true ->
        folded = fold(raw)
        folded_codepoints = codepoint_count(folded)
        short_grams = bigrams(folded)

        cond do
          folded_codepoints < @query_min_codepoints ->
            {:error, :too_short}

          folded_codepoints > @query_max_codepoints ->
            {:error, :too_long}

          short_grams == [] ->
            {:error, :too_short}

          true ->
            {:ok, %Query{raw: raw, folded: folded, short_grams: short_grams}}
        end
    end
  end

  def query(_value), do: {:error, :invalid}

  @spec message_window_start(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def message_window_start(0, 0), do: 0

  def message_window_start(head_seq, tail_seq)
      when is_integer(head_seq) and head_seq > 0 and is_integer(tail_seq) and
             tail_seq >= head_seq,
      do: max(head_seq, tail_seq - @message_slots + 1)

  @spec valid_sequence_range?(term(), term()) :: boolean()
  def valid_sequence_range?(0, 0), do: true

  def valid_sequence_range?(head_seq, tail_seq),
    do:
      is_integer(head_seq) and head_seq > 0 and is_integer(tail_seq) and
        tail_seq >= head_seq

  @spec message_slot(map()) :: {:ok, message_slot()} | {:error, :invalid}
  def message_slot(%{id: id, seq: seq, created_at: created_at, content: content})
      when is_binary(id) and id != "" and is_integer(seq) and seq > 0 and
             (is_nil(created_at) or is_integer(created_at)) and is_binary(content) do
    normalized = normalize(content)
    envelope = build(:message, normalized)

    message =
      if String.trim(normalized) == "" do
        nil
      else
        %{id: id, seq: seq, created_at: created_at, envelope: envelope}
      end

    {:ok, %{seq: seq, message: message}}
  end

  def message_slot(_attrs), do: {:error, :invalid}

  @doc "Select the bounded projection from the canonical latest Message slots."
  @spec message_window([message_slot()], non_neg_integer(), non_neg_integer()) ::
          {:ok, %{messages: [message_entry()], indexed_bytes: non_neg_integer()}}
          | {:error, :invalid}
  def message_window(slots, head_seq, tail_seq) when is_list(slots) do
    if valid_sequence_range?(head_seq, tail_seq) do
      start_seq = message_window_start(head_seq, tail_seq)

      expected_seqs =
        if tail_seq == 0,
          do: [],
          else: Enum.to_list(start_seq..tail_seq)

      select_message_window(slots, expected_seqs)
    else
      {:error, :invalid}
    end
  end

  defp select_message_window(slots, expected_seqs) do
    if valid_slots?(slots) and Enum.map(slots, & &1.seq) == expected_seqs do
      {messages, indexed_bytes} =
        slots
        |> Enum.reverse()
        |> Enum.reduce_while({[], 0}, fn
          %{message: nil}, acc ->
            {:cont, acc}

          %{message: %{envelope: envelope} = message}, {acc, used} ->
            next = used + envelope.weight_bytes

            if next <= @message_window_bytes,
              do: {:cont, {[message | acc], next}},
              else: {:halt, {acc, used}}
        end)

      {:ok, %{messages: messages, indexed_bytes: indexed_bytes}}
    else
      {:error, :invalid}
    end
  end

  @spec valid_message_window?([message_entry()], non_neg_integer(), non_neg_integer()) ::
          boolean()
  def valid_message_window?(messages, head_seq, tail_seq) when is_list(messages) do
    if valid_sequence_range?(head_seq, tail_seq) do
      start_seq = message_window_start(head_seq, tail_seq)
      seqs = Enum.map(messages, & &1.seq)
      ids = Enum.map(messages, & &1.id)

      length(messages) <= @message_slots and
        Enum.all?(messages, &valid_message_entry?/1) and
        seqs == Enum.sort(seqs) and Enum.uniq(seqs) == seqs and
        Enum.uniq(ids) == ids and
        Enum.all?(seqs, &(&1 >= start_seq and &1 <= tail_seq)) and
        Enum.sum(Enum.map(messages, & &1.envelope.weight_bytes)) <= @message_window_bytes
    else
      false
    end
  end

  def valid_message_window?(_messages, _head_seq, _tail_seq), do: false

  @spec valid_message_entry?(term()) :: boolean()
  def valid_message_entry?(%{id: id, seq: seq, created_at: created_at, envelope: envelope}) do
    is_binary(id) and id != "" and is_integer(seq) and seq > 0 and
      (is_nil(created_at) or is_integer(created_at)) and valid?(envelope, :message) and
      String.trim(envelope.content) != ""
  end

  def valid_message_entry?(_message), do: false

  @doc "Render the final public snippet and UTF-16 highlight from stored display text."
  @spec render_match(kind(), String.t(), query()) ::
          {:ok, String.t(), %{String.t() => non_neg_integer()}} | :nomatch
  def render_match(kind, content, %Query{} = query)
      when kind in [:title, :message] and is_binary(content) do
    envelope = build(kind, content)

    if envelope.content == content do
      case kind do
        :title -> full_snippet(envelope, query)
        :message -> contextual_snippet(envelope, query)
      end
    else
      :nomatch
    end
  end

  def render_match(_kind, _content, _query), do: :nomatch

  @spec fold(String.t()) :: String.t()
  def fold(value) when is_binary(value) do
    value
    |> String.graphemes()
    |> Enum.map_join(&fold_grapheme/1)
  end

  @spec fold_grapheme(String.t()) :: String.t()
  def fold_grapheme(grapheme) when is_binary(grapheme) do
    grapheme
    |> String.normalize(:nfkc)
    |> :string.casefold()
    |> IO.iodata_to_binary()
    |> String.normalize(:nfkc)
  end

  @spec bigrams(String.t()) :: [String.t()]
  def bigrams(folded_content) when is_binary(folded_content) do
    folded_content
    |> String.codepoints()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&("b:" <> Enum.join(&1)))
    |> Enum.uniq()
  end

  defp valid_slots?(slots) do
    length(slots) <= @message_slots and
      Enum.all?(slots, fn
        %{seq: seq, message: nil} -> is_integer(seq) and seq > 0
        %{seq: seq, message: %{seq: seq} = message} -> valid_message_entry?(message)
        _other -> false
      end)
  end

  defp normalize(value), do: value |> to_string() |> String.replace(<<0>>, "�")

  defp truncate(content, max_bytes) do
    folded = fold(content)

    if byte_size(content) <= max_bytes and byte_size(folded) <= max_bytes do
      {content, folded}
    else
      original_budget = max(max_bytes - byte_size(@ellipsis), 0)
      folded_ellipsis = fold(@ellipsis)
      folded_budget = max(max_bytes - byte_size(folded_ellipsis), 0)

      {original, folded} =
        take_graphemes(content, original_budget, folded_budget, [], [], 0, 0)

      {original <> @ellipsis, folded <> folded_ellipsis}
    end
  end

  defp take_graphemes(
         _content,
         original_budget,
         folded_budget,
         original,
         folded,
         original_used,
         folded_used
       )
       when original_used >= original_budget or folded_used >= folded_budget,
       do:
         {original |> Enum.reverse() |> IO.iodata_to_binary(),
          folded |> Enum.reverse() |> IO.iodata_to_binary()}

  defp take_graphemes(
         content,
         original_budget,
         folded_budget,
         original,
         folded,
         original_used,
         folded_used
       ) do
    case String.next_grapheme(content) do
      {grapheme, rest} ->
        folded_grapheme = fold_grapheme(grapheme)
        next_original = original_used + byte_size(grapheme)
        next_folded = folded_used + byte_size(folded_grapheme)

        if next_original <= original_budget and next_folded <= folded_budget do
          take_graphemes(
            rest,
            original_budget,
            folded_budget,
            [grapheme | original],
            [folded_grapheme | folded],
            next_original,
            next_folded
          )
        else
          {original |> Enum.reverse() |> IO.iodata_to_binary(),
           folded |> Enum.reverse() |> IO.iodata_to_binary()}
        end

      nil ->
        {original |> Enum.reverse() |> IO.iodata_to_binary(),
         folded |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp full_snippet(envelope, query) do
    with {:ok, byte_start, byte_length} <- original_match(envelope.content, query.folded) do
      range = highlight_range(envelope.content, byte_start, byte_length, 0)
      {:ok, envelope.content, range}
    else
      :nomatch -> :nomatch
    end
  end

  defp contextual_snippet(envelope, query) do
    content = envelope.content

    with {:ok, byte_start, byte_length} <- original_match(content, query.folded),
         graphemes when graphemes != [] <- grapheme_offsets(content),
         start_index when is_integer(start_index) <-
           Enum.find_index(graphemes, fn {_value, _start, finish} -> finish > byte_start end),
         end_index when is_integer(end_index) <-
           graphemes
           |> Enum.with_index()
           |> Enum.reduce(nil, fn {{_value, start, _finish}, index}, last ->
             if start < byte_start + byte_length, do: index, else: last
           end) do
      core_start_index = max(0, start_index - @snippet_before)
      core_end_index = min(length(graphemes) - 1, end_index + @snippet_after)
      {_first, core_start, _first_end} = Enum.at(graphemes, core_start_index)
      {_last, _last_start, core_end} = Enum.at(graphemes, core_end_index)
      core = binary_part(content, core_start, core_end - core_start)
      prefix = if core_start > 0, do: @ellipsis, else: ""
      suffix = if core_end < byte_size(content), do: @ellipsis, else: ""
      contextual = prefix <> core <> suffix

      if byte_size(contextual) <= @message_bytes do
        range = highlight_range(content, byte_start, byte_length, core_start, prefix)
        {:ok, contextual, range}
      else
        # Stored Message text is already bounded. Returning it whole is the
        # only lossless option when adding ellipses would cross the public cap
        # around a very large matched grapheme.
        {:ok, content, highlight_range(content, byte_start, byte_length, 0)}
      end
    else
      _other -> :nomatch
    end
  end

  defp highlight_range(content, byte_start, byte_length, snippet_start, prefix \\ "") do
    before = binary_part(content, snippet_start, byte_start - snippet_start)
    matched = binary_part(content, byte_start, byte_length)
    start = utf16_length(prefix <> before)
    %{"start" => start, "end" => start + utf16_length(matched)}
  end

  defp original_match(content, folded_query) when folded_query != "" do
    {folded_content, spans} = fold_with_spans(content)

    case :binary.match(folded_content, folded_query) do
      {folded_start, folded_length} ->
        folded_end = folded_start + folded_length

        spans
        |> Enum.filter(fn {_original_start, _original_end, span_start, span_end} ->
          span_end > folded_start and span_start < folded_end
        end)
        |> case do
          [] ->
            :nomatch

          matching ->
            {original_start, _first_end, _folded_start, _folded_end} = hd(matching)
            {_last_start, original_end, _folded_start, _folded_end} = List.last(matching)
            {:ok, original_start, original_end - original_start}
        end

      :nomatch ->
        :nomatch
    end
  end

  defp fold_with_spans(content), do: fold_with_spans(content, 0, 0, [], [])

  defp fold_with_spans("", _original_offset, _folded_offset, folded, spans) do
    {folded |> Enum.reverse() |> IO.iodata_to_binary(), Enum.reverse(spans)}
  end

  defp fold_with_spans(content, original_offset, folded_offset, folded, spans) do
    {grapheme, rest} = String.next_grapheme(content)
    folded_grapheme = fold_grapheme(grapheme)
    original_end = original_offset + byte_size(grapheme)
    folded_end = folded_offset + byte_size(folded_grapheme)

    fold_with_spans(
      rest,
      original_end,
      folded_end,
      [folded_grapheme | folded],
      [{original_offset, original_end, folded_offset, folded_end} | spans]
    )
  end

  defp grapheme_offsets(content), do: grapheme_offsets(content, 0, [])
  defp grapheme_offsets("", _offset, acc), do: Enum.reverse(acc)

  defp grapheme_offsets(content, offset, acc) do
    {grapheme, rest} = String.next_grapheme(content)
    finish = offset + byte_size(grapheme)
    grapheme_offsets(rest, finish, [{grapheme, offset, finish} | acc])
  end

  defp utf16_length(value) do
    value
    |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
    |> byte_size()
    |> div(2)
  end

  defp codepoint_count(value), do: value |> String.codepoints() |> length()
end
