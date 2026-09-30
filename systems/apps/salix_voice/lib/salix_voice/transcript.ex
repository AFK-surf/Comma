defmodule SalixVoice.Transcript do
  @moduledoc """
  Transcript ledger of one call (docs/messaging-voice.md).

  GPT-Live client delegation carries only a delegation ID and an audio offset,
  so the call rebuilds each Router request from the transcript: caller
  fragments with their session offsets, and agent text. Fragments are joined
  into readable text with a space where neither side has one.

  The ledger is bounded: it keeps the newest `@max_entries` entries. Caller
  fragments not yet handed to a delegation are kept separately until
  `take_caller/2` consumes them.
  """

  @max_entries 400
  @max_pending_caller 400

  defstruct entries: [], count: 0, pending_caller: [], pending_count: 0

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{}

  @doc "Record a caller fragment with its session offset (ms, or nil)."
  def add_caller(%__MODULE__{} = ledger, text, offset_ms) when is_binary(text) do
    fragment = %{role: :caller, text: text, offset_ms: offset_ms}

    pending =
      if ledger.pending_count >= @max_pending_caller,
        do: Enum.drop(ledger.pending_caller, -1),
        else: ledger.pending_caller

    %{
      append(ledger, fragment)
      | pending_caller: [fragment | pending],
        pending_count: min(ledger.pending_count + 1, @max_pending_caller)
    }
  end

  @doc "Record agent (spoken) text."
  def add_agent(%__MODULE__{} = ledger, text) when is_binary(text),
    do: append(ledger, %{role: :agent, text: text, offset_ms: nil})

  @doc """
  Consume caller fragments at or before `offset_ms` (and fragments with no
  offset). Fragments after it stay for the next delegation. Returns the joined
  text and the ledger.
  """
  def take_caller(%__MODULE__{} = ledger, offset_ms) do
    {taken, kept} =
      ledger.pending_caller
      |> Enum.reverse()
      |> Enum.split_with(fn %{offset_ms: offset} ->
        is_nil(offset) or is_nil(offset_ms) or offset <= offset_ms
      end)

    text = taken |> Enum.map(& &1.text) |> join()

    {text, %{ledger | pending_caller: Enum.reverse(kept), pending_count: length(kept)}}
  end

  @doc "The last sentence the agent said, or nil."
  def last_agent_sentence(%__MODULE__{} = ledger) do
    agent_text =
      ledger.entries
      |> Enum.take_while(&(&1.role == :agent))
      |> case do
        [] ->
          ledger.entries
          |> Enum.drop_while(&(&1.role != :agent))
          |> Enum.take_while(&(&1.role == :agent))

        run ->
          run
      end
      |> Enum.reverse()
      |> Enum.map(& &1.text)
      |> join()

    case agent_text |> sentences() |> List.last() do
      nil -> nil
      "" -> nil
      sentence -> sentence
    end
  end

  @doc "Entries oldest first."
  def entries(%__MODULE__{} = ledger), do: Enum.reverse(ledger.entries)

  @doc "Join fragments, adding a space only where neither side has one."
  def join(fragments) do
    Enum.reduce(fragments, "", fn fragment, acc ->
      cond do
        acc == "" -> fragment
        fragment == "" -> acc
        boundary_space?(acc, fragment) -> acc <> fragment
        true -> acc <> " " <> fragment
      end
    end)
    |> String.trim()
  end

  @doc "Split text into sentences at `.`, `!`, `?` (and CJK stops) followed by space or end."
  def sentences(text) when is_binary(text) do
    Regex.split(~r/(?<=[.!?。！？])\s+/u, String.trim(text), trim: true)
  end

  defp boundary_space?(acc, fragment) do
    String.match?(acc, ~r/\s$/u) or String.match?(fragment, ~r/^[\s.,!?;:'")\]}。，！？]/u)
  end

  defp append(ledger, entry) do
    if ledger.count >= @max_entries,
      do: %{ledger | entries: [entry | Enum.drop(ledger.entries, -1)]},
      else: %{ledger | entries: [entry | ledger.entries], count: ledger.count + 1}
  end
end
