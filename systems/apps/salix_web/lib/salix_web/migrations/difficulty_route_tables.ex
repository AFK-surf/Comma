defmodule SalixWeb.Migrations.DifficultyRouteTables do
  @moduledoc """
  Convert each Group's difficulty table (`task_model_selection` mode
  `tag_rules`, retired) to a route table (mode `routes`, schema version 2).

  Route `d1` through `d10` become entries with the same keys, the difficulty
  question's criteria as their descriptions, and the table's model and
  reasoning effort for each level. A table with a `learning` object gets the
  learning switch on. The routing switch (`enabled`), `profile_id` and the
  rule version (as `revision`) are kept. A route's key and description name
  its evidence (`SalixAgent.TaskRouting.Learner.generation/2`), and a
  difficulty action names the same arm as its catalog Model Choice, so the
  evidence a table learned stays with its routes.

  Each page reads at most 100 Group records. Each write is conditional on the
  record it read (`SalixStore.CasRecord`). A pass run again changes nothing. A converted table that a route table cannot hold
  (more than 8 KiB) stops the pass with the Group's id: shorten its
  descriptions through the Group API, then run the pass again.
  """

  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @page 100

  @doc "Convert every difficulty table. Answers how many Groups changed."
  def run, do: run(nil, 0)

  defp run(cursor, converted) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(Keys.ctl_groups_prefix(), max_keys: @page, continuation_token: cursor),
         {:ok, count} <- convert_page(objects) do
      if next, do: run(next, converted + count), else: {:ok, %{converted: converted + count}}
    end
  end

  defp convert_page(objects) do
    Enum.reduce_while(objects, {:ok, 0}, fn object, {:ok, count} ->
      case group_id(object.key) do
        nil ->
          {:cont, {:ok, count}}

        group_id ->
          case convert(group_id) do
            {:ok, true} -> {:cont, {:ok, count + 1}}
            {:ok, false} -> {:cont, {:ok, count}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp group_id("ctl/groups/" <> name) do
    group_id = String.replace_suffix(name, ".json", "")
    if group_id != name and Ids.valid_group_id?(group_id), do: group_id
  end

  defp group_id(_key), do: nil

  @doc "Convert one Group's difficulty table. Answers whether it changed."
  def convert(group_id) do
    key = Keys.ctl_group(group_id)

    with {:ok, %{"task_model_selection" => %{"mode" => "tag_rules"}}} <- CasRecord.get(key),
         {:ok, _group} <- CasRecord.update(key, &convert_record(&1, group_id), create: false) do
      {:ok, true}
    else
      {:ok, _group} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      error -> error
    end
  end

  defp convert_record(%{"task_model_selection" => %{"mode" => "tag_rules"} = table} = group, id) do
    routes = route_table(table)

    case SalixIM.TaskModelSelection.validate(routes) do
      :ok -> Map.put(group, "task_model_selection", routes)
      {:error, _} -> {:error, {:route_table_too_large, id}}
    end
  end

  defp convert_record(group, _id), do: {:unchanged, group}

  @doc false
  def route_table(table) do
    entries =
      for level <- 1..10 do
        key = "d#{level}"
        action = Enum.at(table["actions"], table["routes"][key]["action"])

        model =
          %{"kind" => "catalog", "model" => action["model"]}
          |> then(fn model ->
            if action["reasoning_effort"],
              do: Map.put(model, "reasoning_effort", action["reasoning_effort"]),
              else: model
          end)

        %{
          "key" => key,
          "description" => table["questions"]["difficulty"]["criteria"][key],
          "model" => model
        }
      end

    %{
      "mode" => "routes",
      "schema_version" => 2,
      "revision" => table["rule_version"],
      "entries" => entries,
      "learning" => is_map(table["learning"])
    }
    |> Map.merge(Map.take(table, ~w(enabled profile_id)))
  end
end
