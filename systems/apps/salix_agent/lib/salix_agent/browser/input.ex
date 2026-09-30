defmodule SalixAgent.Browser.Input do
  @moduledoc false
  import Bitwise
  alias SalixAgent.Browser.Commands

  def text(value, max) when is_binary(value) do
    if String.length(value) <= max, do: value, else: invalid()
  end

  def text(_, _), do: invalid()
  def number(value, min, max) when is_number(value) and value >= min and value <= max, do: value
  def number(_, _, _), do: invalid()
  def integer(value, min, max) when is_integer(value) and value >= min and value <= max, do: value
  def integer(_, _, _), do: invalid()

  def dispatch(state, session, %{"type" => "text"} = event),
    do: Commands.cdp(state, "Input.insertText", %{text: text(event["text"], 4096)}, session)

  def dispatch(state, session, %{"type" => type} = event) when type in ["keyDown", "keyUp"] do
    Commands.cdp(
      state,
      "Input.dispatchKeyEvent",
      %{
        type: type,
        key: text(event["key"], 128),
        code: text(event["code"], 128),
        modifiers: integer(event["modifiers"] || 0, 0, 15),
        windowsVirtualKeyCode: integer(event["keyCode"] || 0, 0, 255)
      },
      session
    )
  end

  def dispatch(state, session, %{"type" => type} = event)
      when type in ~w(mousePressed mouseReleased mouseMoved mouseWheel) do
    button = event["button"] || "none"
    unless button in ~w(none left right middle), do: invalid()

    params = %{
      type: type,
      x: number(event["x"], 0, 1280),
      y: number(event["y"], 0, 720),
      button: button,
      modifiers: integer(event["modifiers"] || 0, 0, 15),
      clickCount: integer(event["clickCount"] || 0, 0, 3)
    }

    params =
      if Map.has_key?(event, "buttons"),
        do: Map.put(params, :buttons, integer(event["buttons"], 0, 7)),
        else: params

    params =
      if type == "mouseWheel",
        do:
          Map.merge(params, %{
            deltaX: number(event["deltaX"] || 0, -4000, 4000),
            deltaY: number(event["deltaY"] || 0, -4000, 4000)
          }),
        else: params

    Commands.cdp(state, "Input.dispatchMouseEvent", params, session)
  end

  def dispatch(_, _, _), do: invalid()

  def click(state, session, x, y) do
    for type <- ["mousePressed", "mouseReleased"],
        do:
          dispatch(state, session, %{
            "type" => type,
            "x" => x,
            "y" => y,
            "button" => "left",
            "clickCount" => 1
          })
  end

  @keys %{
    "Enter" => {"Enter", 13},
    "Tab" => {"Tab", 9},
    "Backspace" => {"Backspace", 8},
    "Delete" => {"Delete", 46},
    "Escape" => {"Escape", 27},
    "Space" => {"Space", 32},
    "ArrowLeft" => {"ArrowLeft", 37},
    "ArrowUp" => {"ArrowUp", 38},
    "ArrowRight" => {"ArrowRight", 39},
    "ArrowDown" => {"ArrowDown", 40},
    "Home" => {"Home", 36},
    "End" => {"End", 35},
    "PageUp" => {"PageUp", 33},
    "PageDown" => {"PageDown", 34},
    "Shift" => {"ShiftLeft", 16},
    "Control" => {"ControlLeft", 17},
    "Alt" => {"AltLeft", 18},
    "Meta" => {"MetaLeft", 91}
  }
  @modifiers %{"Alt" => 1, "Control" => 2, "ControlOrMeta" => 2, "Meta" => 4, "Shift" => 8}
  def press(state, session, chord) do
    parts = if chord == "+", do: ["+"], else: String.split(chord, "+")
    {modifiers, [key]} = Enum.split(parts, -1)
    mask = Enum.reduce(modifiers, 0, fn name, acc -> bor(acc, @modifiers[name] || invalid()) end)
    {key, code, key_code} = key(key)
    key = if band(mask, 8) != 0 and String.length(key) == 1, do: String.upcase(key), else: key
    # Validate the whole chord before sending any input.
    modifier_keys =
      Enum.map(modifiers, fn name ->
        key(if name == "ControlOrMeta", do: "Control", else: name)
      end)

    Enum.each(modifier_keys, fn {key, code, key_code} ->
      key_event(state, session, "rawKeyDown", key, code, key_code, mask)
    end)

    printable = String.length(key) == 1 and band(mask, 7) == 0
    value = if key == "Enter", do: "\r", else: key

    key_event(
      state,
      session,
      "keyDown",
      key,
      code,
      key_code,
      mask,
      if(printable or key == "Enter", do: value, else: nil)
    )

    key_event(state, session, "keyUp", key, code, key_code, mask)

    Enum.each(Enum.reverse(modifier_keys), fn {key, code, key_code} ->
      key_event(state, session, "keyUp", key, code, key_code, 0)
    end)
  end

  defp key("Space"), do: {" ", "Space", 32}

  defp key(key) do
    cond do
      Map.has_key?(@keys, key) ->
        {code, value} = @keys[key]
        {key, code, value}

      String.match?(key, ~r/^[a-zA-Z]$/) ->
        {key, "Key" <> String.upcase(key), :binary.first(String.upcase(key))}

      String.match?(key, ~r/^Key[A-Z]$/) ->
        letter = String.last(key)
        {String.downcase(letter), key, :binary.first(letter)}

      String.match?(key, ~r/^[0-9]$/) ->
        {key, "Digit" <> key, :binary.first(key)}

      String.match?(key, ~r/^F([1-9]|1[0-2])$/) ->
        {key, key, 111 + String.to_integer(String.trim_leading(key, "F"))}

      String.length(key) == 1 ->
        {key, "", 0}

      true ->
        invalid()
    end
  end

  defp key_event(state, session, type, key, code, key_code, modifiers, text \\ nil) do
    params = %{
      type: type,
      key: key,
      code: code,
      windowsVirtualKeyCode: key_code,
      modifiers: modifiers
    }

    params = if text, do: Map.put(params, :text, text), else: params
    Commands.cdp(state, "Input.dispatchKeyEvent", params, session)
  end

  def release(state, session) do
    Enum.each(~w(Shift Control Alt Meta), fn name ->
      {key, code, value} = key(name)
      key_event(state, session, "keyUp", key, code, value, 0)
    end)

    Enum.each(~w(left middle right), fn button ->
      dispatch(state, session, %{
        "type" => "mouseReleased",
        "x" => 0,
        "y" => 0,
        "button" => button
      })
    end)
  end

  defp invalid, do: throw({:browser_error, "invalid_input"})
end
