defmodule SalixMeetNative.Codec do
  @moduledoc false

  import Bitwise

  @spec decode(module(), binary()) :: {:ok, struct()} | :error
  def decode(module, raw) when is_binary(raw) do
    with {:ok, body} <- frame_body(raw) do
      case strict_decode(module, body) do
        {:ok, _} = ok ->
          ok

        :error ->
          with {:ok, clean} <- drop_mismatched(module, body), do: strict_decode(module, clean)
      end
    end
  end

  defp strict_decode(module, body) do
    {:ok, module.decode(body)}
  rescue
    _ -> :error
  end

  @spec drop_mismatched(module(), binary()) :: {:ok, binary()} | :error
  def drop_mismatched(module, body) do
    props = module.__message_props__().field_props

    with {:ok, fields} <- fields(body, []) do
      Enum.reduce_while(fields, {:ok, []}, fn {num, wire, value}, {:ok, acc} ->
        case keep(Map.get(props, num), wire, value) do
          :drop -> {:cont, {:ok, acc}}
          {:keep, value} -> {:cont, {:ok, [encode_field(num, wire, value) | acc]}}
          :error -> {:halt, :error}
        end
      end)
      |> then(fn
        {:ok, acc} -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
        :error -> :error
      end)
    end
  end

  defp keep(nil, _wire, value), do: {:keep, value}

  defp keep(%Protobuf.FieldProps{wire_type: expected} = prop, wire, value) do
    cond do
      wire == expected and prop.embedded? and wire == 2 ->
        case drop_mismatched(prop.type, value) do
          {:ok, clean} -> {:keep, clean}
          :error -> :error
        end

      wire == expected ->
        {:keep, value}

      prop.repeated? and wire == 2 and expected in [0, 1, 5] ->
        {:keep, value}

      true ->
        :drop
    end
  end

  defp fields(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp fields(raw, acc) do
    with {:ok, tag, rest} <- varint(raw, 0, 0),
         wire = tag &&& 7,
         num when num > 0 <- tag >>> 3,
         {:ok, value, rest} <- field_value(wire, rest) do
      fields(rest, [{num, wire, value} | acc])
    else
      _ -> :error
    end
  end

  defp field_value(0, raw), do: varint(raw, 0, 0)
  defp field_value(1, <<v::binary-size(8), rest::binary>>), do: {:ok, v, rest}
  defp field_value(5, <<v::binary-size(4), rest::binary>>), do: {:ok, v, rest}

  defp field_value(2, raw) do
    with {:ok, len, rest} <- varint(raw, 0, 0), <<v::binary-size(^len), rest::binary>> <- rest do
      {:ok, v, rest}
    else
      _ -> :error
    end
  end

  defp field_value(_wire, _raw), do: :error

  defp varint(<<1::1, v::7, rest::binary>>, shift, acc) when shift < 63,
    do: varint(rest, shift + 7, acc ||| v <<< shift)

  defp varint(<<0::1, v::7, rest::binary>>, shift, acc), do: {:ok, acc ||| v <<< shift, rest}
  defp varint(_raw, _shift, _acc), do: :error

  defp encode_field(num, 0, value), do: [encode_varint(num <<< 3), encode_varint(value)]

  defp encode_field(num, 2, value),
    do: [encode_varint(num <<< 3 ||| 2), encode_varint(byte_size(value)), value]

  defp encode_field(num, wire, value), do: [encode_varint(num <<< 3 ||| wire), value]

  defp encode_varint(v) when v < 0x80, do: <<v>>
  defp encode_varint(v), do: <<1::1, v &&& 0x7F::7>> <> encode_varint(v >>> 7)

  @spec decode_rpc_response(module(), binary()) :: {:ok, struct()} | :error
  def decode_rpc_response(module, raw) when is_binary(raw) do
    case decode(module, raw) do
      {:ok, _} = ok ->
        ok

      :error ->
        case Base.decode64(String.trim(raw)) do
          {:ok, decoded} -> decode(module, decoded)
          :error -> :error
        end
    end
  end

  @spec encode(struct()) :: binary()
  def encode(message), do: Protobuf.encode(message)

  @spec frame_body(binary()) :: {:ok, binary()} | :error
  def frame_body(<<0x1F, 0x8B, _::binary>> = raw), do: gunzip(raw)
  def frame_body(raw), do: {:ok, raw}

  @spec gunzip(binary()) :: {:ok, binary()} | :error
  def gunzip(<<0x1F, 0x8B, _::binary>> = raw) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      {:ok, z |> inflate_all(raw) |> IO.iodata_to_binary()}
    rescue
      _ -> :error
    catch
      _, _ -> :error
    after
      :zlib.close(z)
    end
  end

  def gunzip(_raw), do: :error

  defp inflate_all(z, raw) do
    case :zlib.safeInflate(z, raw) do
      {:continue, out} -> [out | inflate_all(z, [])]
      {:finished, out} -> out
    end
  end
end
