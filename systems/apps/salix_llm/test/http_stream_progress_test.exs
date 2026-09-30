defmodule SalixLlm.HttpStreamProgressTest do
  @moduledoc """
  `SalixLlm.Http` reports every response body chunk of a streamed provider
  request to `SalixAgent.StreamProgress`, so the owner of a job killed at the
  deadline can read how much had arrived. Verified against the mock SSE
  server: the chunks the server wrote are the chunks the progress counts,
  keep-alive comments included, and a call with nothing installed records
  nothing.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.StreamProgress
  alias SalixLlm.{MockSSEServer, OpenAIChat}

  setup do
    start_supervised!(MockSSEServer)

    bandit =
      start_supervised!(
        {Bandit, plug: MockSSEServer, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    on_exit(fn -> StreamProgress.install(nil) end)

    {:ok,
     llm_opts: %{
       "protocol" => "",
       "model" => "gpt-test",
       "base_url" => "http://127.0.0.1:#{port}",
       "api_key" => "test-key"
     }}
  end

  test "counts the streamed body, keep-alives included, apart from content deltas", %{
    llm_opts: opts
  } do
    chunks = [
      ": keep-alive\n\n",
      ": keep-alive\n\n",
      "data: " <>
        Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "Hello"}}]}) <> "\n\n",
      "data: [DONE]\n\n"
    ]

    MockSSEServer.set_chunks(chunks)

    progress = StreamProgress.new()
    StreamProgress.install(progress)
    StreamProgress.begin_attempt(1)

    assert {:final, "Hello"} =
             OpenAIChat.complete_stream(
               [%{role: "user", content: "Say hello"}],
               [],
               fn _delta -> StreamProgress.observe_content() end,
               opts
             )

    snapshot = StreamProgress.snapshot(progress)

    assert snapshot.attempt == 1
    assert snapshot.http_status == 200
    assert snapshot.received_chunks == length(chunks)
    assert snapshot.received_bytes == chunks |> Enum.map(&byte_size/1) |> Enum.sum()
    assert is_integer(snapshot.first_body_ms)
    assert snapshot.last_body_ms >= snapshot.first_body_ms
    assert snapshot.content_deltas == 1
    assert snapshot.first_content_ms >= snapshot.first_body_ms
  end

  test "records nothing when no progress array is installed", %{llm_opts: opts} do
    MockSSEServer.set_chunks([
      "data: " <>
        Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "Hi"}}]}) <> "\n\n",
      "data: [DONE]\n\n"
    ])

    StreamProgress.install(nil)
    idle = StreamProgress.new()

    assert {:final, "Hi"} =
             OpenAIChat.complete_stream(
               [%{role: "user", content: "Hi"}],
               [],
               fn _ -> :ok end,
               opts
             )

    assert StreamProgress.snapshot(idle) == nil
  end
end
