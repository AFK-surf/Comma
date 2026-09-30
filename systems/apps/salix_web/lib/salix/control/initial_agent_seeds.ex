defmodule Salix.Control.InitialAgentSeeds do
  @moduledoc """
  Initial agent seed control-plane API.
  """

  alias Salix.Control.{Groups, Store}
  alias SalixStore.Keys

  def list(tenant_id) do
    tenant_id
    |> Keys.ctl_initial_agents_prefix()
    |> Store.list_records()
    |> Enum.map(&initial_agent_json/1)
    |> Enum.sort_by(fn rec -> {rec["sort_order"] || 0, rec["slot"] || ""} end)
  end

  def get(slot, tenant_id) do
    with :ok <- validate_slot(slot),
         {:ok, rec} <- Store.get_record(Keys.ctl_initial_agent(tenant_id, slot)) do
      {:ok, initial_agent_json(rec)}
    end
  end

  def put(slot, attrs, tenant_id) when is_map(attrs) do
    slot = Store.trim(slot)
    now = Store.now()

    with :ok <- validate_slot(slot),
         {:ok, updates} <- updates(slot, attrs, tenant_id) do
      new_rec =
        updates
        |> Map.put("slot", slot)
        |> Map.put("tenant_id", tenant_id)
        |> Map.put_new("enabled", true)
        |> Map.put_new("sort_order", 0)
        |> Map.put("created_at", now)
        |> Map.put("updated_at", now)

      result =
        Store.upsert_record(Keys.ctl_initial_agent(tenant_id, slot), new_rec, fn current ->
          current
          |> Map.merge(updates)
          |> Map.put("slot", slot)
          |> Map.put("tenant_id", tenant_id)
          |> Map.put("updated_at", now)
        end)

      with {:ok, rec} <- result do
        if rec["is_default"] == true do
          clear_other_defaults(tenant_id, slot)
        end

        {:ok, initial_agent_json(rec)}
      end
    end
  end

  def put(_slot, _attrs, _tenant_id),
    do: {:error, {:bad_request, "invalid request body"}}

  def delete(slot, tenant_id) do
    slot = Store.trim(slot)

    with :ok <- validate_slot(slot),
         {:ok, _agent} <- get(slot, tenant_id) do
      Store.delete_record(Keys.ctl_initial_agent(tenant_id, slot))
    end
  end

  def set_main(attrs, tenant_id) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put("is_default", true)
      |> Map.put("is_router", false)
      |> Map.put("role", "worker")
      |> Map.put_new("enabled", true)
      |> Map.put_new("sort_order", 0)

    put("main", attrs, tenant_id)
  end

  def materialize_slot(group_id, slot, tenant_id) do
    with {:ok, group} <- Groups.get(group_id, tenant_id),
         {:ok, slot_rec} <- get(slot, tenant_id),
         true <- slot_rec["enabled"] != false,
         {:ok, existing} <- find_materialized_agent(group_id, slot_rec, tenant_id) do
      case existing do
        nil ->
          attrs = %{
            "group_id" => group["group_id"],
            "template_id" => slot_rec["template_id"],
            "name" => slot_rec["display_name"],
            "role" => slot_rec["role"],
            "is_router" => slot_rec["is_router"] == true,
            "source_initial_agent_slot" => slot_rec["slot"],
            "source_initial_agent_revision" =>
              slot_rec["updated_at"] || slot_rec["created_at"] || 0
          }

          with {:ok, agent} <- SalixAgent.Control.create(attrs, tenant_id),
               {:ok, agent} <- maybe_assign_router(group["group_id"], slot_rec, agent) do
            {:ok, agent}
          end

        agent ->
          {:ok, agent}
      end
    else
      false -> {:error, {:bad_request, "initial agent slot disabled"}}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp load_visible_template(template_id, tenant_id) do
    with {:ok, template} <- SalixAgent.Templates.get(template_id, tenant_id),
         true <- template["hidden"] != true do
      {:ok, template}
    else
      false -> {:error, {:bad_request, "template not found"}}
      {:error, :not_found} -> {:error, {:bad_request, "template not found"}}
      {:error, _} = err -> err
    end
  end

  defp initial_agent_json(rec) do
    template = SalixAgent.Templates.snapshot(rec["template_id"], rec["tenant_id"])

    %{
      "slot" => rec["slot"],
      "display_name" => rec["display_name"] || template["name"] || "",
      "description" => rec["description"] || "",
      "template_id" => rec["template_id"],
      "template_name" => template["name"] || rec["template_name"] || "",
      "model" => template["model"] || rec["model"] || "",
      "is_default" => rec["is_default"] == true,
      "is_router" => rec["is_router"] == true,
      "role" =>
        normalize_role(rec["role"] || if(rec["is_router"] == true, do: "router", else: "worker")),
      "sort_order" => rec["sort_order"] || 0,
      "enabled" => rec["enabled"] != false,
      "created_at" => rec["created_at"] || 0,
      "updated_at" => rec["updated_at"] || rec["created_at"] || 0
    }
    |> Store.put_optional("avatar_url", nonblank(rec["avatar_url"]))
    |> Store.put_optional("avatar_mime_type", nonblank(rec["avatar_mime_type"]))
    |> Store.put_optional("avatar_size_bytes", rec["avatar_size_bytes"])
  end

  defp validate_slot(slot) do
    cond do
      Store.blank?(slot) ->
        {:error, {:bad_request, "initial agent slot is required"}}

      not Regex.match?(~r/^[A-Za-z0-9._-]+$/, slot) ->
        {:error, {:bad_request, "initial agent slot is invalid"}}

      true ->
        :ok
    end
  end

  defp updates(slot, attrs, tenant_id) do
    template_id = Store.trim(attrs["template_id"])

    with :ok <- validate_template(template_id),
         {:ok, template} <- load_visible_template(template_id, tenant_id),
         {:ok, is_default} <- optional_bool(attrs, "is_default", false),
         {:ok, is_router} <- optional_bool(attrs, "is_router", false),
         {:ok, enabled} <- optional_bool(attrs, "enabled", true),
         {:ok, sort_order} <- optional_int(attrs, "sort_order", 0),
         role <- normalize_role(attrs["role"] || if(is_router, do: "router", else: "worker")),
         :ok <- validate_role(role, is_default, is_router),
         :ok <- validate_unique_default(tenant_id, slot, is_default) do
      display_name =
        attrs["display_name"]
        |> Store.trim()
        |> case do
          "" -> template["name"] || slot
          value -> value
        end

      {:ok,
       %{
         "display_name" => display_name,
         "description" => Store.trim(attrs["description"]),
         "template_id" => template_id,
         "template_name" => template["name"] || "",
         "model" => template["model"] || "",
         "is_default" => is_default,
         "is_router" => is_router,
         "role" => role,
         "sort_order" => sort_order,
         "enabled" => enabled
       }
       |> Store.put_optional("avatar_url", nonblank(attrs["avatar_url"]))
       |> Store.put_optional("avatar_mime_type", nonblank(attrs["avatar_mime_type"]))
       |> Store.put_optional("avatar_size_bytes", attrs["avatar_size_bytes"])}
    end
  end

  defp validate_template(""), do: {:error, {:bad_request, "template_id is required"}}
  defp validate_template(_template_id), do: :ok

  defp validate_role("router", false, true), do: :ok
  defp validate_role("worker", true, false), do: :ok
  defp validate_role("worker", false, false), do: :ok

  defp validate_role("router", true, _is_router),
    do: {:error, {:bad_request, "default initial agent role must be worker"}}

  defp validate_role("worker", _is_default, true),
    do: {:error, {:bad_request, "router initial agent seed role must be router"}}

  defp validate_role(_role, _is_default, _is_router),
    do: {:error, {:bad_request, "invalid initial agent role"}}

  defp validate_unique_default(_tenant_id, _slot, _is_default), do: :ok

  defp clear_other_defaults(tenant_id, slot) do
    tenant_id
    |> Keys.ctl_initial_agents_prefix()
    |> Store.list_records()
    |> Enum.each(fn rec ->
      other_slot = rec["slot"]

      if other_slot != slot and rec["is_default"] == true do
        _ =
          Store.update_record(Keys.ctl_initial_agent(tenant_id, other_slot), fn current ->
            Map.put(current, "is_default", false)
          end)
      end
    end)
  end

  # Existence check backing materialization idempotency: a storage failure
  # must propagate rather than read as "not materialized", or a degraded
  # listing would mint a duplicate agent for the slot.
  defp find_materialized_agent(group_id, slot_rec, tenant_id) do
    with {:ok, agents} <- SalixAgent.Control.list_result(tenant_id, group_id: group_id) do
      {:ok, Enum.find(agents, &(&1["source_initial_agent_slot"] == slot_rec["slot"]))}
    end
  end

  defp maybe_assign_router(group_id, %{"is_router" => true}, %{"agent_id" => agent_id}) do
    with {:ok, _group} <- Groups.update(group_id, %{"router_agent_id" => agent_id}) do
      SalixAgent.Control.get(agent_id)
    end
  end

  defp maybe_assign_router(_group_id, _slot_rec, agent), do: {:ok, agent}

  defp optional_bool(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, default}
      _ -> {:error, {:bad_request, "#{key} must be a boolean"}}
    end
  end

  defp optional_int(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_integer(value) -> {:ok, value}
      nil -> {:ok, default}
      _ -> {:error, {:bad_request, "#{key} must be an integer"}}
    end
  end

  defp normalize_role("router"), do: "router"
  defp normalize_role("meeting"), do: "meeting"
  defp normalize_role(_), do: "worker"

  defp nonblank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp nonblank(_value), do: nil
end
