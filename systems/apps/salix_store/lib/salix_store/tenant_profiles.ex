defmodule SalixStore.TenantProfiles do
  @moduledoc """
  Product-owned profile of a Salix Tenant, stored as the `product_profile`
  tenant config record.

  A `router_only` Tenant admits only Router agents with the guest Router
  purpose and no Cloud VM. Once set, `router_only` cannot be removed, so an
  agent created under the profile never outlives it. The optional
  `dependency_max_children` value overrides the per-node, per-Tenant
  dependency admission limit for that Tenant.
  """

  import Ecto.Query

  alias SalixStore.{Repo, TenantConfigs}

  @name "product_profile"
  @guest_router_purpose "comma_guest_router"
  @max_dependency_children 512
  @limit_page 100

  def guest_router_purpose, do: @guest_router_purpose

  @spec get(String.t()) :: map()
  def get(tenant_id) when is_binary(tenant_id) do
    case TenantConfigs.get(tenant_id, @name) do
      {:ok, %{"value" => value}} when is_map(value) -> value
      {:ok, _record} -> %{}
      {:error, :not_found} -> %{}
    end
  end

  @spec router_only?(String.t() | nil) :: boolean()
  def router_only?(tenant_id) when is_binary(tenant_id) and tenant_id != "",
    do: get(tenant_id)["router_only"] == true

  def router_only?(_tenant_id), do: false

  @doc "Mark a Tenant router-only and set its dependency admission limit."
  @spec put_router_only(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def put_router_only(tenant_id, dependency_max_children)
      when is_binary(tenant_id) and is_integer(dependency_max_children) and
             dependency_max_children in 1..@max_dependency_children do
    value = %{
      "router_only" => true,
      "dependency_max_children" => dependency_max_children
    }

    {:ok, _record} =
      TenantConfigs.put(%{
        "tenant_id" => tenant_id,
        "name" => @name,
        "value" => value,
        "updated_at" => System.system_time(:second)
      })

    {:ok, value}
  end

  def put_router_only(_tenant_id, _limit), do: {:error, :invalid_tenant_profile}

  @doc "Bounded map of Tenant id to its dependency admission override."
  @spec dependency_limits() :: %{String.t() => pos_integer()}
  def dependency_limits do
    from(row in TenantConfigs.Row,
      where: row.name == @name,
      order_by: [desc: row.updated_at],
      limit: @limit_page,
      select: {row.tenant_id, row.value}
    )
    |> Repo.all()
    |> Enum.flat_map(fn
      {tenant_id, %{"dependency_max_children" => limit}}
      when is_integer(limit) and limit in 1..@max_dependency_children ->
        [{tenant_id, limit}]

      _other ->
        []
    end)
    |> Map.new()
  end
end
