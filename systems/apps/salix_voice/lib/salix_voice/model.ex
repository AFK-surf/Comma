defmodule SalixVoice.Model do
  @moduledoc """
  The voice model behind a call (docs/messaging-voice.md).

  A model process is started by one `SalixVoice.CallActor` (`opts.owner`) and
  sends it normalized events as `{:voice_model, opts.ref, event}`:

    * `{:started, session_id}`
    * `{:audio, binary}`: agent audio in the call's audio format
    * `{:input_transcript, text, final?, offset_ms | nil}`: caller text
    * `{:output_transcript, text, final?}`: agent text
    * `{:delegation, delegation_id, offset_ms}`
    * `:speech_started`: the caller barged in; the carrier clears playback
    * `{:closed, reason, usage_map}`: the session ended; `usage_map["seconds"]`
      holds billed seconds when the model reported them
    * `{:error, term}`

  `opts.settings` holds only the GPT-Live fields of `SalixVoice.Settings`:
  `gpt_live_url`, `gpt_live_model`, `gpt_live_voice` and `openai_api_key`. An
  implementation must not keep the key in its process state.

  The implementation is `Application.get_env(:salix_voice, :model_mod,
  SalixVoice.Model.GptLive)`.
  """

  @type audio_format :: :pcmu_8k | :pcm16_24k
  @type opts :: %{
          required(:owner) => pid(),
          required(:ref) => reference(),
          required(:audio_format) => audio_format(),
          required(:instructions) => String.t(),
          required(:settings) => map()
        }

  @callback start_link(opts()) :: {:ok, pid()} | {:error, term()}
  @callback send_audio(pid(), binary()) :: :ok
  @callback append(
              pid(),
              :commentary | :thinking | :instructions,
              delegation_id :: String.t() | nil,
              text :: String.t()
            ) :: :ok
  @callback close(pid()) :: :ok

  @doc "The configured model implementation."
  def impl, do: Application.get_env(:salix_voice, :model_mod, SalixVoice.Model.GptLive)
end
