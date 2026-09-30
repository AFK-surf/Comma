defmodule SalixStore.SlackPrivateToken do
  @moduledoc """
  Closed Slack token contract shared by Triage projection and output fencing.

  A Slack object id is a short, fixed-shape identifier: one of the object-class
  prefix letters, then base-34-ish characters with digits mixed into the encoded
  prefix. Matching "prefix letter + any uppercase run containing a digit"
  swallowed ordinary shouted words with a year in them — `GITHUB2024ACTION`,
  `TEAM2024ROADMAP` — and redacting those out of a frozen context destroys the
  meaning the model is supposed to read.

  The rule here keeps every real id in recall while refusing the long
  word-shaped strings: total length inside Slack's id range, at least two
  digits, and a digit inside the encoded prefix rather than only in a trailing
  year.
  """

  # Object-class prefixes Slack actually mints: (A)pp, (B)ot, (C)hannel,
  # (D)M, (G)roup, (T)eam, (U)ser, (W)orkspace-user.
  @candidate_pattern ~r/\b[ABCDGTUW][A-Z0-9]{7,12}\b/
  @digit_pattern ~r/[0-9]/
  @min_digits 2
  # Slack encodes a counter into the head of the id, so a real id always carries
  # a digit within its first few characters. A word with a trailing year does
  # not.
  @prefix_length 5

  @spec redact(String.t(), String.t()) :: String.t()
  def redact(value, replacement \\ "@provider") when is_binary(value) do
    Regex.replace(@candidate_pattern, value, fn candidate ->
      if slack_id?(candidate), do: replacement, else: candidate
    end)
  end

  @spec fragments(String.t()) :: [String.t()]
  def fragments(value) when is_binary(value) do
    @candidate_pattern
    |> Regex.scan(value, capture: :first)
    |> Enum.map(&hd/1)
    |> Enum.filter(&slack_id?/1)
  end

  @doc "Whether one already-extracted candidate has the shape of a Slack object id."
  @spec slack_id?(String.t()) :: boolean()
  def slack_id?(candidate) when is_binary(candidate) do
    digit_count(candidate) >= @min_digits and
      Regex.match?(@digit_pattern, String.slice(candidate, 0, @prefix_length))
  end

  def slack_id?(_candidate), do: false

  defp digit_count(candidate),
    do: @digit_pattern |> Regex.scan(candidate) |> length()
end
