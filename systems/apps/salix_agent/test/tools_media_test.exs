defmodule SalixAgent.ToolsMediaTest do
  @moduledoc """
  Media generation tools (`SalixAgent.Tools.Media`, willow's image.generate /
  video.generate): against a mock Bandit media provider (same canned response
  shapes as `SalixMedia.MockMedia`), a base64 image payload is decoded and
  written into the VFS via a `vfs_write` event (applied + read back), a
  url-only response returns plain text with no events, and provider failures
  raise willow's error texts. Direct tool-fun unit tests with the Fake S3
  backend.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentWorkspace, Tools}
  alias SalixAgent.Tools.Media

  defmodule MockAudioTranscriber do
    @behaviour SalixAgent.AudioTranscriber

    @impl true
    def transcribe(agent_id, path) do
      owner = SystemsRuntime.fetch_env!(:salix_agent, :tools_media_test_pid)
      SystemsRuntime.Proc.send(owner, {:audio_transcribe, agent_id, path})

      SystemsRuntime.Proc.sleep(
        SystemsRuntime.get_env(:salix_agent, :tools_media_audio_delay_ms, 0)
      )

      transcribe_result(path)
    end

    defp transcribe_result("/uploads/silence.mp4"), do: {:error, :asr_empty_transcript}

    defp transcribe_result(_path) do
      {:ok,
       %{
         transcript: "[00:00:01] Speaker: complete",
         duration_seconds: 7,
         chunks: [
           %{index: 0, offset_seconds: 0, transcript: "[00:00:01] Speaker: complete"}
         ]
       }}
    end
  end

  defmodule MockResolver do
    @behaviour SalixAgent.MediaResolver

    def set(config), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :config}, config)

    @impl true
    def resolve(_agent_id),
      do: {:ok, SystemsRuntime.PersistentTerm.get({__MODULE__, :config}, nil)}
  end

  defmodule MockMedia do
    @moduledoc """
    Tiny Plug impersonating the media provider API — same canned response
    shapes as `SalixMedia.MockMedia`, plus an optional status code so 4xx
    provider errors can be exercised. Canned `{status, body}` is keyed by
    request path; the last decoded request is recorded for shape assertions.
    """
    import Plug.Conn

    use Agent

    def start_link(_ \\ []),
      do:
        Agent.start_link(fn -> %{responses: %{}, last_request: nil, last_path: nil} end,
          name: __MODULE__
        )

    def set(path, resp, status \\ 200),
      do: Agent.update(__MODULE__, fn s -> put_in(s, [:responses, path], {status, resp}) end)

    def last_request, do: Agent.get(__MODULE__, & &1.last_request)
    def last_path, do: Agent.get(__MODULE__, & &1.last_path)

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      req = Jason.decode!(raw)
      path = conn.request_path

      Agent.update(__MODULE__, fn s -> %{s | last_request: req, last_path: path} end)
      {status, resp} = Agent.get(__MODULE__, fn s -> s.responses[path] || {200, %{}} end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(resp))
    end
  end

  setup do
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(MockMedia)

    # Retry on port collisions (randomized ports can collide across suites).
    port =
      Enum.find_value(1..10, fn _ ->
        p = 40000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20000)

        case start_supervised({Bandit, plug: MockMedia, port: p}, id: {:bandit, p}) do
          {:ok, _pid} -> p
          {:error, _} -> nil
        end
      end)

    prev_url = SystemsRuntime.get_env(:salix_media, :base_url)
    prev_key = SystemsRuntime.get_env(:salix_media, :api_key)
    prev_resolver = SystemsRuntime.get_env(:salix_agent, :media_resolver)
    prev_audio_transcriber = SystemsRuntime.get_env(:salix_agent, :audio_transcriber_mod)
    prev_test_pid = SystemsRuntime.get_env(:salix_agent, :tools_media_test_pid)
    prev_audio_delay = SystemsRuntime.get_env(:salix_agent, :tools_media_audio_delay_ms)
    SystemsRuntime.put_env(:salix_media, :base_url, "http://127.0.0.1:#{port}")
    SystemsRuntime.put_env(:salix_media, :api_key, "test-key")
    SystemsRuntime.put_env(:salix_agent, :media_resolver, MockResolver)
    SystemsRuntime.put_env(:salix_agent, :audio_transcriber_mod, MockAudioTranscriber)
    SystemsRuntime.put_env(:salix_agent, :tools_media_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_agent, :tools_media_audio_delay_ms, 0)

    MockResolver.set(%{
      "image_config" => %{
        "provider" => "legacy",
        "model" => "mock-image",
        "provider_config" => %{"base_url" => "http://127.0.0.1:#{port}", "api_key" => "test-key"}
      },
      "video_config" => %{
        "provider" => "legacy",
        "model" => "mock-video",
        "provider_config" => %{"base_url" => "http://127.0.0.1:#{port}", "api_key" => "test-key"}
      }
    })

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
      SystemsRuntime.put_env(:salix_media, :base_url, prev_url)
      SystemsRuntime.put_env(:salix_media, :api_key, prev_key)
      restore_env(:media_resolver, prev_resolver)
      restore_env(:audio_transcriber_mod, prev_audio_transcriber)
      restore_env(:tools_media_test_pid, prev_test_pid)
      restore_env(:tools_media_audio_delay_ms, prev_audio_delay)
      SystemsRuntime.PersistentTerm.erase({MockResolver, :config})
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    {:ok, agent: agent, ctx: %{agent_id: agent}}
  end

  describe "image.generate" do
    test "decodes a b64 payload, writes it to the VFS, and round-trips", %{agent: agent, ctx: ctx} do
      bytes = "fake-png-bytes-#{SystemsRuntime.Proc.unique_integer([:positive])}"

      MockMedia.set("/v1/images/generations", %{"data" => [%{"b64_json" => Base.encode64(bytes)}]})

      assert {content, [event]} =
               Media.generate_image(%{"prompt" => "a red fox", "path" => "/images/fox.png"}, ctx)

      assert content =~ "[Generated image: /images/fox.png, #{byte_size(bytes)} bytes"
      assert content =~ "Generation prompt: a red fox"
      assert %{"type" => "vfs_write", "path" => "/images/fox.png"} = event

      # Commit the workspace event and read the body back through AgentWorkspace.
      commit_workspace!(agent, "image-fox", [event])
      assert {:ok, ^bytes} = AgentWorkspace.read(agent, "/images/fox.png")

      # The prompt is forwarded to the provider unchanged.
      assert MockMedia.last_path() == "/v1/images/generations"
      assert MockMedia.last_request()["prompt"] == "a red fox"
    end

    test "a url-only response returns the URL as text with no events", %{ctx: ctx} do
      MockMedia.set("/v1/images/generations", %{"data" => [%{"url" => "https://cdn/img-1.png"}]})

      assert "[Generated image available at: https://cdn/img-1.png]" =
               Media.generate_image(%{"prompt" => "a red fox"}, ctx)
    end
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)

  defp commit_workspace!(agent, operation_id, events) do
    assert {:ok, _} =
             AgentWorkspace.seed_operation(agent, "media-test:" <> operation_id, %{}, events)

    :ok
  end

  describe "video.generate" do
    test "a url-only response returns the URL as text with no events", %{ctx: ctx} do
      MockMedia.set("/v1/videos/generations", %{"video" => %{"url" => "https://cdn/clip-1.mp4"}})

      assert "[Generated video available at: https://cdn/clip-1.mp4]" =
               Media.generate_video(%{"prompt" => "waves at dusk"}, ctx)

      assert MockMedia.last_path() == "/v1/videos/generations"
      assert MockMedia.last_request()["prompt"] == "waves at dusk"
    end
  end

  describe "image.generate and video.generate failures" do
    for {kind, generate, endpoint} <- [
          {"image", :generate_image, "/v1/images/generations"},
          {"video", :generate_video, "/v1/videos/generations"}
        ] do
    end
  end

  describe "audio.transcribe" do
    test "uses the current agent scope and writes the complete transcript to VFS", %{
      agent: agent,
      ctx: ctx
    } do
      assert {content, [event]} =
               Media.transcribe_audio(%{"path" => "/uploads/interview.m4a"}, ctx)

      assert_receive {:audio_transcribe, ^agent, "/uploads/interview.m4a"}
      assert %{"type" => "vfs_write", "path" => transcript_path} = event
      assert transcript_path =~ ~r{^/artifacts/transcripts/audio-transcript-\d+\.txt$}

      assert %{
               "source_path" => "/uploads/interview.m4a",
               "transcript_path" => ^transcript_path,
               "duration_seconds" => 7,
               "chunk_count" => 1
             } = Jason.decode!(content)

      commit_workspace!(agent, "audio-transcript", [event])

      assert {:ok, "[00:00:01] Speaker: complete"} =
               AgentWorkspace.read(agent, transcript_path)
    end

    test "reports a file without speech as such instead of a failure", %{
      agent: agent,
      ctx: ctx
    } do
      assert {content, []} = Media.transcribe_audio(%{"path" => "/uploads/silence.mp4"}, ctx)

      assert_received {:audio_transcribe, ^agent, "/uploads/silence.mp4"}

      assert %{"source_path" => "/uploads/silence.mp4", "speech_detected" => false} ==
               Jason.decode!(content)
    end
  end
end
