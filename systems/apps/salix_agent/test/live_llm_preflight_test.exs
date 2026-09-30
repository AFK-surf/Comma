defmodule SalixAgent.LiveLlmPreflightTest do
  @moduledoc """
  `LiveLlmTestSupport.preflight!/1` is what stops a dead provider from looking
  like a product regression (#945): every `:live_llm` shard asks once, up
  front, so an outage fails in seconds with the provider's own words instead of
  each test spending its full `eventually/2` budget on a turn that can never
  arrive.

  These tests are deliberately NOT tagged `:live_llm` — they run in the
  ordinary suite against a local stub socket and never touch a real provider,
  which is the only way this guard gets exercised while the real one is down.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LiveLlmTestSupport, as: Live

  @quota_body ~s({"type":"error","error":{"type":"GoUsageLimitError",) <>
                ~s("message":"Monthly usage limit reached. Resets in 14 days."}})

  setup do
    :persistent_term.erase({Live, :preflight})
    on_exit(fn -> :persistent_term.erase({Live, :preflight}) end)
    :ok
  end

  test "a quota 429 fails the shard immediately, quoting the provider" do
    port = start_stub(429, @quota_body)

    error = assert_raise(RuntimeError, fn -> Live.preflight!(llm(port)) end)
    message = error.message

    assert message =~ "live LLM provider is out of quota (HTTP 429)"
    assert message =~ "Monthly usage limit reached"
    assert message =~ "http://127.0.0.1:#{port}/v1"
    assert message =~ "stub-model"
    # The point of the guard: say why nothing can pass, not just that it did not.
    assert message =~ "no :live_llm test can pass"
  end

  test "a rejected credential is named as such, not as a generic failure" do
    port = start_stub(401, ~s({"error":{"message":"invalid api key"}}))

    error = assert_raise(RuntimeError, fn -> Live.preflight!(llm(port)) end)
    message = error.message

    assert message =~ "live LLM credential was rejected (HTTP 401)"
    assert message =~ "invalid api key"
  end

  test "a reachable provider passes and is only asked once" do
    port =
      start_stub(200, ~s({"choices":[{"message":{"content":"pong"},"finish_reason":"stop"}]}))

    assert :ok = Live.preflight!(llm(port))
    assert :persistent_term.get({Live, :preflight}) == :ok

    # Second call must not reach the socket at all: close the listener and
    # assert the memoized answer still stands.
    stop_stub(port)
    assert :ok = Live.preflight!(llm(port))
  end

  defp llm(port) do
    System.put_env("STUB_LLM_KEY", "stub-key")
    on_exit(fn -> System.delete_env("STUB_LLM_KEY") end)

    %{
      protocol: "chat_completions",
      base_url: "http://127.0.0.1:#{port}/v1",
      api_key_env: "STUB_LLM_KEY",
      model: "stub-model",
      max_tokens: 2_000
    }
  end

  # A one-socket HTTP stub. Req retries transient statuses internally and the
  # preflight retries once more on top, so the acceptor serves every connection
  # until the test ends rather than answering a single request.
  defp start_stub(status, body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    owner = self()

    pid =
      spawn_link(fn ->
        send(owner, {:stub_ready, port})
        accept_loop(listen, status, body)
      end)

    receive do
      {:stub_ready, ^port} -> :ok
    after
      5_000 -> flunk("stub listener did not start")
    end

    :persistent_term.put({__MODULE__, port}, {listen, pid})
    on_exit(fn -> stop_stub(port) end)
    port
  end

  defp stop_stub(port) do
    case :persistent_term.get({__MODULE__, port}, nil) do
      {listen, pid} ->
        :persistent_term.erase({__MODULE__, port})
        Process.unlink(pid)
        Process.exit(pid, :kill)
        :gen_tcp.close(listen)

      nil ->
        :ok
    end
  end

  defp accept_loop(listen, status, body) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _ = :gen_tcp.recv(socket, 0, 5_000)

        response =
          "HTTP/1.1 #{status} #{reason(status)}\r\n" <>
            "content-type: application/json\r\n" <>
            "content-length: #{byte_size(body)}\r\n" <>
            "connection: close\r\n\r\n" <> body

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        accept_loop(listen, status, body)

      {:error, _closed} ->
        :ok
    end
  end

  defp reason(200), do: "OK"
  defp reason(401), do: "Unauthorized"
  defp reason(429), do: "Too Many Requests"
  defp reason(_status), do: "Error"
end
