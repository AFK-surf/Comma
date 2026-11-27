defmodule SalixAgent.IFC.HardConvergence do
  @moduledoc "A request-local exploration bound over the already visible audience view."
  @budget 8
  @collections ~w(results matches items files messages entries devices bindings hosts credentials tools)

  def prompt do
    "The current exploration budget is exhausted. Only end_turn is available for this request. " <>
      "Answer from the evidence already visible, or ask for missing context in end_turn.reply. " <>
      "An unavailable or empty lookup does not establish whether information exists elsewhere. " <>
      "Do not call help, search, call, or wait_for. A visible answer still requires the normal IFC declaration."
  end

  # These names select public platform contracts, never connected plugin manuals.
  @reply_tools ~w(im_api.slack.reply_message im_api.internal.send_message im_api.feishu.reply_text)

  def tools(specs) do
    specs
    |> Enum.filter(&(&1["name"] == "end_turn"))
    |> Enum.map(fn spec ->
      schema_key = if Map.has_key?(spec, "input_schema"), do: "input_schema", else: "parameters"

      spec
      |> Map.update!("description", &(&1 <> "\n\n" <> prompt()))
      |> update_in([schema_key, "properties", "reply", "description"], fn description ->
        (description || "") <>
          "\nPublic built-in reply parameter contracts follow. Use only the current authenticated reply target. " <>
          "Use field names exactly. Values come from visible source context, never from this catalog. " <>
          "An invalid_params receipt requires correcting these fields before retrying.\n" <>
          Jason.encode!(reply_contracts())
      end)
    end)
  end

  defp reply_contracts do
    Enum.reduce(@reply_tools, %{}, fn name, acc ->
      case SalixAgent.Tools.ImRouter.builtin_help_entry(name) do
        %{"input_schema" => %{"properties" => fields} = schema} ->
          # Omit examples, defaults, descriptions and connection values.
          fields = Map.new(fields, fn {key, value} -> {key, Map.take(value, ["type"])} end)
          Map.put(acc, name, %{"properties" => fields, "required" => schema["required"] || []})

        _ ->
          acc
      end
    end)
  end

  def finish?(projection, async) do
    messages = activation(projection.messages)

    visible_ids =
      messages
      |> Enum.flat_map(&List.wrap(get(&1, :tool_calls)))
      |> Enum.map(fn c ->
        local = "src:t-" <> get(c, :id)
        projection.aliases |> Map.get(local, local) |> String.replace_prefix("src:t-", "")
      end)

    active? = Enum.any?(visible_ids, &Map.has_key?(async, &1))
    streak(messages) >= @budget and not active? and not pending_delegation?(messages)
  end

  def streak(messages) do
    messages = activation(messages)

    results =
      messages
      |> Enum.filter(&(get(&1, :role) == "tool"))
      |> Map.new(&{get(&1, :tool_call_id), decode(get(&1, :content))})

    terminals =
      messages
      |> Enum.filter(&(get(&1, :role) == "runtime"))
      |> Enum.map(&decode(get(&1, :content)))
      |> Enum.filter(&(is_map(&1) and &1["type"] in ["tool_call_completed", "tool_call_failed"]))
      |> Map.new(&{&1["tool_call_id"], &1["result"]})

    {count, _} =
      messages
      |> Enum.filter(&(get(&1, :role) == "assistant"))
      |> Enum.reduce({0, MapSet.new()}, fn message, {count, seen} ->
        calls = List.wrap(get(message, :tool_calls))

        failed? =
          calls != [] and
            Enum.all?(calls, fn call ->
              result = results[get(call, :id)]

              result =
                case result do
                  %{"status" => "running", "tool_call_id" => id} ->
                    case terminals[id] do
                      %{"content" => content} -> decode(content)
                      _ -> nil
                    end

                  other ->
                    other
                end

              # A missing/pending result is not evidence of failure, even on retry.
              not is_nil(result) and
                (no_progress?(result) or MapSet.member?(seen, signature(call)))
            end)

        {if(failed?, do: count + 1, else: 0),
         Enum.reduce(calls, seen, &MapSet.put(&2, signature(&1)))}
      end)

    count
  end

  # No ids, labels, counts, or facts from omitted history enter this calculation.
  defp activation(messages) do
    index =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {m, _} -> get(m, :role) == "user" end)
      |> List.last()

    case index do
      {_, i} -> Enum.drop(messages, i + 1)
      nil -> messages
    end
  end

  defp pending_delegation?(messages) do
    results =
      messages
      |> Enum.filter(&(get(&1, :role) == "tool"))
      |> Map.new(&{get(&1, :tool_call_id), decode(get(&1, :content))})

    messages
    |> Enum.flat_map(&List.wrap(get(&1, :tool_calls)))
    |> Enum.any?(fn call ->
      args = get(call, :args) || %{}

      if get(args, :tool) == "im_api.internal.task.create" do
        # No Group-wide probe: an unresolved visible delegation remains pending.
        result = results[get(call, :id)]
        not definite_local_failure?(result)
      else
        false
      end
    end)
  end

  defp definite_local_failure?(%{"kind" => "runtime_diagnostic"} = item),
    do: SalixAgent.IFC.LocalDiagnostic.fixed_item?(item)

  defp definite_local_failure?(%{"guidance_reason" => reason})
       when reason in ["invalid_params", "not_callable", "envelope_misuse"], do: true

  defp definite_local_failure?(_), do: false

  defp no_progress?([]), do: true

  defp no_progress?(%{"kind" => "runtime_diagnostic"} = item),
    do: SalixAgent.IFC.LocalDiagnostic.fixed_item?(item)

  defp no_progress?(%{
         "status" => "withheld_by_visibility",
         "message" => "This tool result is not visible in the current audience and was omitted."
       }),
       do: true

  defp no_progress?(%{"guidance_reason" => reason})
       when reason in ["invalid_params", "not_callable", "envelope_misuse"], do: true

  defp no_progress?(%{"error" => "history_unavailable_or_invalid_request"}), do: true

  defp no_progress?(body) when is_map(body) do
    body["error"] in [nil, false] and body["has_more"] != true and
      body["next_cursor"] in [nil, ""] and
      Enum.any?(@collections, &(Map.has_key?(body, &1) and body[&1] == []))
  end

  defp no_progress?(_), do: false

  defp signature(call) do
    args = get(call, :args) || %{}
    {get(call, :name), get(args, :tool), get(args, :params) || Map.drop(args, [:ifc, "ifc"])}
  end

  defp decode(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, body} -> body
      _ -> nil
    end
  end

  defp decode(content), do: content
  defp get(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
