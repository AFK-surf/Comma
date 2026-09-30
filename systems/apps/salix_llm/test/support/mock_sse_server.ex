defmodule SalixLlm.MockSSEServer do
  @moduledoc """
  A tiny Plug impersonating the Anthropic Messages **streaming** API for tests
  (companion to `SalixLlm.MockAnthropic`). It `send_chunked/2`-streams a canned
  SSE body — by default text deltas + a tool_use block + a `message_delta`
  stop_reason — with small sleeps between chunks. Chunk boundaries deliberately
  fall mid-line (`set_body/2` slices the body into fixed-size byte pieces) so
  the client's cross-chunk line buffering is exercised.

  State lives in an Agent so a test can swap the canned body and inspect the
  last decoded request before calling `SalixLlm.Streaming.complete_stream/4`.
  """
  import Plug.Conn

  use Agent

  def start_link(_ \\ []) do
    Agent.start_link(fn -> %{chunks: chop(default_body(), 7)} end, name: __MODULE__)
  end

  @doc "Stream `body`, sliced into `chunk_size`-byte chunks (splits lines mid-way)."
  def set_body(body, chunk_size \\ 7) when is_binary(body) do
    Agent.update(__MODULE__, &Map.put(&1, :chunks, chop(body, chunk_size)))
  end

  @doc """
  Stream explicit chunks verbatim.

  A test may use `{:barrier, chunk, owner, tag}` to hold the server immediately
  after that chunk is written. The owner receives
  `{:mock_sse_barrier, tag, server}` and releases it with
  `{:release_mock_sse_barrier, tag}`.
  """
  def set_chunks(chunks, status \\ 200) when is_list(chunks) do
    Agent.update(__MODULE__, &(&1 |> Map.put(:chunks, chunks) |> Map.put(:status, status)))
  end

  @doc "The decoded JSON body of the most recent request."
  def last_request, do: Agent.get(__MODULE__, & &1[:__last_request__])

  @doc "The default canned SSE body (text deltas + tool_use + stop_reason)."
  def default_body do
    """
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1"}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"there"}}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"echo","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"text\\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"hi\\"}"}}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

    event: message_stop
    data: {"type":"message_stop"}
    """
  end

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, raw, conn} = read_body(conn)
    req = Jason.decode!(raw)
    Agent.update(__MODULE__, &Map.put(&1, :__last_request__, req))
    chunks = Agent.get(__MODULE__, & &1.chunks)
    status = Agent.get(__MODULE__, &Map.get(&1, :status, 200))

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(status)

    Enum.reduce(chunks, conn, &stream_chunk/2)
  end

  defp stream_chunk({:barrier, piece, owner, tag}, conn)
       when is_binary(piece) and is_pid(owner) do
    {:ok, conn} = chunk(conn, piece)
    send(owner, {:mock_sse_barrier, tag, self()})

    receive do
      {:release_mock_sse_barrier, ^tag} -> conn
    after
      5_000 -> conn
    end
  end

  defp stream_chunk(piece, conn) when is_binary(piece) do
    {:ok, conn} = chunk(conn, piece)
    Process.sleep(2)
    conn
  end

  # Slice into fixed-size byte chunks; boundaries intentionally ignore lines.
  defp chop(body, size) when byte_size(body) <= size, do: [body]

  defp chop(body, size) do
    <<piece::binary-size(^size), rest::binary>> = body
    [piece | chop(rest, size)]
  end
end
