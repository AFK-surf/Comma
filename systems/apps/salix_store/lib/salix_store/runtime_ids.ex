defmodule SalixStore.RuntimeIds do
  @moduledoc """
  Pure runtime/session identifiers shared across Salix apps.

  The owner app decides when an id is valid to use; this module only defines the
  canonical deterministic id shape so IM, agent runtime, and dashboard links do
  not carry parallel hash implementations.
  """

  @external_runtime_providers ~w(codex pi kimi claude)

  @spec external_runtime_providers() :: [String.t()]
  def external_runtime_providers, do: @external_runtime_providers

  @spec external_runtime_provider?(term()) :: boolean()
  def external_runtime_provider?(provider), do: provider in @external_runtime_providers

  @spec runtime_id(String.t()) :: String.t()
  def runtime_id(identity_material) when is_binary(identity_material) do
    identity_material
    |> trim_identity_material()
    |> hash()
  end

  @spec device_runtime_id(String.t(), String.t(), String.t()) :: String.t()
  def device_runtime_id(device_id, provider, runtime_id)
      when is_binary(device_id) and is_binary(provider) and is_binary(runtime_id) do
    hash(device_id <> ":" <> provider <> ":" <> runtime_id)
  end

  @spec device_environment_id(String.t(), String.t(), String.t()) :: String.t()
  def device_environment_id(device_id, provider, environment_runtime_id)
      when is_binary(device_id) and is_binary(provider) and is_binary(environment_runtime_id) do
    hash(device_id <> ":" <> provider <> ":" <> environment_runtime_id)
  end

  @spec cloud_vm_env_id(String.t()) :: String.t()
  def cloud_vm_env_id(group_id), do: "cloudvm-" <> cloud_vm_group_hash(group_id)

  @spec cloud_vm_device_id(String.t()) :: String.t()
  def cloud_vm_device_id(group_id), do: "dev-cloudvm-" <> cloud_vm_group_hash(group_id)

  @spec cloud_vm_connector_id(String.t()) :: String.t()
  def cloud_vm_connector_id(group_id), do: "conn-cloudvm-" <> cloud_vm_group_hash(group_id)

  @spec cloud_vm_provider_resource_name(String.t()) :: String.t()
  def cloud_vm_provider_resource_name(group_id), do: "salix-" <> cloud_vm_group_hash(group_id)

  @doc """
  Trim connector-owned Codex identity material without interpreting it on the
  server host.

  The connector reports the discovered entry path without resolving symbolic
  links. Salix keeps that material opaque except for trimming. Server-side path
  expansion would use the server's cwd/HOME and can corrupt identity for another
  machine.
  """
  @spec trim_identity_material(String.t()) :: String.t()
  def trim_identity_material(path) when is_binary(path), do: String.trim(path)

  @spec persisted_router_session_id(map()) :: {:ok, String.t()} | {:error, atom()}
  def persisted_router_session_id(%{"role" => "router", "router_session_id" => session_id})
      when is_binary(session_id) do
    case String.trim(session_id) do
      "" ->
        {:error, :router_session_id_required}

      session_id ->
        if SalixStore.Ids.valid_session_id?(session_id) do
          {:ok, session_id}
        else
          {:error, :invalid_router_session_id}
        end
    end
  end

  def persisted_router_session_id(%{"role" => "router"}),
    do: {:error, :router_session_id_required}

  def persisted_router_session_id(_agent), do: {:error, :not_router_agent}

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp cloud_vm_group_hash(group_id), do: hash("cloud-vm:" <> group_id) |> binary_part(0, 16)
end
