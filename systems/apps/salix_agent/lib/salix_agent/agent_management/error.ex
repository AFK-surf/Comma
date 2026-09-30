defmodule SalixAgent.AgentManagement.Error do
  @moduledoc false

  @messages %{
    invalid_arguments:
      "Invalid Agent management arguments. Read this tool's help and correct the input.",
    invalid_cursor: "This cursor belongs to another query. Start again with the current filters.",
    forbidden: "Only the Group's Router may manage its visible Workers.",
    agent_not_found: "The Worker is not visible in this Group.",
    agent_configuration_rollout_pending:
      "Agent management is temporarily unavailable until the online rollout finishes. Retry after the release completes; ordinary message execution remains available.",
    agent_configuration_transfer_required:
      "An operator must drain the legacy configuration outbox and transfer this Agent to Salix before changing it.",
    agent_configuration_transfer_in_progress:
      "Agent configuration transfer is in progress. Resume the transfer, then retry.",
    configuration_authority_transferred:
      "This Agent is owned by Salix. Submit the change through the canonical configuration API.",
    agent_archived: "This Worker is archived and cannot be changed by this tool.",
    agent_archiving: "Permanent archive is already accepted. Read agent.get for progress.",
    agent_permanently_archived: "This Worker is permanently archived and cannot be reactivated.",
    unsupported_agent_kind:
      "Rebinding only supports existing external Workers and external targets.",
    target_not_found:
      "The existing runtime target is not available in this scope. Select it through environment management.",
    target_unavailable:
      "The runtime owner rejected this target. Read its status through environment management.",
    target_discovery_required:
      "This existing runtime needs discovery. Page env.runtime_targets to refresh its exact device reference, then retry the same target.",
    selection_changed:
      "The runtime target changed. Refresh its selection through environment management.",
    binding_conflict: "The binding changed. Read agent.get before deciding on a new rebind.",
    worker_default_unavailable:
      "The product's default Worker model is not configured. Configure the Worker default before creating it.",
    management_unavailable:
      "The Agent configuration owner is unavailable. Read agent.get before retrying a write.",
    read_unavailable:
      "Agent information could not be read. This does not mean the Agent or page is empty.",
    mutation_outcome_unknown:
      "The write outcome is unknown. Read the known agent_id or replay this same invocation; do not blindly create another Worker.",
    user_confirmation_required:
      "Obtain the user's explicit confirmation of this Worker's permanent archive before passing user_confirmed=true.",
    invocation_conflict: "The same invocation cannot be reused with different arguments."
  }

  def public({:creation_failed, id, reason}), do: Map.put(public(reason), "agent_id", id)
  def public(%{"code" => _, "message" => _} = issue), do: issue

  def public(reason) do
    code = code(reason)
    %{"code" => Atom.to_string(code), "message" => Map.fetch!(@messages, code)}
  end

  defp code(:not_found), do: :agent_not_found
  defp code(:stale_binding_revision), do: :binding_conflict
  defp code(:binding_revision_conflict), do: :binding_conflict
  defp code({:target_unavailable, _}), do: :target_unavailable
  defp code({:bad_request, _}), do: :invalid_arguments
  defp code({:ambiguous, _}), do: :mutation_outcome_unknown

  defp code(value) when is_binary(value),
    do: Enum.find(Map.keys(@messages), :management_unavailable, &(Atom.to_string(&1) == value))

  defp code(code) when is_map_key(@messages, code), do: code
  defp code(_), do: :management_unavailable
end
