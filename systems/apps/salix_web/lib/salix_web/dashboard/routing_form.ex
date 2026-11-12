defmodule SalixWeb.Dashboard.RoutingForm do
  @moduledoc "Edits Group-owned routing entries without exposing learning state."
  alias SalixIM.TaskModelSelection

  # The file budget permits indentation. The compact table keeps its existing 8 KiB limit.
  def max_file_bytes, do: 64 * 1024

  def export_table(rows) do
    with {:ok, table} <- table(rows) do
      {:ok, table |> Map.delete("revision") |> Jason.encode!(pretty: true)}
    end
  end

  def import_table(json) when is_binary(json) and byte_size(json) <= 64 * 1024 do
    with {:ok, %{"mode" => "routes", "schema_version" => 2} = table} <- Jason.decode(json),
         true <- Map.keys(table) -- ~w(mode schema_version entries) == [],
         :ok <- TaskModelSelection.validate(Map.put(table, "revision", revision())) do
      {:ok, rows(table)}
    else
      _ ->
        {:error,
         "Invalid route table. Import a version 2 route-table JSON file with unique keys and valid entries."}
    end
  end

  def import_table(_), do: {:error, "Choose a JSON file no larger than 64 KiB."}

  def editable?(nil), do: true
  def editable?(%{"mode" => "routes", "schema_version" => 2}), do: true
  def editable?(_), do: false

  def rows(%{"mode" => "routes", "entries" => entries} = policy) do
    entries
    |> Enum.with_index()
    |> Map.new(fn {entry, index} ->
      model =
        if policy["profile_id"] == entry["model"]["profile_id"],
          do: Map.delete(entry["model"], "profile_id"),
          else: entry["model"]

      {to_string(index), row(entry["key"], entry["description"], model)}
    end)
  end

  def rows(_), do: %{}

  defp row(key, description, model),
    do: %{
      "key" => key,
      "description" => description,
      "model" => model_key(model),
      "effort" => model["reasoning_effort"] || "default"
    }

  def ordered(rows), do: Enum.sort_by(rows, fn {id, _} -> String.to_integer(id) end)

  # Plain choices keep their model id. Paid and pinned choices need a distinct
  # select value so the editor can preserve the complete Model Choice.
  def model_key(choice) do
    choice =
      choice
      |> Map.take(~w(kind model tier allow_paid profile_id))
      |> Map.put_new("kind", "catalog")
      |> Map.reject(fn {key, value} ->
        is_nil(value) or (key == "allow_paid" and value == false)
      end)

    if choice["kind"] == "catalog" and Map.keys(choice) -- ~w(kind model) == [],
      do: choice["model"],
      else: Jason.encode!(choice)
  end

  def choice(key) do
    case Jason.decode(key) do
      {:ok, %{"kind" => kind} = choice} when kind in ["catalog", "platform"] -> choice
      _ -> %{"kind" => "catalog", "model" => key}
    end
  end

  def model_label(choice, name \\ nil) do
    label = name || choice["model"] || "Platform model (#{choice["tier"]})"
    label = if choice["allow_paid"], do: label <> " · Pay-per-use", else: label
    if choice["profile_id"], do: label <> " · Profile " <> choice["profile_id"], else: label
  end

  @doc "A Model Choice with its reasoning effort, for people."
  def arm_label(choice) do
    name =
      case SalixAgent.Models.get(choice["model"]) do
        {:ok, model} -> model["name"]
        _ -> nil
      end

    label = model_label(choice, name)
    if choice["reasoning_effort"], do: label <> " · " <> choice["reasoning_effort"], else: label
  end

  def add(rows) when map_size(rows) < 32 do
    next =
      rows
      |> Map.keys()
      |> Enum.map(&String.to_integer/1)
      |> Enum.max(fn -> -1 end)
      |> Kernel.+(1)

    Map.put(rows, to_string(next), %{
      "key" => "",
      "description" => "",
      "model" => "",
      "effort" => ""
    })
  end

  def add(rows), do: rows

  def model_options(models, current) do
    options = Enum.map(models, &{&1["name"] || &1["id"], &1["key"] || &1["id"]})

    if current not in [nil, ""] and not Enum.any?(options, fn {_, id} -> id == current end),
      do: [{"#{model_label(choice(current))} (unavailable)", current} | options],
      else: options
  end

  def efforts(models, model, current \\ nil) do
    options =
      case Enum.find(models, &((&1["key"] || &1["id"]) == model)) do
        nil ->
          []

        record ->
          Enum.map(record["routing_efforts"], fn
            nil -> {"Default", "default"}
            effort -> {String.capitalize(effort), effort}
          end)
      end

    if current not in [nil, ""] and not Enum.any?(options, fn {_, value} -> value == current end),
      do: [{"#{current} (unavailable)", current} | options],
      else: options
  end

  def valid_row?(%{"model" => model, "effort" => effort}, models),
    do: Enum.any?(efforts(models, model), fn {_, value} -> value == effort end)

  def valid_row?(_, _), do: false

  def change(rows, incoming, models) do
    Map.new(rows, fn {id, previous} ->
      updated =
        Map.merge(
          previous,
          Map.take(Map.get(incoming, id, %{}), ~w(key description model effort))
        )

      updated =
        if updated["model"] != previous["model"] do
          effort =
            case efforts(models, updated["model"]) do
              [{_, value} | _] -> value
              _ -> ""
            end

          Map.put(updated, "effort", effort)
        else
          updated
        end

      {id, updated}
    end)
  end

  @doc "Whether a route table learns from Task results (`Salix.TaskRoutingLearning`)."
  def learning?(%{"mode" => "routes", "learning" => true}), do: true
  def learning?(_policy), do: false

  def policy(original, rows, enabled, models, learning \\ false) do
    cond do
      not editable?(original) ->
        actions = original["actions"] || original["candidates"] || []

        if not enabled or Enum.all?(actions, &valid_action?(&1, models)),
          do: {:ok, Map.put(original, "enabled", enabled)},
          else:
            {:error,
             "A saved model or effort is unavailable under this workspace's accounts and policy."}

      not enabled and original != nil and rows == rows(original) ->
        disabled = Map.put(original, "enabled", false)

        {:ok,
         if(original["mode"] == "routes", do: put_learning(disabled, learning), else: disabled)}

      true ->
        build(original, rows, enabled, models, learning)
    end
  end

  defp put_learning(policy, true), do: Map.put(policy, "learning", true)
  defp put_learning(policy, _learning), do: Map.delete(policy, "learning")

  defp build(original, rows, enabled, models, learning) do
    with {:ok, table} <- table(rows) do
      case Enum.find(ordered(rows), fn {_id, row} -> not valid_row?(row, models) end) do
        nil ->
          {:ok,
           (original || %{})
           |> Map.take(["profile_id"])
           |> Map.merge(table)
           |> Map.put("enabled", enabled)
           |> put_learning(learning)}

        {_id, row} ->
          {:error, "#{row["key"]}: choose an available model and supported reasoning effort."}
      end
    end
  end

  defp table(rows) do
    ordered = ordered(rows)

    entries =
      Enum.map(ordered, fn {_id, row} ->
        model = choice(row["model"])

        model =
          if model["kind"] == "catalog" or SalixAgent.PlatformModels.routed_model?(model),
            do:
              Map.put(
                model,
                "reasoning_effort",
                if(row["effort"] == "default", do: nil, else: row["effort"])
              ),
            else: model

        model =
          if model["kind"] == "platform" and is_nil(model["reasoning_effort"]),
            do: Map.delete(model, "reasoning_effort"),
            else: model

        %{
          "key" => String.trim(row["key"]),
          "description" => row["description"],
          "model" => model
        }
      end)

    policy = %{
      "mode" => "routes",
      "schema_version" => 2,
      "revision" => revision(),
      "entries" => entries
    }

    case TaskModelSelection.validate(policy) do
      :ok ->
        {:ok, policy}

      _ ->
        {:error,
         "Use unique, nonblank keys and descriptions, at most 32 entries and 8 KiB for the table."}
    end
  end

  defp revision, do: "manual-" <> SystemsRuntime.Proc.uuid()

  defp valid_action?(action, models),
    do:
      valid_row?(
        %{"model" => model_key(action), "effort" => action["reasoning_effort"] || "default"},
        models
      )
end
