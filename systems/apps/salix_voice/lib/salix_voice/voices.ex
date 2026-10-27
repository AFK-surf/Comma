defmodule SalixVoice.Voices do
  @moduledoc """
  The voices a Group's calls can speak with
  (docs/messaging-voice.md#call-preferences): a GPT-Live preset, or a custom
  voice the platform's OpenAI account created from a description. Without a
  choice, calls use the platform's `gpt_live_voice`.
  """

  # GPT-Live's documented preset voices (API names).
  @presets ~w(quartz ripple vesper willow stone gleam meridian bossa tempo beacon delta
    cinder nuri juni flitz brise sillage nira harema shida noeul)

  @doc "The preset voice names."
  @spec presets() :: [String.t()]
  def presets, do: @presets

  @doc "True when `name` is a preset voice."
  def preset?(name), do: name in @presets

  @doc """
  The session voice of stored call preferences (`SalixIM.VoiceConnects`): a
  preset's name, `%{"id" => id}` for the custom voice, nil for the platform
  default.
  """
  @spec session_voice(map()) :: String.t() | map() | nil
  def session_voice(%{"voice" => %{"kind" => "preset", "name" => name}}), do: name

  def session_voice(%{"voice" => %{"kind" => "custom"}, "custom_voice" => %{"id" => id}}),
    do: %{"id" => id}

  def session_voice(_prefs), do: nil
end
