defmodule SalixVoice.Model.GptLiveTest do
  use ExUnit.Case, async: false

  alias SalixVoice.Model.GptLive

  # A local stand-in for the GPT-Live WebSocket endpoint: it reports each
  # client frame to the test and pushes whatever server events the test sends.
  defmodule FakeServer do
    @behaviour WebSock

    @impl true
    def init(state) do
      send(state.test, {:server_socket, self()})
      {:ok, state}
    end

    @impl true
    def handle_in({text, [opcode: :text]}, state) do
      send(state.test, {:client_event, Jason.decode!(text)})
      {:ok, state}
    end

    @impl true
    def handle_info({:push, event}, state), do: {:push, {:text, Jason.encode!(event)}, state}
    def handle_info(:drop, state), do: {:stop, :normal, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule Endpoint do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, test: test) do
      send(test, {:upgrade, conn.request_path, get_req_header(conn, "authorization")})

      conn
      |> WebSockAdapter.upgrade(FakeServer, %{test: test}, timeout: 30_000)
      |> halt()
    end
  end

  setup do
    listener =
      start_supervised!(
        {Bandit, plug: {Endpoint, test: self()}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    %{url: "ws://127.0.0.1:#{port}/v1/live/sessions"}
  end

  defp start_model(url, format, extra_settings \\ %{}) do
    Process.flag(:trap_exit, true)
    ref = make_ref()

    {:ok, pid} =
      GptLive.start_link(%{
        owner: self(),
        ref: ref,
        audio_format: format,
        instructions: "Be brief.",
        settings:
          Map.merge(%{"gpt_live_url" => url, "openai_api_key" => "sk-test"}, extra_settings)
      })

    assert_receive {:upgrade, "/v1/live/sessions", ["Bearer sk-test"]}, 2_000
    assert_receive {:server_socket, server}, 2_000
    {pid, ref, server}
  end

  test "session.start requests client delegation and mu-law audio, then events normalize", %{
    url: url
  } do
    {pid, ref, server} = start_model(url, :pcmu_8k, %{"gpt_live_voice" => "marin"})

    assert_receive {:client_event, start}, 2_000

    assert start == %{
             "type" => "session.start",
             "session" => %{
               "model" => "gpt-live-1",
               "instructions" => "Be brief.",
               "delegation" => %{"type" => "client"},
               "audio" => %{
                 "format" => %{"type" => "audio/pcmu", "rate" => 8000},
                 "output" => %{"voice" => "marin"}
               }
             }
           }

    send(
      server,
      {:push,
       %{"type" => "session.started", "session" => %{"id" => "sess_123", "model" => "gpt-live-1"}}}
    )

    assert_receive {:voice_model, ^ref, {:started, "sess_123"}}

    GptLive.send_audio(pid, <<1, 2, 3>>)
    assert_receive {:client_event, %{"type" => "session.input_audio.append", "audio" => "AQID"}}

    GptLive.append(pid, :commentary, "item_delegation_123", "Paris is sunny.")

    assert_receive {:client_event,
                    %{
                      "type" => "session.commentary.append",
                      "delegation_id" => "item_delegation_123",
                      "content" => "Paris is sunny.",
                      "event_id" => _
                    }}

    GptLive.append(pid, :thinking, nil, "Still checking.")

    assert_receive {:client_event,
                    %{
                      "type" => "session.thinking.append",
                      "delegation_id" => nil,
                      "content" => "Still checking."
                    }}

    GptLive.append(pid, :instructions, nil, "End the call now.")
    assert_receive {:client_event, %{"type" => "session.instructions.append"}}

    # The live service sends output audio without timing; the output
    # transcript carries the agent's speech timeline.
    send(
      server,
      {:push, %{"type" => "session.output_audio.delta", "delta" => Base.encode64(<<9, 9>>)}}
    )

    assert_receive {:voice_model, ^ref, {:audio, <<9, 9>>}}

    send(
      server,
      {:push,
       %{
         "type" => "session.output_transcript.delta",
         "delta" => "Let me explain.",
         "start_ms" => 0,
         "end_ms" => 2_000
       }}
    )

    assert_receive {:voice_model, ^ref, {:output_transcript, "Let me explain.", true}}

    # The caller speaks at 1.5 s while agent speech runs to 2 s: a barge-in,
    # reported once for this output run.
    for {delta, start_ms} <- [{"wait", 1_500}, {"please", 1_700}] do
      send(
        server,
        {:push,
         %{
           "type" => "session.input_transcript.delta",
           "delta" => delta,
           "start_ms" => start_ms,
           "end_ms" => start_ms + 200
         }}
      )
    end

    assert_receive {:voice_model, ^ref, :speech_started}
    assert_receive {:voice_model, ^ref, {:input_transcript, "wait", true, 1_500}}
    assert_receive {:voice_model, ^ref, {:input_transcript, "please", true, 1_700}}
    refute_received {:voice_model, ^ref, :speech_started}

    send(
      server,
      {:push,
       %{
         "type" => "session.output_transcript.delta",
         "delta" => "Sure.",
         "start_ms" => 0,
         "end_ms" => 500
       }}
    )

    assert_receive {:voice_model, ^ref, {:output_transcript, "Sure.", true}}

    send(
      server,
      {:push,
       %{
         "type" => "session.delegation.created",
         "offset_ms" => 1_000,
         "delegation" => %{
           "id" => "item_delegation_123",
           "type" => "delegation",
           "target" => "client"
         }
       }}
    )

    assert_receive {:voice_model, ^ref, {:delegation, "item_delegation_123", 1_000}}

    send(
      server,
      {:push,
       %{
         "type" => "error",
         "error" => %{
           "type" => "invalid_request_error",
           "code" => "invalid_audio",
           "message" => "odd"
         }
       }}
    )

    assert_receive {:voice_model, ^ref, {:error, %{"code" => "invalid_audio"}}}

    send(server, {:push, %{"type" => "session.usage.updated", "usage" => %{"seconds" => 12}}})
    GptLive.close(pid)
    assert_receive {:client_event, %{"type" => "session.close"}}

    send(
      server,
      {:push,
       %{
         "type" => "session.closed",
         "reason" => "close_requested",
         "usage" => %{"seconds" => 128}
       }}
    )

    assert_receive {:voice_model, ^ref, {:closed, "close_requested", %{"seconds" => 128}}}
    assert_receive {:EXIT, ^pid, _reason}, 2_000
    refute_received {:voice_model, ^ref, {:closed, _, _}}
  end

  # Timings from a live GPT-Live session: the service delivers the agent's
  # transcript about a second after its timeline position, so a caller who
  # talks over queued agent audio can start after the last agent fragment
  # already received ends.
  test "barge-in: a caller fragment starting after the agent's run began clears playback once",
       %{url: url} do
    {_pid, ref, server} = start_model(url, :pcm16_24k)
    push = fn event -> send(server, {:push, event}) end

    output = fn delta, start_ms ->
      %{
        "type" => "session.output_transcript.delta",
        "delta" => delta,
        "start_ms" => start_ms,
        "end_ms" => start_ms + 200
      }
    end

    input = fn delta, start_ms ->
      %{
        "type" => "session.input_transcript.delta",
        "delta" => delta,
        "start_ms" => start_ms,
        "end_ms" => start_ms + 200
      }
    end

    push.(input.(" Roman Empire", 3_200))
    push.(output.(" Sure,", 6_600))
    # The tail of the caller's own question is transcribed after the agent's
    # first words, but it started before them: not a barge-in.
    push.(input.(" in detail", 6_000))
    push.(output.(" there's a lot", 7_000))
    push.(output.(" [laugh]", 8_800))

    assert_receive {:voice_model, ^ref, {:input_transcript, " in detail", true, 6_000}}
    assert_receive {:voice_model, ^ref, {:output_transcript, " [laugh]", true}}
    refute_received {:voice_model, ^ref, :speech_started}

    push.(input.(" Wait", 9_400))
    push.(input.(", stop", 10_400))

    assert_receive {:voice_model, ^ref, :speech_started}
    assert_receive {:voice_model, ^ref, {:input_transcript, ", stop", true, 10_400}}
    refute_received {:voice_model, ^ref, :speech_started}

    # The agent answers while the caller finishes the sentence: the caller's
    # next word continues the utterance, so it is not a barge-in.
    push.(input.(" of", 12_600))
    push.(output.(" Sure, that's", 13_000))
    push.(input.(" France", 13_000))
    assert_receive {:voice_model, ^ref, {:input_transcript, " France", true, 13_000}}
    refute_received {:voice_model, ^ref, :speech_started}

    # A new caller utterance during that run is.
    push.(input.(" Thanks", 14_000))
    assert_receive {:voice_model, ^ref, :speech_started}
  end

  test "PCM16 24 kHz uses the service default format; a lost transport reports last usage", %{
    url: url
  } do
    {pid, ref, server} = start_model(url, :pcm16_24k)

    assert_receive {:client_event, %{"type" => "session.start", "session" => session}}
    refute Map.has_key?(session, "audio")

    send(server, {:push, %{"type" => "session.started", "session" => %{"id" => "sess_2"}}})
    assert_receive {:voice_model, ^ref, {:started, "sess_2"}}
    send(server, {:push, %{"type" => "session.usage.updated", "usage" => %{"seconds" => 30}}})
    send(server, :drop)

    assert_receive {:voice_model, ^ref, {:closed, "connection_lost", %{"seconds" => 30}}}, 2_000
    assert_receive {:EXIT, ^pid, _reason}, 2_000
  end

  test "the model key is not in the adapter's state or status", %{url: url} do
    {pid, _ref, _server} = start_model(url, :pcmu_8k)

    refute inspect(:sys.get_state(pid)) =~ "sk-test"
    refute inspect(:sys.get_status(pid)) =~ "sk-test"
  end

  test "an unreachable endpoint reports an error and a close" do
    Process.flag(:trap_exit, true)
    ref = make_ref()

    {:ok, pid} =
      GptLive.start_link(%{
        owner: self(),
        ref: ref,
        audio_format: :pcmu_8k,
        instructions: "x",
        settings: %{
          "gpt_live_url" => "ws://127.0.0.1:1/v1/live/sessions",
          "openai_api_key" => "k"
        }
      })

    assert_receive {:voice_model, ^ref, {:error, {:disconnected, _}}}, 5_000
    assert_receive {:voice_model, ^ref, {:closed, "connection_lost", %{}}}
    assert_receive {:EXIT, ^pid, _}, 2_000
  end
end
