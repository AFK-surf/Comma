defmodule SalixAgent.AgentManagement.Projection do
  @moduledoc false
  alias SalixAgent.{Control, Templates}

  def runtime(%{"kind" => kind} = binding) when kind in ~w(external connected_runtime) do
    %{
      "kind" => "connected",
      "provider" => binding["provider"],
      "device_id" => binding["device_id"],
      "device_runtime_id" => binding["device_runtime_id"]
    }
  end

  def runtime(%{"kind" => "compute_workload"} = binding),
    do: %{
      "kind" => "compute",
      "provider" => get_in(binding, ["runtime_spec", "provider"]),
      "workload_id" => binding["workload_id"]
    }

  def runtime(_), do: %{"kind" => "internal"}

  def summary(record) do
    %{
      "agent_id" => record["agent_id"],
      "name" => record["name"],
      "purpose" => record["management_purpose"] || "",
      "lifecycle" => if(Control.archived?(record), do: "archived", else: "unarchived"),
      "runtime" => runtime(record["runtime_config"]),
      "binding_revision" =>
        if(Control.external_runtime?(record),
          do: get_in(record, ["runtime_config", "binding_revision"]) || 0,
          else: nil
        ),
      "archived_at" => record["archived_at"],
      "permanent" => Control.permanently_archived?(record)
    }
  end

  def detail(record) do
    summary(record)
    |> Map.put("model", model(record))
    |> Map.put("creation_audit", record["management_creation_audit"])
  end

  defp model(record) do
    if Control.external_runtime?(record) do
      runtime = record["runtime_config"] || %{}
      settings = runtime["runtime_spec"] || runtime

      %{
        "source" => if(settings["model"], do: "agent_config", else: "runtime_default"),
        "model_id" => settings["model"],
        "provider" => settings["model_provider"],
        "reasoning_effort" => settings["reasoning_effort"]
      }
    else
      # `source` says whether the Agent pins this template or follows a role
      # default; the remaining fields always describe the effective template.
      case Templates.resolve_public_template_for_record(record) do
        {:ok, template, source} ->
          %{
            "source" => Atom.to_string(source),
            "template_id" => template["template_id"],
            "name" => template["name"],
            "model_id" => template["model"],
            "provider" => template["provider"]
          }

        _ ->
          %{"source" => "unavailable"}
      end
    end
  end
end
