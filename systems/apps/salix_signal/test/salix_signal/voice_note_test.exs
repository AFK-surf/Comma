defmodule SalixSignal.VoiceNoteTest do
  # Voice notes (CRS-10 section 11.1): container sniffing and hand-off of the
  # decrypted audio to the transcriber.
  use ExUnit.Case, async: true

  alias SalixSignal.Test.{FakeCdn, FakeChat}
  alias SalixSignal.VoiceNote
  alias SalixSignalProto.Attachment
  alias SalixSignalProto.Attachment.Pointer

  defmodule Transcriber do
    def transcribe_audio_with_metadata(cfg, audio, name, prompt, opts) do
      send(cfg["test"], {:transcribe, audio, name, prompt, opts})
      {:ok, %{transcript: "hello from signal", duration_seconds: 2, chunks: []}}
    end
  end

  # First bytes of each container a sender uses.
  @adts <<0xFF, 0xF1, 0x50, 0x80, 0x02, 0x1F, 0xFC>>
  @mp3_frame <<0xFF, 0xFB, 0x90, 0x64>>
  @mp4 <<0, 0, 0, 0x1C, "ftypM4A ", 0, 0, 0, 0>>

  test "the container is recognized from the bytes, not the content type" do
    assert VoiceNote.container(@adts) == :adts
    assert VoiceNote.container(@mp3_frame) == :mp3
    assert VoiceNote.container("ID3" <> <<4, 0>>) == :mp3
    assert VoiceNote.container(@mp4) == :mp4
    assert VoiceNote.container("OggS") == :unknown

    assert VoiceNote.file_name(@mp4, "audio/aac") == {:ok, "voice-note.m4a"}
    assert VoiceNote.file_name("????", "audio/mpeg") == {:ok, "voice-note.mp3"}
    assert VoiceNote.file_name("????", "application/pdf") == {:error, :unsupported_audio}
  end

  test "a downloaded voice note reaches the transcriber with its container's name" do
    chain = FakeChat.chain()
    cdn = start_supervised!({FakeCdn, self()})
    server = start_supervised!({Bandit, FakeCdn.bandit_options(cdn, chain)})
    url = "https://localhost:#{FakeChat.port(server)}"

    audio = @adts <> :crypto.strong_rand_bytes(500)
    keys = Attachment.generate_keys()

    %{blob: blob, digest: digest, size: size} =
      Attachment.encrypt(audio, keys, Attachment.generate_iv())

    FakeCdn.put_object(cdn, "attachments/voice0000000000000001", blob)

    pointer = %Pointer{
      cdn_key: "voice0000000000000001",
      cdn_number: 3,
      content_type: "audio/mp4",
      keys: keys,
      size: size,
      digest: digest,
      flags: Pointer.flag_voice_message()
    }

    opts = [
      http: [trust: :signal, roots: [chain.root]],
      base_urls: %{3 => url},
      transcriber: Transcriber
    ]

    assert {:ok, %{transcript: "hello from signal"}} =
             VoiceNote.download_and_transcribe(pointer, %{"test" => self()}, opts)

    assert_received {:transcribe, ^audio, "voice-note.aac", _prompt, []}

    assert VoiceNote.download_and_transcribe(%{pointer | flags: nil}, %{}, opts) ==
             {:error, :not_a_voice_note}
  end
end
