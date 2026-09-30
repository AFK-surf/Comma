defmodule SystemsObservability.Resource do
  @moduledoc "Runtime resource identity. Surface is deliberately absent."

  def identity(env \\ System.get_env()) do
    %{
      environment: normalize_environment(env["COMMA_ENVIRONMENT"] || env["MIX_ENV"]),
      cluster: value(env["COMMA_CLUSTER"]),
      workload: value(env["COMMA_WORKLOAD"]),
      pod: value(env["POD_NAME"]),
      revision: value(env["COMMA_REVISION"])
    }
  end

  def otel_resource(identity \\ identity()) do
    %{
      service: %{
        name: identity.workload,
        version: identity.revision,
        instance: %{id: identity.pod}
      },
      deployment: %{environment: %{name: identity.environment}},
      k8s: %{cluster: %{name: identity.cluster}, pod: %{name: identity.pod}}
    }
  end

  def put_current(identity \\ identity()) do
    :persistent_term.put({__MODULE__, :identity}, identity)
    identity
  end

  def current do
    case :persistent_term.get({__MODULE__, :identity}, nil) do
      nil -> identity()
      identity -> identity
    end
  end

  defp normalize_environment(value) when value in ["staging", :staging], do: "staging"

  defp normalize_environment(value) when value in ["production", "prod", :production, :prod],
    do: "production"

  defp normalize_environment(_value), do: "development"
  defp value(value) when is_binary(value) and value != "", do: value
  defp value(_value), do: "unknown"
end
