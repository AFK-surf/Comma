defmodule SalixStore.Age.Bech32 do
  @moduledoc """
  Bech32 (BIP-173) encoding, as used by age for `age1…` recipients and
  `AGE-SECRET-KEY-1…` identities.

  This is not general-purpose Bech32: it exists so operators can paste the
  exact string `age-keygen` prints into config, and so a mistyped or truncated
  key is rejected by the checksum instead of silently producing an archive
  nobody holds the key for. That check is the reason this module exists rather
  than a raw base64 recipient field.

  Note age uses Bech32, NOT Bech32m — the final checksum constant is 1.
  """

  @charset ~c"qpzry9x8gf2tvdw0s3jn54khce6mua7l"
  @generator [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]

  @doc """
  Decode a Bech32 string into `{:ok, hrp, data}` where `data` is the decoded
  8-bit payload. The HRP is returned lowercased.
  """
  @spec decode(String.t()) :: {:ok, String.t(), binary()} | {:error, atom()}
  def decode(string) when is_binary(string) do
    with :ok <- validate_length(string),
         :ok <- validate_case(string),
         normalized = String.downcase(string),
         {:ok, hrp, data5} <- split(normalized),
         :ok <- verify_checksum(hrp, data5),
         payload5 = Enum.drop(data5, -6),
         {:ok, bytes} <- convert_bits(payload5, 5, 8, false) do
      {:ok, hrp, :binary.list_to_bin(bytes)}
    end
  end

  @doc "Encode `data` under `hrp`. The result is lowercase."
  @spec encode(String.t(), binary()) :: {:ok, String.t()} | {:error, atom()}
  def encode(hrp, data) when is_binary(hrp) and is_binary(data) do
    hrp = String.downcase(hrp)

    with {:ok, data5} <- convert_bits(:binary.bin_to_list(data), 8, 5, true) do
      checksum = create_checksum(hrp, data5)
      body = Enum.map_join(data5 ++ checksum, "", &<<Enum.at(@charset, &1)>>)
      {:ok, hrp <> "1" <> body}
    end
  end

  # BIP-173 caps the whole string at 90 characters.
  defp validate_length(string) when byte_size(string) <= 90, do: :ok
  defp validate_length(_string), do: {:error, :too_long}

  # BIP-173 restricts HRP bytes to US-ASCII 33..126.
  defp validate_hrp(hrp) do
    if hrp != "" and Enum.all?(:binary.bin_to_list(hrp), &(&1 >= 33 and &1 <= 126)),
      do: :ok,
      else: {:error, :invalid_hrp}
  end

  # Bech32 is case-insensitive, and mixed case is invalid so two spellings
  # cannot check out as the same key. Note `String.downcase/1` is Unicode-aware
  # (U+212A KELVIN folds to ASCII "k"), which real age shares — the ASCII-only
  # HRP check above is what keeps that confined to the data part.
  defp validate_case(string) do
    cond do
      string == String.downcase(string) -> :ok
      string == String.upcase(string) -> :ok
      true -> {:error, :mixed_case}
    end
  end

  defp split(string) do
    case :binary.matches(string, "1") do
      [] ->
        {:error, :missing_separator}

      matches ->
        {pos, _} = List.last(matches)
        hrp = binary_part(string, 0, pos)
        body = binary_part(string, pos + 1, byte_size(string) - pos - 1)

        cond do
          hrp == "" -> {:error, :empty_hrp}
          byte_size(body) < 6 -> {:error, :too_short}
          validate_hrp(hrp) != :ok -> {:error, :invalid_hrp}
          true -> decode_body(hrp, body)
        end
    end
  end

  defp decode_body(hrp, body) do
    body
    |> :binary.bin_to_list()
    |> Enum.reduce_while({:ok, []}, fn char, {:ok, acc} ->
      case Enum.find_index(@charset, &(&1 == char)) do
        nil -> {:halt, {:error, :invalid_character}}
        index -> {:cont, {:ok, [index | acc]}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, hrp, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp verify_checksum(hrp, data5) do
    if polymod(hrp_expand(hrp) ++ data5) == 1, do: :ok, else: {:error, :bad_checksum}
  end

  defp create_checksum(hrp, data5) do
    values = hrp_expand(hrp) ++ data5 ++ [0, 0, 0, 0, 0, 0]
    mod = Bitwise.bxor(polymod(values), 1)
    for i <- 0..5, do: Bitwise.band(Bitwise.bsr(mod, 5 * (5 - i)), 31)
  end

  defp hrp_expand(hrp) do
    chars = :binary.bin_to_list(hrp)
    Enum.map(chars, &Bitwise.bsr(&1, 5)) ++ [0] ++ Enum.map(chars, &Bitwise.band(&1, 31))
  end

  defp polymod(values) do
    Enum.reduce(values, 1, fn value, chk ->
      top = Bitwise.bsr(chk, 25)
      chk = Bitwise.bxor(Bitwise.bsl(Bitwise.band(chk, 0x1FFFFFF), 5), value)

      Enum.reduce(0..4, chk, fn i, acc ->
        if Bitwise.band(Bitwise.bsr(top, i), 1) == 1 do
          Bitwise.bxor(acc, Enum.at(@generator, i))
        else
          acc
        end
      end)
    end)
  end

  # Regroup a list of `from`-bit values into `to`-bit values. When padding,
  # a trailing partial group is zero-extended; when not, any non-zero
  # remainder is an encoding error rather than something to silently drop.
  defp convert_bits(values, from, to, pad) do
    max = Bitwise.bsl(1, to) - 1

    {acc, bits, out} =
      Enum.reduce(values, {0, 0, []}, fn value, {acc, bits, out} ->
        acc = Bitwise.bor(Bitwise.bsl(acc, from), value)
        bits = bits + from
        emit(acc, bits, to, max, out)
      end)

    cond do
      pad and bits > 0 ->
        last = Bitwise.band(Bitwise.bsl(acc, to - bits), max)
        {:ok, Enum.reverse([last | out])}

      not pad and (bits >= from or Bitwise.band(Bitwise.bsl(acc, to - bits), max) != 0) ->
        {:error, :invalid_padding}

      true ->
        {:ok, Enum.reverse(out)}
    end
  end

  defp emit(acc, bits, to, max, out) when bits >= to do
    bits = bits - to
    value = Bitwise.band(Bitwise.bsr(acc, bits), max)
    emit(acc, bits, to, max, [value | out])
  end

  defp emit(acc, bits, _to, _max, out), do: {acc, bits, out}
end
