defmodule Salix.Bindings.AgentGroupContext do
  @moduledoc false

  @behaviour SalixAgent.GroupContext

  alias Salix.Control.Groups

  @impl true
  def list(tenant_id), do: Groups.list(tenant_id)

  @impl true
  def get(group_id, tenant_id) do
    case Groups.get(group_id, tenant_id) do
      {:ok, group} ->
        {:ok, group}

      {:error, :not_found} ->
        with true <- SalixStore.Ids.valid_group_id_for_tenant?(group_id, tenant_id),
             {:ok, %{"tenant_id" => ^tenant_id, "purpose" => "collaboration"} = group} <-
               Groups.get(group_id) do
          {:ok, group}
        else
          _ -> {:error, :not_found}
        end

      error ->
        error
    end
  end
end
