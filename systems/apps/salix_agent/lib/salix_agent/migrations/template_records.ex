defmodule SalixAgent.Migrations.TemplateRecords do
  @moduledoc """
  Read-only access to the template records and default pointers that earlier
  releases stored, for the migrations that convert them
  (`AgentCreationDefaults`, `AgentModelChoices`, `PlatformModels`,
  `TemplatePinChoices`, `OrgModelChoices`). Nothing else reads them.

  Storage: global templates under `ctl/templates/`, a Tenant's private
  templates under `ctl/tenant_templates/<tenant>/`, platform default pointers
  in `ctl/system/agent_defaults.json`, and a Tenant's creation pointers in the
  `agent_defaults` section of its record config.
  """

  alias SalixStore.{Ids, Keys, S3}

  @fields %{"router" => "router_template_id", "worker" => "worker_template_id"}

  @doc """
  A stored template: a global one (`tenant_id` nil) or a Tenant-private one
  (`ptm1_` ids) of `tenant_id`. `{:error, :not_found}` when it is absent or
  belongs to another owner.
  """
  @spec get(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def get(id, tenant_id \\ nil)

  def get("ptm1_" <> _ = id, tenant_id) do
    if Ids.valid_private_template_id?(id) and Ids.valid_tenant_id?(tenant_id),
      do: read_owned(Keys.ctl_private_template(tenant_id, id), id, tenant_id),
      else: {:error, :not_found}
  end

  def get(id, _tenant_id) when is_binary(id) and id != "",
    do: read_owned(Keys.ctl_template(id), id, nil)

  def get(_id, _tenant_id), do: {:error, :not_found}

  @doc """
  The Tenant's Custom Profile that `SalixAgent.Migrations.TemplatePinChoices`
  made for an own-endpoint template: an API-key Custom Profile with the
  template's name (`custom_profile_name/1`) that lists its model.
  """
  @spec custom_profile(String.t(), map()) :: {:ok, String.t()} | :none | {:error, term()}
  def custom_profile(tenant_id, template) do
    case SalixAgent.SubscriptionStore.query(
           """
           SELECT id FROM subscription_accounts
           WHERE tenant_id=$1 AND value->>'credential'='api_key' AND value->>'source'='custom'
             AND value->>'name'=$2 AND value->'models' ? $3
           ORDER BY id LIMIT 1
           """,
           [tenant_id, custom_profile_name(template), template["model"]]
         ) do
      {:ok, %{rows: [[id]]}} -> {:ok, id}
      {:ok, %{rows: []}} -> :none
      {:error, _} = error -> error
    end
  end

  @doc "The name of the Custom Profile made for an own-endpoint template."
  @spec custom_profile_name(map()) :: String.t()
  def custom_profile_name(template) do
    name = template["name"] || template["model"]

    if is_binary(name) and String.trim(name) != "",
      do: String.slice(String.trim(name), 0, 80),
      else: "Custom"
  end

  @doc "The global template with this name, or nil."
  @spec named(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def named(name) do
    with {:ok, objects} <- S3.list_all(Keys.ctl_templates_prefix()) do
      Enum.reduce_while(objects, {:ok, nil}, fn %{key: key}, acc ->
        case read(key) do
          {:ok, %{"name" => ^name} = template} -> {:halt, {:ok, template}}
          {:ok, _other} -> {:cont, acc}
          {:error, :not_found} -> {:cont, acc}
          {:error, %Jason.DecodeError{}} -> {:cont, acc}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc "The platform default template id of a role (`router`, `worker`), or nil."
  @spec platform_default(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def platform_default(role) do
    case read(Keys.ctl_system_agent_defaults()) do
      {:ok, defaults} -> {:ok, present(defaults[@fields[role]])}
      {:error, :not_found} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  @doc "The template id a Tenant copied to its new Agents of a role, or nil."
  @spec tenant_default(String.t(), String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def tenant_default(role, tenant_id) when is_map_key(@fields, role) and is_binary(tenant_id) do
    case read(Keys.ctl_tenant(tenant_id)) do
      {:ok, record} ->
        case decode_config(record["config"]) do
          %{"agent_defaults" => %{} = defaults} -> {:ok, present(defaults[@fields[role]])}
          _ -> {:ok, nil}
        end

      {:error, :not_found} ->
        {:ok, nil}

      {:error, _} = error ->
        error
    end
  end

  def tenant_default(_role, _tenant_id), do: {:ok, nil}

  defp read_owned(key, id, tenant_id) do
    case read(key) do
      {:ok, %{"template_id" => ^id} = template} ->
        if template["tenant_id"] == tenant_id, do: {:ok, template}, else: {:error, :not_found}

      {:ok, _other} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  defp read(key) do
    with {:ok, %{body: body}} <- S3.get(key),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      {:ok, map}
    else
      {:ok, _not_a_map} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp decode_config(config) when is_map(config), do: config

  defp decode_config(config) when is_binary(config) and config != "" do
    case Jason.decode(config) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_config(_config), do: %{}

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil
end
