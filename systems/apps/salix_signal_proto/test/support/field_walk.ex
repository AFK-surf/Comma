defmodule SalixSignalProto.Test.FieldWalk do
  @moduledoc false
  # Compares a decoded protobuf struct with a CRS field list of the form
  # [%{"field" => n, "type" => "varint" | "bytes" | "string" | "message",
  # "value" => ...}] (vectors/CRS-05/*-encoding.json). The field numbers are
  # looked up in the Comma schema, so a mismatch shows a wrong field number or
  # type in the schema. Returns a list of differences; empty means equal.

  def diff(module, struct, fields, path \\ []) do
    props = module.__message_props__().field_props
    expected = Enum.group_by(fields, & &1["field"])

    set_fields =
      for {number, prop} <- props,
          value = Map.fetch!(struct, prop.name_atom),
          value not in [nil, []],
          do: number

    unexpected =
      for number <- set_fields,
          not Map.has_key?(expected, number),
          do: {path ++ [number], :unexpected}

    compared =
      Enum.flat_map(expected, fn {number, entries} ->
        case Map.fetch(props, number) do
          :error ->
            [{path ++ [number], :not_in_schema}]

          {:ok, prop} ->
            actual = Map.fetch!(struct, prop.name_atom)
            actual = if prop.repeated?, do: actual, else: List.wrap(actual)

            if length(actual) != length(entries) do
              [{path ++ [number], {:count, length(entries), length(actual)}}]
            else
              entries
              |> Enum.zip(actual)
              |> Enum.flat_map(fn {entry, value} ->
                compare(entry, value, prop, path ++ [number])
              end)
            end
        end
      end)

    unexpected ++ compared
  end

  defp compare(%{"type" => "message", "value" => fields}, value, prop, path),
    do: diff(prop.type, value, fields, path)

  defp compare(%{"type" => type, "value" => hex}, value, _prop, path) when type == "bytes",
    do:
      if(Base.decode16!(hex, case: :lower) == value, do: [], else: [{path, {:bytes, hex, value}}])

  defp compare(%{"type" => "string", "value" => text}, value, _prop, path),
    do: if(text == value, do: [], else: [{path, {:string, text, value}}])

  defp compare(%{"type" => "varint", "value" => expected}, value, _prop, path) do
    expected =
      case expected do
        digits when is_binary(digits) -> String.to_integer(digits)
        other -> other
      end

    if expected == value, do: [], else: [{path, {:varint, expected, value}}]
  end
end
