defmodule SalixWeb.VoiceHTTP do
  require SystemsRuntime.Proc

  @moduledoc """
  HTTPS carrier for comma.voice.v1. The streaming request owns the existing
  VoiceSocket session state. Short uploads reach that process on its original
  node. A handle locates a transport, and never grants access to a call.
  """
  import Plug.Conn
  alias SalixWeb.VoiceSocket

  @registry SalixWeb.VoiceHTTP.Registry
  @content_type "application/x-comma-voice"
  @max_batch 32 * 1024
  @max_frame 16 * 1024

  def content_type, do: @content_type

  @doc """
  Whether `conn` continues an open stream: an upload or its hang-up. It is
  routed to the owner even while this pod drains, like a frame on an open
  WebSocket.
  """
  def continuation?(%Plug.Conn{method: method, request_path: path}),
    do:
      method in ["POST", "DELETE"] and
        Regex.match?(~r"^/v1/agent-groups/[^/]+/voice/http/[0-9a-f]{32}$", path)

  def stream(conn, args) do
    handle = Base.encode16(SystemsRuntime.Proc.random_bytes(16), case: :lower)
    gate = SystemsRuntime.Atomics.new(1, signed: false)
    scope = {args.group_id, args.key["key_hash"]}
    {:ok, _} = SystemsRuntime.Registry.register(@registry, handle, {scope, gate})

    conn =
      conn
      |> put_resp_content_type(@content_type)
      |> put_resp_header("cache-control", "no-store, no-transform")
      |> put_resp_header("x-accel-buffering", "no")

    # An HTTP/1 request reuses its connection process. Close that connection
    # after the stream so session timers cannot reach a later request. HTTP/2
    # already owns a separate process for each stream.
    conn =
      if get_http_protocol(conn) == :"HTTP/2",
        do: conn,
        else: put_resp_header(conn, "connection", "close")

    try do
      conn = send_chunked(conn, 200)
      ready = Jason.encode!(%{handle: handle, node: node_token(node())})

      case chunk(conn, frame(3, ready)) do
        {:ok, conn} -> run(conn, VoiceSocket.init(args), gate, 0)
        {:error, _} -> conn
      end
    after
      if state = Process.delete({__MODULE__, :state}), do: VoiceSocket.terminate(:normal, state)
      SystemsRuntime.Registry.unregister(@registry, handle)
    end
  end

  # The hash comes from the initial authenticated key record. Continuations
  # prove possession of that same bearer without a database read per packet.
  def dispatch(owner, handle, scope, command) do
    target = Enum.find([node() | Node.list()], &Plug.Crypto.secure_compare(node_token(&1), owner))

    cond do
      is_nil(target) -> {:error, 503}
      target == node() -> deliver(handle, scope, command)
      true -> :erpc.call(target, __MODULE__, :deliver, [handle, scope, command], 4_000)
    end
  catch
    _, _ -> {:error, 503}
  end

  @doc false
  def deliver(handle, {group_id, hash}, command) do
    case SystemsRuntime.Registry.lookup(@registry, handle) do
      [{pid, {{^group_id, expected}, gate}}] ->
        cond do
          not Plug.Crypto.secure_compare(hash, expected) ->
            {:error, 404}

          # A hang-up must not wait for the gate: an upload the client
          # cancelled may still hold it.
          command == :close ->
            SystemsClock.call(pid, {:voice_http, :close}, 3_000)

          SystemsRuntime.Atomics.compare_exchange(gate, 1, 0, 1) == :ok ->
            # Only the stream releases the lock. An RPC timeout does not cancel
            # an accepted upload, and must not admit a second queued upload.
            SystemsClock.call(pid, {:voice_http, command}, 3_000)

          true ->
            {:error, 409}
        end

      _ ->
        {:error, 404}
    end
  catch
    :exit, _ -> {:error, 503}
  end

  # Locates the owner node without telling clients its name, which carries the
  # pod address. Nodes of one cluster share the cookie.
  defp node_token(node) do
    :crypto.mac(:hmac, :sha256, Atom.to_string(:erlang.get_cookie()), Atom.to_string(node))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  def decode(body) when byte_size(body) <= @max_batch, do: decode_frames(body, [])
  def decode(_), do: {:error, :bad_frame}

  defp decode_frames(<<>>, []), do: {:error, :bad_frame}
  defp decode_frames(<<>>, frames), do: {:ok, Enum.reverse(frames)}

  defp decode_frames(<<kind, size::unsigned-big-32, rest::binary>>, frames)
       when kind in [1, 2] and size <= @max_frame and byte_size(rest) >= size do
    <<payload::binary-size(^size), rest::binary>> = rest
    opcode = if kind == 1, do: :text, else: :binary
    decode_frames(rest, [{payload, [opcode: opcode]} | frames])
  end

  defp decode_frames(_, _), do: {:error, :bad_frame}

  def frame(kind, payload), do: <<kind, byte_size(payload)::unsigned-big-32, payload::binary>>

  defp run(conn, {:ok, state}, gate, sequence) do
    Process.put({__MODULE__, :state}, state)

    SystemsRuntime.Proc.receive do
      {:"$gen_call", from, {:voice_http, {:upload, ^sequence, frames}}} ->
        result =
          Enum.reduce_while(frames, {:ok, conn, state}, fn input, {:ok, conn, state} ->
            case write_result(conn, VoiceSocket.handle_in(input, state)) do
              {:ok, conn, state} -> {:cont, {:ok, conn, state}}
              stopped -> {:halt, stopped}
            end
          end)

        SystemsRuntime.Atomics.put(gate, 1, 0)
        GenServer.reply(from, :ok)

        case result do
          {:ok, conn, state} ->
            result = VoiceSocket.handle_control({"", [opcode: :pong]}, state)
            run(conn, result, gate, sequence + 1)

          {:closed, conn, state} ->
            finish(conn, state)
        end

      {:"$gen_call", from, {:voice_http, {:upload, _, _}}} ->
        SystemsRuntime.Atomics.put(gate, 1, 0)
        GenServer.reply(from, {:error, 409})
        run(conn, {:ok, state}, gate, sequence)

      {:"$gen_call", from, {:voice_http, :close}} ->
        GenServer.reply(from, :ok)
        conn

      # Bandit owns its stream-window and reset messages. Leave those in the
      # mailbox for the adapter instead of swallowing them as session events.
      message
      when is_atom(message) or
             (is_tuple(message) and elem(message, 0) in [:voice_call, :DOWN]) ->
        run(conn, VoiceSocket.handle_info(message, state), gate, sequence)
    end
  end

  defp run(conn, result, gate, sequence) do
    case write_result(conn, result) do
      {:ok, conn, state} -> run(conn, {:ok, state}, gate, sequence)
      {:closed, conn, state} -> finish(conn, state)
    end
  end

  defp finish(conn, state) do
    Process.put({__MODULE__, :state}, state)
    conn
  end

  defp write_result(conn, {:ok, state}), do: {:ok, conn, state}

  defp write_result(conn, {:push, frames, state}) do
    Process.put({__MODULE__, :state}, state)

    case write_frames(conn, List.wrap(frames)) do
      {:ok, conn} -> {:ok, conn, state}
      {:error, _} -> {:closed, conn, state}
    end
  end

  defp write_result(conn, {:stop, reason, close, state}),
    do: write_result(conn, {:stop, reason, close, [], state})

  defp write_result(conn, {:stop, _, {code, reason}, frames, state}) do
    Process.put({__MODULE__, :state}, state)

    conn =
      case write_frames(conn, List.wrap(frames)) do
        {:ok, conn} ->
          case chunk(conn, frame(4, Jason.encode!(%{code: code, reason: reason}))) do
            {:ok, conn} -> conn
            {:error, _} -> conn
          end

        {:error, _} ->
          conn
      end

    {:closed, conn, state}
  end

  defp write_frames(conn, frames) do
    Enum.reduce_while(frames, {:ok, conn}, fn {opcode, data}, {:ok, conn} ->
      kind =
        case opcode do
          :text -> 1
          :binary -> 2
          :ping -> 5
        end

      case chunk(conn, frame(kind, IO.iodata_to_binary(data))) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
