defmodule SalixAgent.IFC.ProjectionRequest do
  @moduledoc "Authenticated request-domain selection and request-local IFC projection."
  alias SalixAgent.{IFC, InternalSession}
  alias SalixAgent.IFC.{ContextProjection, Context}
  alias SalixIFC.{Codec, Label}

  def prepare(session, delta, config, ctx) do
    if IFC.mode_for(config.tenant_id, config.group_id) == :enforce do
      origins = InternalSession.query(session, :ifc_projection_origins)
      labels = target_labels(origins, ctx)
      messages = InternalSession.query(session, :ifc_projection_input)
      # Unlabelled activation reminders are not a source of public facts.
      messages = messages ++ Enum.map(List.wrap(delta && delta[:messages]), &runtime_message/1)

      atoms =
        Enum.flat_map(messages, fn message ->
          segments =
            get_in(message, [:trusted_origin, "projection_segments"]) ||
              get_in(message, ["trusted_origin", "projection_segments"]) || []

          Codec.encode_label(ContextProjection.label(message)) ++
            Enum.flat_map(segments, &List.wrap(&1["label"]))
        end) ++
          List.flatten(labels)

      request = %{
        "tenant_id" => config.tenant_id,
        "group_id" => config.group_id,
        "agent_id" => ctx.agent_id,
        "session_id" => ctx.session_id,
        "requester" => get_in(ctx[:trusted_origin] || %{}, ["ifc", "principal"]),
        "destination" => %{"kind" => "public"},
        "atoms" => Enum.uniq(atoms),
        "trusted_origin" => ctx[:trusted_origin],
        "now" => SystemsClock.system_time(:millisecond)
      }

      {destinations, facts} =
        case IFC.resolve(request) do
          {:ok, reply} ->
            {Enum.map(labels, &Codec.decode_label(&1, Context.private())),
             Codec.decode_facts(reply)}

          _ ->
            {[], SalixIFC.Facts.new()}
        end

      projection = ContextProjection.project(messages, destinations, facts)

      capped? =
        SalixAgent.IFC.HardConvergence.finish?(
          projection,
          InternalSession.get(session, :async_tool_calls) || %{}
        )

      projection
      |> Map.put(:prompt, config[:ifc_static_prompt] || "")
      |> Map.put(:finish_only, capped?)
      |> Map.put(:destinations, destinations)
      |> Map.put(:facts, facts)
    else
      nil
    end
  end

  defp target_labels(origins, ctx) do
    labels = Enum.map(origins, &get_in(&1, ["ifc", "label"]))

    if labels != [] and Enum.all?(labels, &match?({:ok, %Label{}}, Codec.decode_label(&1))) do
      labels
    else
      delegated_targets(ctx)
    end
  end

  defp delegated_targets(ctx) do
    mod = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)

    if is_atom(mod) and not is_nil(mod) and function_exported?(mod, :ifc_projection_targets, 1) do
      origins = List.wrap(ctx[:trusted_origins] || ctx[:trusted_origin])

      Enum.reduce_while(origins, [], fn origin, targets ->
        local =
          ctx
          |> Map.put(:trusted_origin, origin)
          |> Map.put(:source_message_id, origin["source_message_id"])

        case mod.ifc_projection_targets(local) do
          {:ok, [_ | _] = next} -> {:cont, targets ++ next}
          _ -> {:halt, []}
        end
      end)
    else
      []
    end
  end

  defp runtime_message(payload) do
    %{
      role: "runtime",
      content: payload[:content] || payload["content"] || payload[:summary] || payload["summary"],
      ifc: payload[:ifc] || payload["ifc"]
    }
  end
end
