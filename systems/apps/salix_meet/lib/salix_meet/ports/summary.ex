defmodule SalixMeet.Ports.Summary do
  @moduledoc false

  @callback summarize(state :: map()) :: {:ok, map()} | :skip | {:error, term()}
  @callback prepare_context(state :: map()) ::
              {:ok, map()} | :skip | {:error, term()}
  @callback summarize(state :: map(), context :: map()) ::
              {:ok, map()} | :skip | {:error, term()}

  @optional_callbacks prepare_context: 1, summarize: 2

  @spec summarize(map()) :: {:ok, map()} | :skip | {:error, term()}
  def summarize(state) when is_map(state), do: impl().summarize(state)

  @spec summarize(map(), map()) :: {:ok, map()} | :skip | {:error, term()}
  def summarize(state, context) when is_map(state) and is_map(context) do
    mod = impl()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :summarize, 2) do
      mod.summarize(state, context)
    else
      mod.summarize(state)
    end
  end

  @spec prepare_context(map()) :: {:ok, map()} | :skip | {:error, term()}
  def prepare_context(state) when is_map(state) do
    mod = impl()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :prepare_context, 1) do
      mod.prepare_context(state)
    else
      {:ok, fallback_context(state)}
    end
  end

  defp impl do
    Application.get_env(:salix_meet, :summary_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.Summary

    @impl true
    def summarize(_state), do: :skip
  end

  # Compatibility context for test/custom summary adapters which predate the
  # explicit canonical-context callback. The production binding implements
  # `prepare_context/1` and supplies the exact transcript it summarizes.
  defp fallback_context(state) do
    captions =
      state["captions"]
      |> List.wrap()
      |> Enum.map(&stringify/1)
      |> Enum.map_join("\n", fn caption ->
        text = trim(caption["text"])

        case trim(caption["speaker"]) do
          "" -> text
          speaker -> speaker <> ": " <> text
        end
      end)
      |> String.trim()

    chat =
      state["chats"]
      |> List.wrap()
      |> Enum.map(&stringify/1)
      |> Enum.reject(&(trim(&1["direction"]) == "outgoing"))
      |> Enum.map_join("\n", fn message ->
        sender = blank_default(trim(message["sender"]), "Unknown")
        sender <> ": " <> trim(message["text"])
      end)
      |> String.trim()

    transcript =
      case {captions, chat} do
        {"", ""} -> ""
        {"", chat} -> "In-meeting chat:\n" <> chat
        {captions, ""} -> captions
        {captions, chat} -> captions <> "\n\nIn-meeting chat:\n" <> chat
      end

    %{
      "version" => 1,
      "source" => "captions_chat_fallback",
      "transcript" => transcript
    }
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify(_), do: %{}

  defp blank_default("", fallback), do: fallback
  defp blank_default(value, _fallback), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)

  defp trim(value) when is_atom(value) or is_number(value),
    do: value |> to_string() |> String.trim()

  defp trim(_), do: ""
end
