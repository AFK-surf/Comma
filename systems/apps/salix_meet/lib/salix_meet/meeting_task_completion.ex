defmodule SalixMeet.MeetingTaskCompletion do
  @moduledoc false

  alias SalixMeet.MeetingPlan

  def finish(state) do
    case {get_in(state, ["source", "meeting_plan_id"]), state["status"]} do
      {plan_id, status} when is_binary(plan_id) and status in ~w(done failed cancelled) ->
        case MeetingPlan.get(state["group_id"], plan_id) do
          {:ok, plan} ->
            MeetingPlan.finish_conversation(
              plan,
              if(status == "done", do: "completed", else: status)
            )

          {:error, :not_found} ->
            :ok

          {:error, _} = error ->
            error
        end

      _ ->
        :ok
    end
  end
end
