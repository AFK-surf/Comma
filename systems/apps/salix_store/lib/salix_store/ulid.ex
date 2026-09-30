defmodule SalixStore.ULID do
  @moduledoc false

  import Bitwise

  @alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @valid ~r/^[0-7][0-9A-HJKMNP-TV-Z]{25}$/
  @max (1 <<< 128) - 1

  def generate(after_id \\ nil) do
    candidate =
      <<System.system_time(:millisecond)::unsigned-big-48, :crypto.strong_rand_bytes(10)::binary>>
      |> :binary.decode_unsigned()

    value =
      case decode(after_id) do
        {:ok, previous} -> max(candidate, previous + 1)
        :error -> candidate
      end

    if value > @max, do: raise("ULID space exhausted"), else: encode(value)
  end

  @doc "Derives a stable ULID-shaped fence from a domain-separated list of binaries."
  def derive(domain, parts)
      when is_binary(domain) and domain != "" and is_list(parts) and parts != [] do
    if Enum.all?(parts, &(is_binary(&1) and &1 != "")) do
      payload =
        [domain | parts]
        |> Enum.map(fn part -> <<byte_size(part)::unsigned-big-32, part::binary>> end)
        |> IO.iodata_to_binary()

      <<value::unsigned-big-128, _rest::binary>> = :crypto.hash(:sha256, payload)
      encode(value)
    else
      raise ArgumentError, "ULID derivation parts must be non-empty binaries"
    end
  end

  def derive(_domain, _parts),
    do: raise(ArgumentError, "ULID derivation requires a domain and non-empty binary parts")

  def valid?(value) when is_binary(value), do: Regex.match?(@valid, value)
  def valid?(_value), do: false

  defp encode(value) do
    value
    |> do_encode([])
    |> List.to_string()
    |> String.pad_leading(26, "0")
  end

  defp do_encode(0, []), do: [String.at(@alphabet, 0)]
  defp do_encode(0, chars), do: chars

  defp do_encode(value, chars) do
    do_encode(value >>> 5, [String.at(@alphabet, value &&& 31) | chars])
  end

  defp decode(value) when is_binary(value) do
    if valid?(value) do
      value
      |> String.to_charlist()
      |> Enum.reduce_while({:ok, 0}, fn char, {:ok, acc} ->
        case :binary.match(@alphabet, <<char>>) do
          {index, 1} -> {:cont, {:ok, (acc <<< 5) + index}}
          :nomatch -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp decode(_value), do: :error
end
