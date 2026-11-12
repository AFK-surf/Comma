defmodule SalixWeb.Dashboard.RoutingStorageTest do
  use SystemsClock.Case, async: false
  alias Salix.Control.{Groups, Store, Tenants}

  setup do
    {:ok, tenant} = Tenants.create(%{"name" => "Routing storage test"})
    {:ok, group} = Groups.create(%{"name" => "Routing storage test"}, tenant["tenant_id"])
    %{tenant: tenant["tenant_id"], group: group["group_id"]}
  end

  defp policy(revision),
    do: %{
      "mode" => "routes",
      "schema_version" => 2,
      "revision" => revision,
      "enabled" => true,
      "entries" => []
    }

  test "route saves reject stale and cross-tenant editors while preserving unrelated edits", %{
    tenant: tenant,
    group: id
  } do
    first = policy("first")
    {:ok, _} = Groups.update_task_model_selection(id, tenant, nil, first)
    {:ok, _} = Groups.update(id, %{"name" => "Other editor"}, tenant)
    {:ok, saved} = Groups.update_task_model_selection(id, tenant, first, policy("second"))
    assert saved["name"] == "Other editor"
    assert {:error, _} = Groups.update_task_model_selection(id, tenant, first, policy("stale"))
    {:ok, other} = Tenants.create(%{"name" => "Other tenant"})

    assert {:error, _} =
             Groups.update_task_model_selection(
               id,
               other["tenant_id"],
               saved["task_model_selection"],
               policy("forbidden")
             )

    assert {:ok, ^saved} = Groups.get(id, tenant)
  end

  test "an ETag conflict rechecks the expected routing instead of overwriting the winning edit",
       %{tenant: tenant, group: id} do
    first = policy("first")
    winner = policy("winner")
    {:ok, _} = Groups.update_task_model_selection(id, tenant, nil, first)

    assert {:error, :stale} =
             Store.update_record_checked(SalixStore.Keys.ctl_group(id), fn current ->
               if current["task_model_selection"] == first do
                 {:ok, _} = Groups.update(id, %{"task_model_selection" => winner}, tenant)
                 {:ok, Map.put(current, "task_model_selection", policy("loser"))}
               else
                 {:error, :stale}
               end
             end)

    assert {:ok, %{"task_model_selection" => ^winner}} = Groups.get(id, tenant)
  end
end
