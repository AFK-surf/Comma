defmodule SystemsObservability.Trace do
  @moduledoc """
  Finite custom span boundary for Comma-owned operations.

  Callers choose a compile-time operation key and may provide only bounded,
  non-identifying attributes. IDs and content belong in the W3C context or
  structured facts, never span names or attributes.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @spans %{
    bft_salix: "bft.salix.call",
    comma_salix: "comma.salix.call",
    salix_session_repair: "salix.session.repair",
    salix_session_activation: "salix.session.activation",
    salix_round_config_build: "salix.round.config.build",
    salix_round_config_prepare: "salix.round.config.prepare",
    salix_round_config: "salix.round.config",
    salix_round_context_providers: "salix.round.context.providers",
    salix_session_get: "salix.session.get",
    salix_session_read: "salix.session.read",
    salix_session_decode: "salix.session.decode",
    salix_round_materialize: "salix.round.materialize",
    salix_round_metering: "salix.round.metering",
    salix_round_admission: "salix.round.admission",
    salix_session_apply: "salix.session.apply",
    salix_session_prepare_write: "salix.session.prepare.write",
    salix_session_prerequisites: "salix.session.prerequisites",
    salix_session_fence_wait: "salix.session.fence.wait",
    salix_session_cleanup: "salix.session.cleanup",
    salix_work_index_write: "salix.work.index.write",
    salix_discovery_write: "salix.discovery.write",
    salix_session_encode: "salix.session.encode",
    salix_session_cas: "salix.session.cas",
    salix_round_conversation: "salix.round.conversation",
    salix_stream_persistence_wait: "salix.stream.persistence.wait",
    salix_llm: "salix.llm.request",
    salix_im_send: "salix.im.send.stage",
    salix_tool: "salix.tool.execute",
    salix_vm: "salix.vm.call",
    triage_recovery: "salix.triage.recovery",
    billing: "billing.operation",
    background_job: "comma.background.job"
  }

  @attribute_keys ~w(component surface operation provider model_key job.kind async.kind)a
  @kinds [:internal, :server, :client]

  def with_span(key, attributes, fun, opts \\ []) when is_function(fun, 0) do
    name = Map.fetch!(@spans, key)
    kind = Keyword.get(opts, :kind, :internal)
    links = Keyword.get(opts, :links, []) |> Enum.reject(&is_nil/1)

    unless kind in @kinds, do: raise(ArgumentError, "unsupported span kind #{inspect(kind)}")

    Tracer.with_span name,
                     %{kind: kind, attributes: sanitize_attributes(attributes), links: links} do
      result = fun.()
      record_result(result)
      result
    end
  end

  defp sanitize_attributes(attributes) do
    attributes
    |> Map.new()
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = normalize_key(key)

      if key in @attribute_keys do
        Map.put(acc, Atom.to_string(key), normalize_value(key, value))
      else
        raise ArgumentError, "forbidden span attribute #{inspect(key)}"
      end
    end)
  end

  def link_from(serialized_context, attributes \\ %{}) do
    context = SystemsObservability.Context.extract(serialized_context)
    span_ctx = OpenTelemetry.Tracer.current_span_ctx(context.otel)
    OpenTelemetry.link(span_ctx, sanitize_attributes(attributes))
  end

  defp record_result({:error, reason}) do
    Tracer.set_status(:error, error_class(reason))
  end

  defp record_result(_), do: :ok

  defp error_class(:timeout), do: "timeout"
  defp error_class(:unavailable), do: "unavailable"
  defp error_class(:rate_limited), do: "rate_limited"
  defp error_class({:error, reason}), do: error_class(reason)
  defp error_class(_), do: "error"

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)

  defp normalize_value(:surface, value), do: SystemsObservability.Classifier.surface(value)
  defp normalize_value(:component, value), do: SystemsObservability.Classifier.component(value)
  defp normalize_value(:provider, value), do: SystemsObservability.Classifier.provider(value)

  defp normalize_value(:operation, value),
    do: SystemsObservability.Classifier.trace_operation(value)

  defp normalize_value(:"job.kind", value), do: SystemsObservability.Classifier.job_kind(value)

  defp normalize_value(:"async.kind", value),
    do: SystemsObservability.Classifier.async_kind(value)

  defp normalize_value(:model_key, value) do
    SystemsObservability.Classifier.model_key(
      value,
      Application.get_env(:systems_observability, :model_keys, [])
    )
  end
end
