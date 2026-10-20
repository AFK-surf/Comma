defmodule SystemsClock.ReqAdapter do
  @moduledoc """
  The Req adapter of the test environment
  (`config :req, default_options: [adapter: &SystemsClock.ReqAdapter.run/1]`):
  an HTTP request's timeouts are measured on `SystemsClock`.

  Under a manual clock, Finch gets no timeout of its own (`SystemsClock.timeout/1`):
  a stub server that answers after clock time, while the clock waits for it,
  is not cut off by real time that passes on a slow machine. The request runs
  under `SystemsClock.run_bounded/2` instead, so it ends with the transport
  error a Finch timeout gives (`%Req.TransportError{reason: :timeout}`) when
  its receive timeout passes on the clock. A streamed response (the
  request's `into`) is read in the caller, whose process state the callback
  may use, with its timeouts on the clock and no bound of its own. On a real clock the request
  runs as Req's own adapter runs it.

  Req is called by name: this application does not depend on it.
  """

  # Finch's receive timeout when the request gives none.
  @receive_timeout 15_000

  @doc "Runs `request` as `Req.Steps.run_finch/1` does, with its timeouts on the clock."
  def run(request) do
    options = request.options
    receive_timeout = Map.get(options, :receive_timeout, @receive_timeout)

    clocked = %{request | options: clocked_options(options)}

    cond do
      Map.get(request, :into) != nil or not is_integer(receive_timeout) or
          SystemsClock.timeout(receive_timeout) == receive_timeout ->
        finch(clocked)

      true ->
        case SystemsClock.run_bounded(fn -> finch(clocked) end, receive_timeout) do
          {:ok, result} ->
            result

          {:exit, {kind, reason}} when kind in [:error, :exit, :throw] ->
            reraise_in_caller(kind, reason)

          {:exit, reason} ->
            exit(reason)

          :timeout ->
            {request, struct(Req.TransportError, reason: :timeout)}
        end
    end
  end

  defp finch(request), do: apply(Req.Steps, :run_finch, [request])

  defp clocked_options(options) do
    options
    |> update_timeout(:receive_timeout)
    |> update_timeout(:pool_timeout)
    |> then(fn options ->
      case options do
        %{connect_options: connect} when is_list(connect) ->
          if Keyword.has_key?(connect, :timeout),
            do: %{options | connect_options: Keyword.update!(connect, :timeout, &timeout/1)},
            else: options

        options ->
          options
      end
    end)
  end

  defp update_timeout(options, key) do
    case options do
      %{^key => value} -> %{options | key => timeout(value)}
      options -> options
    end
  end

  defp timeout(value) when is_integer(value), do: SystemsClock.timeout(value)
  defp timeout(value), do: value

  defp reraise_in_caller(:error, reason), do: :erlang.error(reason)
  defp reraise_in_caller(:exit, reason), do: exit(reason)
  defp reraise_in_caller(:throw, reason), do: throw(reason)
end
