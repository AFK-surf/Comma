defmodule SalixWeb.Dashboard.SlackCommandScope do
  @moduledoc "Shared organization-scoped App choices for command administration."

  def apps(tenant) do
    tenant
    |> Salix.Control.Groups.list()
    |> Enum.flat_map(fn group ->
      case SalixIM.ProviderConnects.list_group_im_connects(group["group_id"], "slack") do
        {:ok, connects} ->
          connects
          |> Enum.filter(
            &(&1["tenant_id"] == tenant and
                is_nil(&1["deleted_at"]) and is_binary(&1["app_id"]) and &1["app_id"] != "")
          )
          |> Enum.map(&Map.put(&1, "group_name", group["name"] || group["group_id"]))

        _ ->
          []
      end
    end)
    |> Enum.sort_by(&{&1["app_name"], &1["app_id"]})
  end

  def label(tenants, id) do
    Enum.find_value(tenants, id, fn tenant ->
      if tenant["tenant_id"] == id, do: tenant["name"]
    end)
  end

  def profile_apps(tenant) do
    apps(tenant)
    |> Enum.flat_map(fn app ->
      case SalixIM.SlackCommands.get(tenant, app["group_id"], app["connect_id"]) do
        {:ok, current} ->
          [
            {current["configuration"]["credential_profile"] || "default",
             "#{app["app_name"]} (#{app["app_id"]})"}
          ]

        _ ->
          []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end
end
