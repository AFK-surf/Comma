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
      "Rebinding only moves a Worker bound to a station to another station target, {kind: station, device_id} or {kind: cloud_vm}.",
    external_runtime_retired:
      "External runtime Workers are retired. Create a Worker bound to a station instead: runtime {kind: station, device_id} or {kind: cloud_vm}, with model {kind: runtime, provider: codex | claude, model?}.",
    station_model_required:
      "A Worker bound to a station needs model {kind: runtime, provider: codex | claude}, with an optional model id that station runs (its task_models in device.get), and an optional reasoning_effort.",
    target_not_found:
      "The existing runtime target is not available in this scope. Select it through environment management.",
    target_unavailable:
      "The runtime owner rejected this target. Read its status through environment management.",
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
    invocation_conflict: "The same invocation cannot be reused with different arguments.",
    invalid_model_configuration:
      "This model choice is not valid here. Choose a model from agent.models, a reasoning_effort from its efforts, and a profile_id only for a Profile that serves it.",
    model_not_allowed:
      "The organization does not allow this model choice. Ask the user to pick another model and effort, or an organization admin to allow it.",
    model_selection_unsupported:
      "This product does not let the Router choose a Worker model. Omit model to use the product default.",
    model_catalog_too_large:
      "The workspace has too many model choices in use. Reuse an existing Worker or create this one without model."
  }

  def public({:creation_failed, id, reason}), do: Map.put(public(reason), "agent_id", id)

  def public({:runtime_not_ready, reason}) do
    {reason, message} = runtime_issue(reason)
    %{"code" => "target_unavailable", "reason" => reason, "message" => message}
  end

  def public(%{"error_class" => "billing_unavailable"} = issue),
    do: Map.put(issue, "code", "billing_unavailable")

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

  defp runtime_issue("authentication_required"),
    do:
      {"authentication_required",
       "The selected runtime needs login. Log in to that installation, then retry the same target."}

  defp runtime_issue("permission_required"),
    do: {"permission_required", "Set this device's Access to Full, then retry the same target."}

  defp runtime_issue("connector_disconnected"),
    do:
      {"connector_disconnected",
       "The selected device disconnected during its check. Reconnect it, then retry the same target."}

  defp runtime_issue("runtime_probe_timeout"),
    do:
      {"runtime_probe_timeout",
       "The selected runtime did not finish its check in time. Retry the same target."}

  defp runtime_issue("native_server_unavailable"),
    do:
      {"native_server_unavailable",
       "The selected runtime could not start its native interface. Check that installation, then retry the same target."}

  defp runtime_issue("model_unavailable"),
    do:
      {"model_unavailable",
       "The selected runtime cannot use its configured model. Check its model configuration, then retry the same target."}

  defp runtime_issue("workspace_unavailable"),
    do:
      {"workspace_unavailable",
       "The selected runtime cannot access its workspace. Check the device workspace, then retry the same target."}

  defp runtime_issue(_),
    do:
      {"runtime_probe_failed",
       "The selected runtime did not pass its readiness check. Read its device status before retrying the same target."}
end
