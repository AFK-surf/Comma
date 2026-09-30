defmodule SystemsObservability.Context do
  @moduledoc """
  Bounded observability context shared by metrics, traces, and logs.

  Local process propagation carries the OTel context plus the finite product
  surface and an opaque, non-business correlation id. Serialized propagation is
  deliberately limited to W3C Trace Context and those two safe fields.
  """

  alias OpenTelemetry.Ctx

  @surface_key {__MODULE__, :surface}
  @correlation_key {__MODULE__, :correlation_id}
  @serialized_keys ~w(traceparent tracestate surface correlation_id)

  @type local :: %{otel: Ctx.t(), surface: String.t(), correlation_id: String.t()}

  def current_surface do
    Ctx.get_value(@surface_key, "system")
    |> SystemsObservability.Classifier.surface()
  end

  defp correlation_id do
    case Ctx.get_value(@correlation_key, nil) do
      value when is_binary(value) and byte_size(value) in 1..64 -> value
      _ -> new_correlation_id()
    end
  end

  def with_surface(surface, fun) when is_function(fun, 0) do
    surface = SystemsObservability.Classifier.surface(surface)
    correlation_id = correlation_id()

    context = %{
      otel:
        Ctx.get_current()
        |> Ctx.set_value(@surface_key, surface)
        |> Ctx.set_value(@correlation_key, correlation_id),
      surface: surface,
      correlation_id: correlation_id
    }

    token = attach(context)

    try do
      fun.()
    after
      detach(token)
    end
  end

  @spec capture() :: local()
  def capture do
    %{
      otel: Ctx.get_current(),
      surface: current_surface(),
      correlation_id: correlation_id()
    }
  end

  @doc false
  def attach_surface(surface) do
    capture()
    |> Map.put(:surface, normalize_surface(surface))
    |> attach()
  end

  defp attach(%{otel: otel} = context) do
    surface = normalize_surface(context[:surface])
    correlation_id = normalize_correlation(context[:correlation_id])
    logger_metadata = Logger.metadata()
    Logger.metadata(surface: surface, correlation_id: correlation_id)

    otel_token =
      otel
      |> Ctx.set_value(@surface_key, surface)
      |> Ctx.set_value(@correlation_key, correlation_id)
      |> Ctx.attach()

    {otel_token, logger_metadata}
  end

  @doc false
  def detach({otel_token, logger_metadata}) do
    Ctx.detach(otel_token)
    Logger.reset_metadata(logger_metadata)
  end

  def run(context, fun) when is_function(fun, 0) do
    token = attach(context)

    try do
      fun.()
    after
      detach(token)
    end
  end

  @doc "Serialize the narrow cross-runtime contract; no baggage is propagated."
  def inject(context \\ capture()) do
    carrier =
      :otel_propagator_text_map.inject_from(
        context.otel,
        :otel_propagator_trace_context,
        []
      )
      |> Map.new()

    carrier
    |> Map.put("surface", normalize_surface(context.surface))
    |> Map.put("correlation_id", normalize_correlation(context.correlation_id))
  end

  @doc "Extract a serialized contract without attaching it to the caller."
  def extract(carrier) when is_map(carrier) do
    safe =
      Enum.flat_map(@serialized_keys, fn key ->
        case Map.get(carrier, key) || Map.get(carrier, String.to_atom(key)) do
          nil -> []
          value -> [{key, to_string(value)}]
        end
      end)

    otel =
      :otel_propagator_text_map.extract_to(
        Ctx.new(),
        :otel_propagator_trace_context,
        safe
      )

    %{
      otel: otel,
      surface: normalize_surface(value(safe, "surface")),
      correlation_id: normalize_correlation(value(safe, "correlation_id"))
    }
  end

  def extract(_), do: %{otel: Ctx.new(), surface: "system", correlation_id: new_correlation_id()}

  defp normalize_surface(value), do: SystemsObservability.Classifier.surface(value || "system")

  defp normalize_correlation(value) when is_binary(value) and byte_size(value) in 1..64 do
    if String.match?(value, ~r/\A[A-Za-z0-9_-]+\z/), do: value, else: new_correlation_id()
  end

  defp normalize_correlation(_), do: new_correlation_id()
  defp new_correlation_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  defp value(carrier, key), do: carrier |> List.keyfind(key, 0, {key, nil}) |> elem(1)
end
