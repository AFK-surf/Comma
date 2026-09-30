defmodule SalixIM.SlackCommandTemplates do
  @moduledoc "Tenant-owned command presets. Copying creates independent App configuration."
  alias SalixIM.SlackCommands
  alias SalixStore.{SlackCommandControl, TenantConfigs}

  @name "slack_command_templates"

  def built_ins, do: SlackCommands.task_aliases()

  def get(tenant_id) do
    case TenantConfigs.get(tenant_id, @name) do
      {:ok, %{"value" => value}} ->
        {:ok, value}

      # Built-ins are a separate library, never implicit organization data.
      {:error, :not_found} ->
        {:ok, %{"revision" => 0, "commands" => []}}
    end
  end

  def save(tenant_id, revision, entries) do
    with {:ok, entries} <- SlackCommands.validate(entries) do
      SlackCommandControl.exclusive(fn ->
        with {:ok, current} <- get(tenant_id),
             true <- current["revision"] == revision,
             {:ok, record} <-
               TenantConfigs.put(%{
                 "tenant_id" => tenant_id,
                 "name" => @name,
                 "value" => %{"revision" => revision + 1, "commands" => entries},
                 "updated_at" => System.system_time(:second)
               }) do
          {:ok, record["value"]}
        else
          false -> {:error, :command_templates_changed}
        end
      end)
    end
  end

  def copy(tenant_id, group_id, connect_id, app_id, app_revision, template_revision, command) do
    with {:ok, templates} <- get(tenant_id),
         true <- templates["revision"] == template_revision,
         entry when is_map(entry) <- Enum.find(templates["commands"], &(&1["command"] == command)),
         {:ok, app} <- SlackCommands.get(tenant_id, group_id, connect_id) do
      config = app["configuration"]

      if Enum.any?(config["commands"], &(&1["command"] == command)) do
        {:error, :command_template_conflict}
      else
        # Copy the selected snapshot. Future template edits/deletion are not
        # inherited. The existing App CAS still fences concurrent App edits.
        SlackCommands.save(
          tenant_id,
          group_id,
          connect_id,
          app_id,
          app_revision,
          config["commands"] ++ [entry],
          config["credential_profile"] || "default"
        )
      end
    else
      false -> {:error, :command_templates_changed}
      nil -> {:error, :command_template_missing}
      error -> error
    end
  end
end
