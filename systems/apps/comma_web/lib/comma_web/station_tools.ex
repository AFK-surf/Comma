defmodule CommaWeb.StationTools do
  require SystemsRuntime.Proc

  @moduledoc """
  Device tool calls over the station's own presence WebSocket (contract §8,
  presence transport). The station already keeps that socket open to Comma,
  so no gateway service, relay or gateway key is needed.

  A call is broadcast on the station's PubSub topic; the one presence socket
  of that station (on any node) pushes a `tool` frame and acknowledges that it
  sent it, then forwards the station's `tool_result` frame. The outcome
  follows contract §9: no acknowledgement means nothing was sent
  (`station_unreachable`); a lost socket or the deadline after sending means
  the op may have run (`station_disconnected`, `timeout`). A call is never
  retried.

  The gateway transport (`CommaWeb.Stations.Gateway`) remains for a later
  switch back (`COMMA_STATION_TOOLS_TRANSPORT=gateway`).
  """

  alias SalixStore.Stations.Events

  @ack_ms 5_000
  @default_ms 60_000
  @op_grace_ms 15_000
  @max_ms 15 * 60_000

  @spec call(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(station_id, %{"id" => id, "args" => args} = request) when is_binary(id) do
    ref = SystemsRuntime.Proc.make_ref()

    message = {:comma_station_tool, ref, SystemsRuntime.Proc.self(), request}

    # One socket takes the call: it is told where that socket listens.
    if CommaWeb.StationPresence.on_earlier_server?(station_id),
      do: Comma.Stations.Window.tell_tool(station_id, message),
      else: Events.tool_request(station_id, message)

    deadline = deadline(args)

    SystemsRuntime.Proc.receive do
      {:comma_station_tool_sent, ^ref} -> await(ref, deadline)
    after
      SystemsRuntime.get_env(:comma_web, :station_tools_ack_ms, @ack_ms) ->
        {:error, {:gateway, "station_unreachable", "the station is not connected"}}
    end
  end

  defp await(ref, deadline) do
    SystemsRuntime.Proc.receive do
      {:comma_station_tool_result, ^ref, %{"ok" => true, "result" => result}}
      when is_map(result) ->
        {:ok, result}

      {:comma_station_tool_result, ^ref, %{"ok" => false, "error" => %{} = error}} ->
        {:error, {:tool, error}}

      {:comma_station_tool_result, ^ref, _other} ->
        {:error, {:gateway, "bad_station_response", "the station sent an unreadable result"}}

      {:comma_station_tool_lost, ^ref} ->
        {:error, {:gateway, "station_disconnected", "the station disconnected during the call"}}
    after
      deadline -> {:error, {:gateway, "timeout", "no answer from the station"}}
    end
  end

  defp deadline(%{"timeout_ms" => ms}) when is_integer(ms) and ms > 0,
    do: min(max(@default_ms, ms + @op_grace_ms), @max_ms)

  defp deadline(_args), do: @default_ms
end
