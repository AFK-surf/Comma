defmodule SalixAgent.AudioTranscriberTest do
  use ExUnit.Case, async: false

  alias SalixAgent.AudioTranscriber

  defmodule RecordingTranscriber do
    @behaviour SalixAgent.AudioTranscriber

    @impl true
    def transcribe(agent_id, path) do
      send(self(), {:transcribe, agent_id, path})

      {:ok,
       %{
         transcript: "hello",
         duration_seconds: 1,
         chunks: [%{index: 0, offset_seconds: 0, transcript: "hello"}]
       }}
    end
  end

  setup do
    previous = Application.get_env(:salix_agent, :audio_transcriber_mod)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:salix_agent, :audio_transcriber_mod)
      else
        Application.put_env(:salix_agent, :audio_transcriber_mod, previous)
      end
    end)

    :ok
  end

  test "fails closed when no implementation is configured" do
    Application.delete_env(:salix_agent, :audio_transcriber_mod)
    assert {:error, :asr_not_configured} = AudioTranscriber.transcribe("agent-1", "/audio.ogg")
  end

  test "forwards the trusted agent id and visible path unchanged" do
    Application.put_env(:salix_agent, :audio_transcriber_mod, RecordingTranscriber)

    assert {:ok, %{transcript: "hello"}} =
             AudioTranscriber.transcribe("agent-1", "/uploads/audio.ogg")

    assert_receive {:transcribe, "agent-1", "/uploads/audio.ogg"}
  end

  test "rejects non-binary source identity before dispatch" do
    Application.put_env(:salix_agent, :audio_transcriber_mod, RecordingTranscriber)
    assert {:error, :invalid_asr_source} = AudioTranscriber.transcribe(nil, "/audio.ogg")
    refute_receive {:transcribe, _, _}
  end
end
