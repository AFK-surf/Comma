defmodule SalixIM.TeamsAdmission do
  @moduledoc "Teams eligibility before accepting new work into a Conversation."

  def authorize_group(group) do
    case {SystemsRuntime.get_env(:salix_im, :teams_access_mod), group["billing_owner"]} do
      {nil, %{"surface" => "bridge"}} ->
        {:error, :teams_billing_unavailable}

      {access, %{"surface" => "bridge", "billing_account_id" => account}} ->
        case access.check(account) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  def new_work?(message) do
    message["actor_type"] in ["user", "provider_user"] or
      is_map(message["agent_input"]) or
      is_map(get_in(message, ["metadata", "task_schedule"]))
  end
end
