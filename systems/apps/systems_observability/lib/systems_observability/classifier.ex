defmodule SystemsObservability.Classifier do
  @moduledoc "Finite classifiers for all metric labels."

  # Product surfaces, the internal delivery writers that name themselves
  # (`Salix.Telemetry.normalize_surface/1` is the metric-side twin, #928),
  # and the `system` fallback for a caller that set none.
  @surfaces ~w(bft comma salix schedule timer auto_title system)
  @components ~w(bridge_for_teams comma_product salix_agent salix_llm salix_im salix_mcp salix_store salix_cluster billing)
  @endpoints ~w(bft_dashboard comma_product_api salix_api)
  @providers ~w(openai anthropic sprites cloudflare)
  @outcomes ~w(ok error timeout unavailable conflict rejected cancelled)
  @error_classes ~w(none validation auth rate_limited timeout unavailable conflict provider storage internal)
  @repos ~w(bft billing comma salix)
  @trace_operations ~w(im_send_total im_send_authorize im_send_conversation im_send_attachments im_send_participant im_send_placement im_send_call im_send_queue im_send_actor im_send_membership im_send_sender im_send_sender_fence im_send_prepare im_send_commit im_send_delivery im_send_result erpc.receive erpc.call charge authorize request execute provision archive provider_request salix_boundary deliver triage_recovery)
  @job_kinds ~w(tool_completion)
  @async_kinds ~w(tool_completion)

  @application_components %{
    bridge_for_teams_core: "bridge_for_teams",
    bridge_for_teams_web: "bridge_for_teams",
    comma_core: "comma_product",
    comma_web: "comma_product",
    salix_agent: "salix_agent",
    salix_cluster: "salix_cluster",
    salix_im: "salix_im",
    salix_llm: "salix_llm",
    salix_mcp: "salix_mcp",
    salix_store: "salix_store",
    billing_commerce: "billing",
    billing_core: "billing",
    billing_stripe: "billing"
  }

  def surface(value), do: finite(value, @surfaces)
  def component(value), do: finite(value, @components)
  def endpoint(value), do: finite(value, @endpoints)
  def provider(value), do: finite(value, @providers)
  def outcome(value), do: finite(value, @outcomes)
  def error_class(value), do: finite(value, @error_classes)
  def repo(value), do: finite(value, @repos)
  def trace_operation(value), do: finite(value, @trace_operations)
  def job_kind(value), do: finite(value, @job_kinds)
  def async_kind(value), do: finite(value, @async_kinds)

  @doc "Returns the bounded component owned by an OTP application, for log attribution."
  def component_for_application(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
    |> component_for_application()
  rescue
    ArgumentError -> "other"
  end

  def component_for_application(value) when is_atom(value) do
    @application_components
    |> Map.get(value)
    |> component()
  end

  def component_for_application(_value), do: "other"

  def method(value) do
    value
    |> normalize()
    |> then(
      &if(&1 in ~w(get post put patch delete options head), do: String.upcase(&1), else: "OTHER")
    )
  end

  def status_class(value) when is_integer(value) and value >= 100 and value <= 599,
    do: "#{div(value, 100)}xx"

  def status_class(_value), do: "other"

  def route_template(endpoint, value),
    do: SystemsObservability.RouteCatalog.classify(endpoint(endpoint), value)

  def model_key(value, configured_keys) when is_list(configured_keys) do
    normalized = normalize(value)
    allowed = configured_keys |> Enum.take(7) |> Enum.map(&normalize/1)
    if normalized in allowed, do: normalized, else: "other"
  end

  defp finite(value, values) do
    normalized = normalize(value)
    if normalized in values, do: normalized, else: "other"
  end

  defp normalize(value) when is_atom(value), do: value |> Atom.to_string() |> normalize()

  defp normalize(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize(_value), do: ""
end
