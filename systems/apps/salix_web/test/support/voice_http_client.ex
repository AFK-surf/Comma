defmodule SalixWeb.VoiceHTTPClient do
  @moduledoc false
  use GenServer

  def start(url, owner, key, opts \\ []), do: GenServer.start(__MODULE__, {url, owner, key, opts})
  def upload(pid, frames, opts \\ []), do: GenServer.call(pid, {:upload, frames, opts}, 10_000)
  def reset(pid), do: GenServer.call(pid, :reset)
  def close(pid), do: GenServer.stop(pid)
  def json(map), do: SalixWeb.VoiceHTTP.frame(1, Jason.encode!(map))
  def audio(data), do: SalixWeb.VoiceHTTP.frame(2, data)

  def init({url, owner, key, opts}) do
    uri = URI.parse(url)
    {:ok, conn} = Mint.HTTP.connect(:http, uri.host, uri.port, opts)

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "POST",
        uri.path,
        [
          {"authorization", "Bearer " <> key},
          {"content-type", SalixWeb.VoiceHTTP.content_type()}
        ],
        ""
      )

    {:ok,
     %{
       conn: conn,
       ref: ref,
       owner: owner,
       key: key,
       url: url,
       pending: "",
       ready: nil,
       sequence: 0
     }}
  end

  def handle_call(:reset, _from, state) do
    {:ok, conn} = Mint.HTTP2.cancel_request(state.conn, state.ref)
    {:reply, :ok, %{state | conn: conn}}
  end

  def handle_call({:upload, frames, opts}, _from, state) do
    ready = state.ready

    response =
      Req.request!(
        method: opts[:method] || :post,
        url: state.url <> "/" <> ready["handle"],
        headers: [
          {"authorization", "Bearer " <> (opts[:key] || state.key)},
          {"content-type", SalixWeb.VoiceHTTP.content_type()},
          {"x-voice-node", opts[:node] || ready["node"]},
          {"x-voice-sequence", to_string(Keyword.get(opts, :sequence, state.sequence))}
        ],
        body: IO.iodata_to_binary(frames),
        retry: false
      )

    next = if response.status == 204, do: state.sequence + 1, else: state.sequence
    {:reply, response, %{state | sequence: next}}
  end

  def handle_info(message, state) do
    case Mint.HTTP.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state =
          Enum.reduce(responses, %{state | conn: conn}, fn
            {:data, _, data}, state ->
              decode(%{state | pending: state.pending <> data})

            {:status, _, status}, state ->
              SystemsRuntime.Proc.send(
                state.owner,
                {:http_status, SystemsRuntime.Proc.self(), status}
              )

              state

            {:done, _}, state ->
              SystemsRuntime.Proc.send(state.owner, {:http_closed, SystemsRuntime.Proc.self()})
              state

            _, state ->
              state
          end)

        {:noreply, state}

      {:error, conn, _, _} ->
        {:noreply, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  defp decode(%{pending: <<kind, size::32, rest::binary>>} = state)
       when byte_size(rest) >= size do
    <<payload::binary-size(^size), rest::binary>> = rest

    {event, state} =
      case kind do
        1 ->
          {{:json, Jason.decode!(payload)}, state}

        2 ->
          {{:binary, payload}, state}

        3 ->
          ready = Jason.decode!(payload)
          {{:ready, ready}, %{state | ready: ready}}

        4 ->
          {{:closed, Jason.decode!(payload)}, state}

        5 ->
          {:heartbeat, state}
      end

    SystemsRuntime.Proc.send(state.owner, {:http, SystemsRuntime.Proc.self(), event})
    decode(%{state | pending: rest})
  end

  defp decode(state), do: state

  def terminate(_, state), do: Mint.HTTP.close(state.conn)
end
