defmodule SalixAgent.IFC.Triage do
  @moduledoc """
  Effect-local command authority for a product-authored Triage Task handoff.

  The incoming alert remains data. Only the exact admitted handoff can supply
  a synthetic system command, and only for an ordinary one-shot Task creation.
  The provider still revalidates the immutable obligation, current target and
  source freshness before creating anything. No public reply gains authority.
  """

  alias SalixAgent.ToolCallProvenance

  def prepare(call, declaration, ctx) do
    wire = ctx[:ifc]

    with "im_api.internal.task.create" <- call[:name] || call["name"],
         "router" <- ctx[:role],
         %{} = args <- call[:args] || call["args"],
         ref when is_binary(ref) and ref != "" <- args["triage_delegation_ref"],
         nil <- args["schedule"],
         {:ok, selected} <- ToolCallProvenance.select(call, ctx),
         %{"provider" => "slack"} <- selected[:trusted_origin],
         %{"items" => items} <- wire,
         [source] <- Enum.filter(items, &(&1["source_message_id"] == ref)),
         true <- declaration.request in [nil, source["ref"]],
         command_ref = "ifc:triage-command:" <> ref,
         false <- Enum.any?(items, &(&1["ref"] == command_ref)) do
      command = %{
        "ref" => command_ref,
        "label" => source["label"],
        "integrity" => "command",
        "principal" => "system"
      }

      wire =
        Map.merge(wire, %{
          "items" => items ++ [command],
          "request" => command_ref,
          "requester" => "system",
          "source_scope" => source["label"],
          "consumed_refs" => [command_ref]
        })

      {wire, %{declaration | request: command_ref}}
    else
      _ -> {wire, declaration}
    end
  end
end
