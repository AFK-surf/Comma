defmodule SalixIM.TaskCompletion do
  @moduledoc false

  # The provider supplies the authenticated Router, never a model parameter.
  # Check the current record inside the Conversation owner's update transaction.
  def router_update(conversation, %{"status" => "completed"} = updates, router_id)
      when is_binary(router_id) do
    cond do
      conversation["kind"] != "agent_task" or
          Map.get(updates, "kind", "agent_task") != "agent_task" ->
        denied("Router completion applies only to Tasks")

      conversation["created_by_agent_id"] != router_id ->
        denied("Only this Task's Router can set completed")

      not is_nil(conversation["workflow"]) ->
        denied("Workflow Tasks must use their Gates and human review")

      is_map(get_in(conversation, ["source_refs", "triage_investigation"])) ->
        denied("Triage completion is product-owned")

      scheduled?(conversation["schedule"]) ->
        denied("A scheduled Task cannot complete after one delivery window")

      conversation["status"] not in ~w(active ready_for_review completed) ->
        denied("Reopen the plain Task before completing it")

      true ->
        :ok
    end
  end

  def router_update(_conversation, _updates, _router_id), do: :ok

  defp scheduled?(nil), do: false
  defp scheduled?(%{"schedule_id" => nil}), do: false
  defp scheduled?(_), do: true

  defp denied(message), do: {:error, {:forbidden, message}}
end
