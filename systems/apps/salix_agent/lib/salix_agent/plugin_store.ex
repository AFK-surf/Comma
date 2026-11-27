defmodule SalixAgent.PluginStore do
  @moduledoc """
  Runtime-facing plugin projection port.

  The plugin control-plane lives in the composition/web layer. Agent runtime
  code only asks for the already materialized group projection through this
  behaviour so internal, external, and JavaScript runtimes share one policy
  without `salix_agent` depending on `salix_web`.
  """

  @callback runtime_projection(map()) :: {:ok, map()} | {:error, term()}
  @callback list_definitions(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback list_raw_definitions(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_definition(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback create_definition(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback update_definition(String.t(), String.t(), String.t(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback put_refs(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback list_group_enablements(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback enable_group(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback disable_group(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}

  def runtime_projection(attrs), do: call(:runtime_projection, [attrs])
  def list_definitions(tenant_id, group_id), do: call(:list_definitions, [tenant_id, group_id])

  def list_raw_definitions(tenant_id, group_id),
    do: call(:list_raw_definitions, [tenant_id, group_id])

  def get_definition(tenant_id, group_id, plugin_id),
    do: call(:get_definition, [tenant_id, group_id, plugin_id])

  def create_definition(tenant_id, group_id, attrs),
    do: call(:create_definition, [tenant_id, group_id, attrs])

  def update_definition(tenant_id, group_id, plugin_id, attrs),
    do: call(:update_definition, [tenant_id, group_id, plugin_id, attrs])

  def put_refs(tenant_id, group_id, plugin_id, attrs),
    do: call(:put_refs, [tenant_id, group_id, plugin_id, attrs])

  def list_group_enablements(tenant_id, group_id),
    do: call(:list_group_enablements, [tenant_id, group_id])

  def enable_group(tenant_id, group_id, plugin_id),
    do: call(:enable_group, [tenant_id, group_id, plugin_id])

  def disable_group(tenant_id, group_id, plugin_id),
    do: call(:disable_group, [tenant_id, group_id, plugin_id])

  @doc """
  Fast fail-closed check whether `plugin_id` is enabled for `(tenant_id, group_id)`.

  Delegates to `mod.plugin_enabled?/3` when exported on `:plugin_store_mod`
  (backed by `PluginCatalogCache`), otherwise falls back to `list_group_enablements/2`.
  Always returns `false` on missing configuration or errors.
  """
  @spec enabled?(String.t(), String.t(), String.t()) :: boolean()
  def enabled?(tenant_id, group_id, plugin_id)
      when is_binary(tenant_id) and tenant_id != "" and is_binary(group_id) and group_id != "" and
             is_binary(plugin_id) and plugin_id != "" do
    case SystemsRuntime.get_env(:salix_agent, :plugin_store_mod) do
      nil ->
        false

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :plugin_enabled?, 3) do
          mod.plugin_enabled?(tenant_id, group_id, plugin_id) == true
        else
          case apply(mod, :list_group_enablements, [tenant_id, group_id]) do
            {:ok, enablements} when is_list(enablements) ->
              Enum.any?(enablements, &enablement_matches?(&1, plugin_id))

            _ ->
              false
          end
        end
    end
  rescue
    _ -> false
  end

  def enabled?(_, _, _), do: false

  defp enablement_matches?(entry, plugin_id) when is_map(entry) do
    id =
      Map.get(entry, "plugin_id") || Map.get(entry, :plugin_id) ||
        Map.get(entry, "id") || Map.get(entry, :id)

    enabled = Map.get(entry, "enabled", Map.get(entry, :enabled, false))
    id == plugin_id and enabled == true
  end

  defp enablement_matches?(_, _), do: false

  defp call(fun, args) do
    case SystemsRuntime.get_env(:salix_agent, :plugin_store_mod) do
      nil -> {:error, :plugin_store_not_configured}
      mod -> apply(mod, fun, args)
    end
  end
end
