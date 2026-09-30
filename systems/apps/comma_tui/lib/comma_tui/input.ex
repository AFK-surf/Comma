defmodule CommaTUI.Input do
  @moduledoc "Bounded incremental terminal input decoder. Paste never submits a form."
  defstruct buffer: "", paste: nil
  @limit 65_536
  @keys [
    {"\e[A", :up},
    {"\e[B", :down},
    {"\e[C", :right},
    {"\e[D", :left},
    {"\e[H", :home},
    {"\e[F", :end},
    {"\e[3~", :delete},
    {"\e[5~", :page_up},
    {"\e[6~", :page_down},
    {"\e\r", :newline},
    {"\e\n", :newline}
  ]

  def feed(state, bytes) when byte_size(bytes) <= @limit do
    buffer = state.buffer <> bytes

    if byte_size(buffer) + byte_size(state.paste || "") > @limit,
      do: {:error, :input_too_large},
      else: parse(%{state | buffer: buffer}, [])
  end

  def feed(_, _), do: {:error, :input_too_large}

  defp parse(%{paste: paste, buffer: buffer} = state, events) when is_binary(paste) do
    case :binary.match(buffer, "\e[201~") do
      {index, 6} ->
        <<part::binary-size(^index), _::binary-size(6), rest::binary>> = buffer
        text = CommaTUI.Text.safe(paste <> part)
        parse(%{state | buffer: rest, paste: nil}, [{:text, text} | events])

      :nomatch ->
        # Retain the delimiter prefix across SSH packets.
        n = max(byte_size(buffer) - 5, 0)
        <<part::binary-size(^n), rest::binary>> = buffer
        {:ok, Enum.reverse(events), %{state | paste: paste <> part, buffer: rest}}
    end
  end

  defp parse(%{buffer: ""} = state, events), do: {:ok, Enum.reverse(events), state}

  defp parse(%{buffer: "\e[200~" <> rest} = state, events),
    do: parse(%{state | buffer: rest, paste: ""}, events)

  defp parse(%{buffer: "\e[M" <> payload} = state, events) do
    case payload do
      <<button, _x, _y, rest::binary>> ->
        parse(%{state | buffer: rest}, mouse_event(button - 32, "M", events))

      _ ->
        {:ok, Enum.reverse(events), state}
    end
  end

  defp parse(%{buffer: "\e[<" <> _ = bytes} = state, events) do
    case Regex.run(~r/^\e\[<(\d{1,5});\d{1,5};\d{1,5}([Mm])/, bytes) do
      [sequence, button, action] ->
        rest = binary_part(bytes, byte_size(sequence), byte_size(bytes) - byte_size(sequence))
        parse(%{state | buffer: rest}, mouse_event(String.to_integer(button), action, events))

      nil ->
        if Regex.match?(~r/^\e\[<[0-9;]*$/, bytes) and byte_size(bytes) < 32 do
          {:ok, Enum.reverse(events), state}
        else
          {:error, :invalid_mouse_report}
        end
    end
  end

  defp parse(%{buffer: "\e" <> _ = bytes} = state, events) do
    case Enum.find(@keys, fn {sequence, _} -> String.starts_with?(bytes, sequence) end) do
      {sequence, key} ->
        rest = binary_part(bytes, byte_size(sequence), byte_size(bytes) - byte_size(sequence))
        parse(%{state | buffer: rest}, [key | events])

      nil ->
        cond do
          Enum.any?(
            ["\e[200~", "\e[M", "\e[<" | Enum.map(@keys, &elem(&1, 0))],
            &String.starts_with?(&1, bytes)
          ) ->
            {:ok, Enum.reverse(events), state}

          Regex.match?(~r/^\e\[[0-9;?]*$/, bytes) and byte_size(bytes) < 32 ->
            {:ok, Enum.reverse(events), state}

          true ->
            # Unknown controls are discarded, never interpreted as submit keys.
            rest = Regex.replace(~r/^\e(?:\[[0-9;?]*[ -\/]*[@-~]|.)/s, bytes, "")
            parse(%{state | buffer: rest}, events)
        end
    end
  end

  defp parse(%{buffer: <<byte, rest::binary>>} = state, events) when byte < 32 or byte == 127 do
    event =
      case byte do
        3 -> :interrupt
        4 -> :quit
        13 -> :submit
        10 -> :submit
        9 -> :tab
        b when b in [8, 127] -> :backspace
        1 -> :home
        5 -> :end
        _ -> :ignore
      end

    # CRLF is one submit.
    rest =
      if byte == 13 and String.starts_with?(rest, "\n"),
        do: binary_part(rest, 1, byte_size(rest) - 1),
        else: rest

    parse(%{state | buffer: rest}, [event | events])
  end

  defp parse(%{buffer: buffer} = state, events) do
    case buffer do
      <<char::utf8, rest::binary>> ->
        parse(%{state | buffer: rest}, [{:text, <<char::utf8>>} | events])

      _ ->
        case :unicode.characters_to_binary(buffer) do
          {:incomplete, _, _} -> {:ok, Enum.reverse(events), state}
          _ -> {:error, :invalid_utf8}
        end
    end
  end

  defp mouse_event(button, "M", events) do
    case Bitwise.band(button, Bitwise.bnot(28)) do
      64 -> [:scroll_up | events]
      65 -> [:scroll_down | events]
      _ -> events
    end
  end

  defp mouse_event(_, _, events), do: events
end
