defmodule SystemsObservability.HTTPPlug do
  @moduledoc "Common bounded HTTP instrumentation for Plug and Phoenix endpoints."
  @behaviour Plug

  @request_state_key {__MODULE__, :request_state}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    discard_request_state()

    state = %{
      started: System.monotonic_time(),
      endpoint: Keyword.get(opts, :endpoint),
      route: safe_route(conn, opts),
      method: conn.method,
      context_token:
        SystemsObservability.Context.attach_surface(surface(Keyword.get(opts, :endpoint)))
    }

    Process.put(@request_state_key, state)

    Plug.Conn.register_before_send(conn, fn conn ->
      complete(conn.status)
      conn
    end)
  rescue
    _exception ->
      discard_request_state()
      handler_failure()
      conn
  catch
    _kind, _reason ->
      discard_request_state()
      handler_failure()
      conn
  end

  @doc false
  def complete(status) do
    case Process.delete(@request_state_key) do
      %{started: started} = state ->
        safe_detach(state.context_token)

        safe_execute(
          %{duration: max(System.monotonic_time() - started, 0)},
          %{
            endpoint: state.endpoint,
            route: state.route,
            method: state.method,
            status: finite_status(status)
          }
        )

      _missing ->
        :ok
    end
  end

  @doc false
  def complete_exception(exception) do
    complete(Plug.Exception.status(exception))
  rescue
    _exception -> complete(500)
  catch
    _kind, _reason -> complete(500)
  end

  defp surface(endpoint) when endpoint in [:bft_dashboard, :bridge_for_teams], do: "bft"
  defp surface(endpoint) when endpoint in [:comma_product_api, :comma_product], do: "comma"
  defp surface(endpoint) when endpoint in [:salix_api, :salix_dashboard], do: "salix"
  defp surface(_), do: "system"

  defp safe_route(conn, opts) do
    resolve_route(conn, opts)
  rescue
    _exception -> "unmatched"
  catch
    _kind, _reason -> "unmatched"
  end

  defp resolve_route(conn, opts) do
    case Keyword.get(opts, :route) do
      route when is_binary(route) ->
        route

      _other ->
        first_matched_route([
          fn -> plug_route(conn) end,
          fn -> phoenix_route(conn) end,
          fn -> resolver_route(conn, Keyword.get(opts, :route_resolver)) end
        ])
    end
  end

  defp plug_route(%{private: %{plug_route: {path, _fun}}}) when is_binary(path), do: path
  defp plug_route(_conn), do: "unmatched"

  defp phoenix_route(%{private: %{phoenix_router: router}} = conn) do
    case apply(Phoenix.Router, :route_info, [router, conn.method, conn.path_info, conn.host]) do
      %{route: route} when is_binary(route) -> route
      _ -> "unmatched"
    end
  end

  defp phoenix_route(_conn), do: "unmatched"

  defp resolver_route(_conn, nil), do: "unmatched"
  defp resolver_route(conn, {module, function}), do: apply(module, function, [conn])

  defp first_matched_route(resolvers) do
    Enum.find_value(resolvers, "unmatched", fn resolver ->
      case resolver.() do
        route when is_binary(route) and route != "unmatched" -> route
        _ -> nil
      end
    end)
  end

  defp finite_status(status) when is_integer(status) and status in 100..599, do: status
  defp finite_status(_status), do: 500

  defp safe_execute(measurements, metadata) do
    :telemetry.execute([:comma_system, :http, :stop], measurements, metadata)
  rescue
    _exception -> handler_failure()
  catch
    _kind, _reason -> handler_failure()
  end

  defp discard_request_state do
    case Process.delete(@request_state_key) do
      %{context_token: token} -> safe_detach(token)
      _missing -> :ok
    end
  end

  defp safe_detach(token) do
    SystemsObservability.Context.detach(token)
  rescue
    _exception -> handler_failure()
  catch
    _kind, _reason -> handler_failure()
  end

  defp handler_failure do
    :telemetry.execute(
      [:systems_observability, :handler, :failure],
      %{},
      %{reason: "invalid_measurement"}
    )

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
