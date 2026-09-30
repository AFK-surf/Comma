defmodule SalixAgent.Utf8 do
  @moduledoc """
  UTF-8 validation and scrubbing for transcript-bound text.

  Session journals, skill catalogs, and provider request bodies all promise
  JSON-encodable text, but two seams let invalid bytes slip through
  unvalidated: ETF snapshots (`:erlang.term_to_binary/1` round-trips any
  binary) and `Jason.decode/1` (which does not validate UTF-8 inside decoded
  strings). A single invalid byte committed into durable session state — a
  compaction summary, a refreshed system-prompt snapshot carrying a
  byte-truncated skill description — then made every later `Jason.encode!/1`
  of an LLM request raise `Jason.EncodeError`, permanently wedging the
  session.

  `scrub/1` replaces each invalid byte with U+FFFD, returning valid input
  unchanged (same binary, no copy). `scrub_term/1` walks a JSON-shaped term
  and scrubs every binary in it, so a whole event or request body can be
  guaranteed encodable in one call.
  """

  @replacement <<0xFFFD::utf8>>

  @doc "True when the binary is valid UTF-8."
  @spec valid?(binary()) :: boolean()
  def valid?(bin) when is_binary(bin), do: String.valid?(bin)

  @doc "Replace each invalid byte with U+FFFD; valid input is returned as-is."
  @spec scrub(binary()) :: String.t()
  def scrub(bin) when is_binary(bin) do
    if String.valid?(bin), do: bin, else: do_scrub(bin, <<>>)
  end

  defp do_scrub(<<cp::utf8, rest::binary>>, acc), do: do_scrub(rest, <<acc::binary, cp::utf8>>)
  defp do_scrub(<<_bad, rest::binary>>, acc), do: do_scrub(rest, acc <> @replacement)
  defp do_scrub(<<>>, acc), do: acc

  @doc """
  Deep-scrub every binary in a JSON-shaped term (maps, lists, strings).

  Structs and non-binary leaves pass through untouched; a term containing
  only valid text comes back equal to the input.
  """
  @spec scrub_term(term()) :: term()
  def scrub_term(bin) when is_binary(bin), do: scrub(bin)
  def scrub_term(%_{} = struct), do: struct

  def scrub_term(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {scrub_term(key), scrub_term(value)} end)

  def scrub_term(list) when is_list(list), do: Enum.map(list, &scrub_term/1)
  def scrub_term(other), do: other

  @doc """
  Repair Session input before admission, including MapSet members and tuple fields.

  The kernel can turn these containers into plain maps. Repair their text before
  the kernel compares identities. Other structs remain subject to Session schema checks.
  """
  @spec scrub_session_input(term()) :: term()
  def scrub_session_input(%MapSet{} = set), do: MapSet.new(set, &scrub_session_input/1)
  def scrub_session_input(%_{} = struct), do: struct

  def scrub_session_input(map) when is_map(map),
    do:
      Map.new(map, fn {key, value} -> {scrub_session_input(key), scrub_session_input(value)} end)

  def scrub_session_input(list) when is_list(list), do: Enum.map(list, &scrub_session_input/1)

  def scrub_session_input(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&scrub_session_input/1) |> List.to_tuple()

  def scrub_session_input(other), do: scrub_term(other)
end
