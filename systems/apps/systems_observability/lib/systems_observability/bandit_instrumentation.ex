defmodule SystemsObservability.BanditInstrumentation do
  @moduledoc """
  Security boundary around the official Bandit OpenTelemetry handler.

  `opentelemetry_bandit` currently has no option to omit `url.query` and records
  raw exceptions. We still delegate span creation, propagation, HTTP semantic
  conventions and completion to the official handler, but own the single
  Telemetry registration so unsafe inputs are removed deterministically before
  that handler observes them.
  """

  @upstream_handler :comma_bandit_upstream_config
  @upstream_id {OpentelemetryBandit, @upstream_handler}
  @handler_id {__MODULE__, :request}
  @events [
    [:bandit, :request, :start],
    [:bandit, :request, :stop],
    [:bandit, :request, :exception]
  ]
  @propagation_headers ~w(traceparent tracestate)

  defmodule ConstantPeerAdapter do
    @moduledoc false

    @peer_data %{address: {0, 0, 0, 0}, port: 0, ssl_cert: nil}

    def get_peer_data(_wrapped_adapter), do: @peer_data

    def get_http_protocol({adapter, payload}) do
      adapter.get_http_protocol(payload)
    end
  end

  def setup do
    if handler_attached?(@handler_id) do
      {:error, :already_exists}
    else
      :telemetry.detach(@upstream_id)

      with :ok <- OpentelemetryBandit.setup(handler_id: @upstream_handler) do
        result =
          case upstream_config() do
            {:ok, config} ->
              :telemetry.attach_many(
                @handler_id,
                @events,
                &__MODULE__.handle_event/4,
                config
              )

            error ->
              error
          end

        # Never leave the content-bearing upstream handler installed, including
        # when config discovery or safe-handler registration fails.
        :telemetry.detach(@upstream_id)
        result
      end
    end
  end

  @doc false
  def handle_event([:bandit, :request, :stop] = event, measurements, metadata, config) do
    SystemsObservability.HTTPPlug.complete(metadata[:conn] && metadata.conn.status)
    delegate(event, measurements, metadata, config)
  end

  def handle_event([:bandit, :request, :exception] = event, measurements, metadata, config) do
    SystemsObservability.HTTPPlug.complete_exception(metadata[:exception])
    delegate(event, measurements, metadata, config)
  end

  def handle_event(event, measurements, metadata, config) do
    delegate(event, measurements, metadata, config)
  end

  defp delegate(event, measurements, metadata, config) do
    OpentelemetryBandit.handle_request(event, measurements, sanitize(event, metadata), config)
  rescue
    _exception -> handler_failure()
  catch
    _kind, _reason -> handler_failure()
  end

  @doc false
  def sanitize([:bandit, :request, :start], %{conn: conn} = metadata) do
    safe_headers =
      Enum.filter(conn.req_headers, fn {name, _value} -> name in @propagation_headers end)

    %{
      metadata
      | conn: %{
          conn
          | adapter: {ConstantPeerAdapter, conn.adapter},
            host: "",
            path_info: [],
            request_path: "",
            query_string: "",
            req_headers: safe_headers
        }
    }
  end

  def sanitize([:bandit, :request, :stop], %{error: _error} = metadata) do
    %{metadata | error: "request_error"}
  end

  def sanitize([:bandit, :request, :exception], metadata) do
    metadata
    |> Map.put(:exception, RuntimeError.exception("request failed"))
    |> Map.put(:stacktrace, [])
  end

  def sanitize(_event, metadata), do: metadata

  defp upstream_config do
    case Enum.find(:telemetry.list_handlers([:bandit, :request, :start]), fn handler ->
           handler.id == @upstream_id
         end) do
      %{config: config} -> {:ok, config}
      nil -> {:error, :upstream_handler_not_found}
    end
  end

  defp handler_attached?(id) do
    Enum.any?(:telemetry.list_handlers([:bandit, :request, :start]), &(&1.id == id))
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
