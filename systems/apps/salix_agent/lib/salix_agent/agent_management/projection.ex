defmodule SalixAgent.AgentManagement.Projection do
  @moduledoc false
  alias SalixAgent.{AgentModel, Control, StationBinding}

  @doc "Where a Worker record runs, as Router tools and products show it."
  def worker_runtime(record) do
    case StationBinding.get(record) do
      nil ->
        %{"kind" => "internal"}

      binding ->
        %{
          "kind" => "station",
          "runs_on" => binding["runs_on"],
          "provider" => get_in(binding, ["model", "provider"])
        }
    end
  end

  def summary(record) do
    %{
      "agent_id" => record["agent_id"],
      "name" => record["name"],
      "purpose" => record["management_purpose"] || "",
      "lifecycle" => if(Control.archived?(record), do: "archived", else: "unarchived"),
      "runtime" => worker_runtime(record),
      "binding_revision" => binding_revision(record),
      "archived_at" => record["archived_at"],
      "permanent" => Control.permanently_archived?(record)
    }
  end

  def detail(record) do
    summary(record)
    |> Map.put("model", model(record))
    |> Map.put("creation_audit", record["management_creation_audit"])
  end

  defp binding_revision(record) do
    if StationBinding.bound?(record),
      do: get_in(record, ["station_binding", "binding_revision"]) || 0
  end

  defp model(%{"station_binding" => %{"runs_on" => %{}, "model" => model}}) do
    %{
      "source" => if(model["model"], do: "agent_config", else: "runtime_default"),
      "model_id" => model["model"],
      "provider" => model["provider"],
      "reasoning_effort" => model["reasoning_effort"]
    }
  end

  # `source` says whether the Agent chose this model or follows its role's
  # platform model; the remaining fields describe the model it runs.
  defp model(record) do
    case AgentModel.resolve_public(record) do
      {:ok, model, source} ->
        %{
          "source" => Atom.to_string(source),
          "name" => model["name"],
          "model_id" => model["model"],
          "provider" => model["provider"]
        }

      _ ->
        %{"source" => "unavailable"}
    end
  end
end
