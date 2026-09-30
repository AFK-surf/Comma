defmodule SalixVoice.Carrier do
  @moduledoc """
  Wire codec behaviour for a call's carrier socket (docs/messaging-voice.md).

  A carrier socket process (a WebSock handler in `salix_web`) decodes each
  inbound frame into events and forwards them to its `SalixVoice.CallActor`,
  and encodes each `{:voice_call, ...}` message it receives into frames.

  Decoded events:

    * `:connected`
    * `{:start, map}`: carrier session parameters (Twilio `start`, or the
      WebSocket `session.start`)
    * `{:audio, binary}`: caller audio in the call's format; forward as
      `{:voice_carrier, :audio, binary}`
    * `{:mark_played, name}`: forward as `{:voice_carrier, :mark_played, name}`
    * `{:hangup, reason}`: forward as `{:voice_carrier, :hangup, reason}`
    * `{:dtmf, digit}`: forward as `{:voice_carrier, :dtmf, digit}`

  Commands to encode are the `{:voice_call, ...}` payloads without the tag:
  `{:audio, binary}`, `:clear`, `{:mark, name}`,
  `{:transcript, role, text, final?}` and `{:end, reason}`.

  Frames are `{:text, iodata}` or `{:binary, iodata}`, ready for a WebSock
  `{:push, frames, state}` reply.
  """

  @type frame :: {:text, iodata()} | {:binary, iodata()}
  @type event ::
          :connected
          | {:start, map()}
          | {:audio, binary()}
          | {:mark_played, String.t()}
          | {:hangup, atom()}
          | {:dtmf, String.t()}
  @type command ::
          {:audio, binary()}
          | :clear
          | {:mark, String.t()}
          | {:transcript, :caller | :agent, String.t(), boolean()}
          | {:end, atom()}
          | term()

  @callback decode(frame(), state :: term()) :: {:ok, [event()], term()} | {:error, term()}
  @callback encode(command(), state :: term()) :: {[frame()], term()}

  @doc "Bytes of audio per second for an audio format."
  @spec bytes_per_second(:pcmu_8k | :pcm16_24k) :: pos_integer()
  def bytes_per_second(:pcmu_8k), do: 8_000
  def bytes_per_second(:pcm16_24k), do: 48_000

  @doc "Duration in milliseconds of `bytes` of audio."
  @spec audio_ms(non_neg_integer(), :pcmu_8k | :pcm16_24k) :: non_neg_integer()
  def audio_ms(bytes, format), do: div(bytes * 1000, bytes_per_second(format))
end
