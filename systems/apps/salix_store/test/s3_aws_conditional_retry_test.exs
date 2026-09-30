defmodule SalixStore.S3.AWSConditionalRetryTest do
  @moduledoc """
  The adapter-boundary contract behind CAS soundness: a conditional
  mutation (PUT or DELETE) whose transport failed and was retried, and
  whose retry answers 412, is classified
  `{:ambiguous, :conditional_retry_412}` — never a clean conflict —
  because attempt 1 may have landed. A first-attempt 412 stays a clean
  `:precondition_failed`. Driven against a real TCP listener so the actual
  retry sequence (request consumed, connection closed without a response →
  retry → HTTP response) is exercised, not a stubbed classification.
  """
  use ExUnit.Case, async: false

  alias SalixStore.S3.AWS

  setup do
    prev = Application.get_all_env(:salix_store)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    Application.put_env(:salix_store, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:salix_store, :s3_bucket, "retry-test")

    on_exit(fn ->
      :gen_tcp.close(listener)
      Application.put_all_env([{:salix_store, prev}])
    end)

    {:ok, listener: listener}
  end

  defp serve(listener, script) do
    Task.async(fn ->
      Enum.each(script, fn action ->
        {:ok, socket} = :gen_tcp.accept(listener, 10_000)

        case action do
          # Consume the COMPLETE request (headers + body) before closing
          # without a response: the portable shape of "the server may have
          # processed attempt 1" — closing before the body arrives would
          # model a request that provably never reached the handler.
          :swallow_and_close ->
            _ = drain_request(socket)
            :gen_tcp.close(socket)

          {:respond, status_line} ->
            _ = drain_request(socket)

            :gen_tcp.send(
              socket,
              "HTTP/1.1 #{status_line}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            )

            :gen_tcp.close(socket)
        end
      end)
    end)
  end

  # Read the full request: headers, then content-length bytes of body.
  defp drain_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} ->
        acc = acc <> data

        case String.split(acc, "\r\n\r\n", parts: 2) do
          [headers, body] ->
            expected = content_length(headers)

            if byte_size(body) >= expected,
              do: acc,
              else: drain_request(socket, acc)

          [_incomplete] ->
            drain_request(socket, acc)
        end

      {:error, _} ->
        acc
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/^content-length:\s*(\d+)\r?$/im, headers) do
      [_, len] -> String.to_integer(len)
      nil -> 0
    end
  end

  test "a retried conditional PUT 412 is ambiguous, a first-attempt 412 is clean", %{
    listener: listener
  } do
    # Full request consumed, connection closed with no response → Finch
    # :closed → adapter retries → the retry receives 412. Attempt 1 may
    # have landed: ambiguous.
    server = serve(listener, [:swallow_and_close, {:respond, "412 Precondition Failed"}])

    assert {:error, {:ambiguous, :conditional_retry_412}} =
             AWS.put("cas/retried", "body", if_match: "\"etag\"")

    Task.await(server, 15_000)

    # A first-attempt 412 (no transport retry involved) cannot have landed:
    # clean conflict, safe for CAS callers to re-run against.
    server = serve(listener, [{:respond, "412 Precondition Failed"}])

    assert {:error, :precondition_failed} =
             AWS.put("cas/clean", "body", if_match: "\"etag\"")

    Task.await(server, 15_000)

    # An UNconditional write retried into a 412 (not that S3 produces one)
    # keeps the plain classification — the ambiguity rule is scoped to
    # conditional writes.
    server = serve(listener, [:swallow_and_close, {:respond, "412 Precondition Failed"}])

    assert {:error, :precondition_failed} = AWS.put("cas/unconditional", "body", [])

    Task.await(server, 15_000)
  end

  test "a retried conditional DELETE 412 is ambiguous, a first-attempt 412 is clean", %{
    listener: listener
  } do
    # The 412 classification lives on the NATIVE conditional-delete path
    # (emulate mode never sends If-Match on the DELETE). put_all_env cannot
    # remove a key absent from the saved env, so restore explicitly.
    prev_mode = Application.fetch_env(:salix_store, :s3_conditional_delete)
    Application.put_env(:salix_store, :s3_conditional_delete, :native)

    on_exit(fn ->
      case prev_mode do
        {:ok, value} -> Application.put_env(:salix_store, :s3_conditional_delete, value)
        :error -> Application.delete_env(:salix_store, :s3_conditional_delete)
      end
    end)

    # Same soundness split on the DELETE boundary: attempt 1 may have
    # removed the object, making the retry's 412 our own success echoing
    # back as a conflict.
    server = serve(listener, [:swallow_and_close, {:respond, "412 Precondition Failed"}])

    assert {:error, {:ambiguous, :conditional_retry_412}} =
             AWS.delete("cas/retried-delete", if_match: "\"etag\"")

    Task.await(server, 15_000)

    server = serve(listener, [{:respond, "412 Precondition Failed"}])

    assert {:error, :precondition_failed} =
             AWS.delete("cas/clean-delete", if_match: "\"etag\"")

    Task.await(server, 15_000)
  end
end
