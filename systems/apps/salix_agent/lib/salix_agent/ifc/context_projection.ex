defmodule SalixAgent.IFC.ContextProjection do
  @moduledoc "Request-local visibility projection. The durable transcript is never rewritten."

  alias SalixIFC.{Codec, Label}
  @private ["agent_private"]
  @fields [
    :id,
    :role,
    :content,
    :tool_calls,
    :tool_call_id,
    :name,
    :tool_name,
    :result_seq,
    :trusted_attachment_refs,
    :trusted_origin,
    :ifc
  ]

  def visible_label?(raw, %{destinations: destinations, facts: facts}) do
    label = Codec.decode_label(raw, Codec.decode_label(@private, Label.bottom()))

    destinations != [] and
      Enum.all?(destinations, &(SalixIFC.readers_subset?(&1, label, facts) == true))
  end

  def response(response, nil), do: response

  def response(response, %{aliases: refs}) when is_tuple(response) do
    case Tuple.to_list(response) do
      [:assistant, text, calls | rest] when is_list(calls) ->
        List.to_tuple([:assistant, text, Enum.map(calls, &translate_call(&1, refs)) | rest])

      _ ->
        response
    end
  end

  def response(response, _), do: response

  defp translate_call(call, refs) do
    call = remap_declaration(call, refs)

    Enum.reduce([:args, "args", :params, "params"], call, fn key, acc ->
      case Map.get(acc, key) do
        %{} = args ->
          args = remap_declaration(args, refs)

          args =
            Enum.reduce([:reply, "reply"], args, fn reply_key, params ->
              case Map.get(params, reply_key) do
                %{} = reply -> Map.put(params, reply_key, translate_call(reply, refs))
                _ -> params
              end
            end)

          args = if value(call, :name) == "call", do: translate_params(args, refs), else: args
          Map.put(acc, key, args)

        _ ->
          acc
      end
    end)
  end

  defp translate_params(args, refs) do
    case Map.get(args, "params") do
      %{} = params -> Map.put(args, "params", remap_declaration(params, refs))
      _ -> args
    end
  end

  # All labels here are owner-held metadata, never labels parsed from content.
  def project(messages, destinations, facts) do
    visible =
      if destinations == [] do
        []
      else
        messages = Enum.flat_map(messages, &provider_content(&1, destinations, facts))

        all_calls =
          messages
          |> Enum.filter(&(value(&1, :role) == "assistant"))
          |> Enum.flat_map(&List.wrap(value(&1, :tool_calls)))
          |> MapSet.new(&value(&1, :id))

        visible_calls =
          messages
          |> Enum.filter(fn message ->
            value(message, :role) == "assistant" and
              visible_label?(value(message, :ifc_view_label), %{
                destinations: destinations,
                facts: facts
              })
          end)
          |> Enum.flat_map(&List.wrap(value(&1, :tool_calls)))
          |> MapSet.new(&value(&1, :id))

        Enum.flat_map(messages, fn message ->
          cond do
            value(message, :role) == "tool" and
                MapSet.member?(visible_calls, value(message, :tool_call_id)) ->
              called_result(message, destinations, facts)

            value(message, :role) == "tool" and
                MapSet.member?(all_calls, value(message, :tool_call_id)) ->
              []

            legacy_result?(message) ->
              []

            value(message, :role) == "provider_context" ->
              []

            visible_label?(Codec.encode_label(label(message)), %{
              destinations: destinations,
              facts: facts
            }) ->
              [message]

            true ->
              visible_elements(message, destinations, facts)
          end
        end)
      end

    visible = pair_tools(visible)

    call_ids =
      visible
      |> Enum.flat_map(&List.wrap(value(&1, :tool_calls)))
      |> Enum.with_index(1)
      |> Map.new(fn {call, index} -> {value(call, :id), "call-#{index}"} end)

    aliases =
      visible
      |> Enum.with_index(1)
      |> Map.new(fn {message, index} ->
        local =
          if value(message, :role) == "tool",
            do: "src:t-" <> Map.fetch!(call_ids, value(message, :tool_call_id)),
            else: local_ref(message, index)

        {local, source_ref(message)}
      end)

    reverse = Map.new(aliases, fn {local, original} -> {original, local} end)

    projected =
      visible
      |> Enum.with_index(1)
      |> Enum.map(fn {message, index} ->
        message
        |> take_fields()
        |> Map.put(:id, index)
        |> remap_calls(call_ids, reverse)
      end)

    %{
      messages: projected,
      aliases: aliases,
      label: Codec.encode_label(Label.join_all(Enum.map(visible, &label/1) ++ destinations))
    }
  end

  # Only producer-sealed segments carry labels. Body markup is never interpreted.
  defp provider_content(message, destinations, facts) do
    origin = value(message, :trusted_origin)

    if value(message, :role) == "user" and is_binary(value(origin, :provider)) and
         value(origin, :provider) != "internal" do
      case value(origin, :projection_segments) do
        segments when is_list(segments) ->
          visible =
            Enum.filter(segments, fn segment ->
              is_binary(value(segment, :content)) and
                visible_label?(value(segment, :label), %{destinations: destinations, facts: facts})
            end)

          if visible == [] do
            []
          else
            body = Enum.map_join(visible, "\n", &value(&1, :content))

            [
              message
              |> Map.delete("content")
              |> Map.put(:content, body)
              |> Map.delete("trusted_origin")
              |> Map.put(:trusted_origin, Map.put(origin, "projection_segments", visible))
            ]
          end

        _ ->
          case value(origin, :source_text) do
            text when is_binary(text) ->
              [message |> Map.delete("content") |> Map.put(:content, text)]

            _ ->
              []
          end
      end
    else
      [message]
    end
  end

  defp visible_elements(message, destinations, facts) do
    block = value(message, :ifc) || %{}
    elements = value(block, :items)
    content = value(message, :content)
    decoded = if is_binary(content), do: Jason.decode(content), else: {:ok, content}

    bodies =
      case decoded do
        {:ok, list} when is_list(list) -> list
        {:ok, %{"items" => list}} when is_list(list) -> list
        {:ok, %{"messages" => list}} when is_list(list) -> list
        _ -> []
      end

    if value(message, :role) in ["tool", "runtime"] and is_list(elements) do
      Enum.flat_map(elements, fn element ->
        index = value(element, :index)
        body = if is_integer(index) and index >= 0, do: Enum.at(bodies, index)

        child = %{
          id: value(message, :id),
          role: "runtime",
          content: Jason.encode!(body),
          projection_source_ref: source_ref(message) <> "##{index}",
          ifc: %{"label" => value(element, :label), "view_label" => value(block, :view_label)}
        }

        if not is_nil(body) and
             visible_label?(Codec.encode_label(label(child)), %{
               destinations: destinations,
               facts: facts
             }), do: [child], else: []
      end)
    else
      []
    end
  end

  defp called_result(message, destinations, facts) do
    elements =
      if legacy_result?(message), do: [], else: visible_elements(message, destinations, facts)

    diagnostic =
      Enum.find(elements, fn element ->
        value(element.ifc, :label) == ["public"] and
          SalixAgent.IFC.LocalDiagnostic.fixed_item?(Jason.decode!(element.content))
      end)

    cond do
      diagnostic != nil ->
        receipt =
          diagnostic
          |> Map.put(:role, "tool")
          |> Map.put(:tool_call_id, value(message, :tool_call_id))

        [receipt | Enum.reject(elements, &(&1 == diagnostic))]

      not legacy_result?(message) and
          visible_label?(Codec.encode_label(label(message)), %{
            destinations: destinations,
            facts: facts
          }) ->
        [message]

      true ->
        [withheld_result(message, destinations) | elements]
    end
  end

  # Only a visible, runtime-labelled invocation permits this receipt. It never
  # reveals the result's body, source, label, error or whether data was found.
  defp withheld_result(message, destinations) do
    %{
      id: value(message, :id),
      role: "tool",
      tool_call_id: value(message, :tool_call_id),
      content:
        Jason.encode!(%{
          "status" => "withheld_by_visibility",
          "message" => "This tool result is not visible in the current audience and was omitted."
        }),
      ifc: %{
        "label" => ["public"],
        "view_label" => Codec.encode_label(Label.join_all(destinations))
      }
    }
  end

  defp legacy_result?(message) do
    (value(message, :role) == "tool" or
       value(message, :type) in ["tool_call_completed", "tool_call_failed"]) and
      not is_list(value(value(message, :ifc), :view_label))
  end

  def label(message) do
    raw =
      cond do
        legacy_result?(message) ->
          @private

        value(message, :role) in ["assistant", "summary"] ->
          value(message, :ifc_view_label)

        true ->
          block = value(message, :ifc) || value(value(message, :trusted_origin), :ifc)
          value(block, :label)
      end

    fallback = Codec.decode_label(@private, Label.bottom())

    child_labels =
      Enum.map(
        List.wrap(value(value(message, :ifc), :items)),
        &Codec.decode_label(value(&1, :label), fallback)
      )

    segment_labels =
      Enum.map(
        List.wrap(value(value(message, :trusted_origin), :projection_segments)),
        &Codec.decode_label(value(&1, :label), fallback)
      )

    label = Label.join_all([Codec.decode_label(raw, fallback) | child_labels ++ segment_labels])

    case value(value(message, :ifc), :view_label) do
      nil ->
        label

      view ->
        Label.join_all([
          label,
          Codec.decode_label(view, Codec.decode_label(@private, Label.bottom()))
        ])
    end
  end

  # Foreign invocations and orphan results reveal neither tool names nor counts.
  # A visible invocation can instead pair with its fixed withheld receipt.
  defp pair_tools(messages) do
    results =
      messages
      |> Enum.filter(&(value(&1, :role) == "tool"))
      |> MapSet.new(&value(&1, :tool_call_id))

    calls =
      messages
      |> Enum.flat_map(&List.wrap(value(&1, :tool_calls)))
      |> MapSet.new(&value(&1, :id))

    Enum.flat_map(messages, fn message ->
      case value(message, :role) do
        "tool" ->
          if MapSet.member?(calls, value(message, :tool_call_id)), do: [message], else: []

        "assistant" ->
          kept =
            Enum.filter(
              List.wrap(value(message, :tool_calls)),
              &MapSet.member?(results, value(&1, :id))
            )

          if kept == [] and value(message, :content) in [nil, "", []] do
            []
          else
            [message |> Map.delete("tool_calls") |> Map.put(:tool_calls, kept)]
          end

        _ ->
          [message]
      end
    end)
  end

  defp take_fields(message) do
    Map.new(
      Enum.flat_map(@fields, fn key ->
        case value(message, key) do
          nil ->
            []

          val when key == :trusted_origin ->
            [
              {key,
               Map.drop(val, [
                 "projection_segments",
                 "source_text",
                 :projection_segments,
                 :source_text
               ])}
            ]

          val ->
            [{key, val}]
        end
      end)
    )
  end

  defp remap_calls(message, ids, refs) do
    message =
      if Map.has_key?(message, :tool_calls) do
        Map.update!(message, :tool_calls, fn calls ->
          Enum.map(calls, fn call ->
            call = call |> Map.delete("id") |> Map.put(:id, Map.fetch!(ids, value(call, :id)))
            translate_call(call, refs)
          end)
        end)
      else
        message
      end

    case message[:tool_call_id] do
      nil -> message
      id -> Map.put(message, :tool_call_id, Map.fetch!(ids, id))
    end
  end

  # Only structured declaration fields are translated. Message bodies remain data.
  def remap_declaration(call, refs) do
    Enum.reduce([:ifc, "ifc"], call, fn key, acc ->
      case Map.get(acc, key) do
        %{} = declaration -> Map.put(acc, key, remap_fields(declaration, refs))
        _ -> acc
      end
    end)
  end

  defp remap_fields(declaration, refs) do
    Enum.reduce([:request, "request", :sources, "sources"], declaration, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, values} when is_list(values) ->
          Map.put(acc, key, Enum.map(values, &Map.get(refs, &1, "src:unavailable")))

        {:ok, ref} when is_binary(ref) ->
          Map.put(acc, key, Map.get(refs, ref, "src:unavailable"))

        _ ->
          acc
      end
    end)
  end

  defp local_ref(message, index), do: prefix(message) <> to_string(index)

  defp source_ref(message) do
    id =
      if value(message, :role) == "tool",
        do: value(message, :tool_call_id),
        else: value(message, :id)

    value(message, :projection_source_ref) || prefix(message) <> to_string(id)
  end

  defp prefix(message) do
    case value(message, :role) do
      "user" -> "src:q-"
      "tool" -> "src:t-"
      _ -> "src:a-"
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_, _), do: nil
end
