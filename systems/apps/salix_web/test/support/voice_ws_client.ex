defmodule SalixWeb.VoiceWsClient do
  @moduledoc false
  # WebSocket test client for the voice sockets. Every frame and the final
  # disconnect go to the owner as `{:ws, self(), frame}` and
  # `{:ws_closed, self(), close}`. With `auto_played: true` it answers each
  # `output.mark` with `output.played`, as a comma.voice.v1 player does.

  use WebSockex

  def start(url, owner, opts \\ []) do
    state = %{owner: owner, auto_played: Keyword.get(opts, :auto_played, false)}

    WebSockex.start(url, __MODULE__, state,
      extra_headers: Keyword.get(opts, :headers, []),
      handle_initial_conn_failure: true
    )
  end

  def send_json(client, map), do: WebSockex.send_frame(client, {:text, Jason.encode!(map)})
  def send_binary(client, data), do: WebSockex.send_frame(client, {:binary, data})

  @doc "Closes the socket from the client side (close 1000)."
  def close(client), do: WebSockex.cast(client, :close)

  @impl true
  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_frame({:text, text}, state) do
    message = Jason.decode!(text)
    send(state.owner, {:ws, self(), {:json, message}})

    if state.auto_played and message["type"] == "output.mark" do
      reply = Jason.encode!(%{"type" => "output.played", "name" => message["name"]})
      {:reply, {:text, reply}, state}
    else
      {:ok, state}
    end
  end

  def handle_frame({:binary, data}, state) do
    send(state.owner, {:ws, self(), {:binary, data}})
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    close =
      case reason do
        {:remote, code, message} -> {code, message}
        {:remote, :closed} -> :closed
        other -> other
      end

    send(state.owner, {:ws_closed, self(), close})
    {:ok, state}
  end
end
