defmodule AlertRouter.Slack.Interactions do
  @moduledoc "Slack users claim and transfer the existing Incident owner."
  import Ecto.Query
  alias AlertRouter.{Repo, Telemetry}
  alias AlertRouter.Data.Incident
  alias AlertRouter.Slack.{Progress, Renderer}

  def accept(payload) do
    Telemetry.observe(:progress, :slack, fn -> accept_action(payload) end)
  end

  defp accept_action(%{
         "type" => "block_actions",
         "team" => %{"id" => team},
         "api_app_id" => app,
         "user" => %{"id" => user},
         "container" => %{"channel_id" => channel, "message_ts" => root},
         "actions" => [action]
       })
       when is_map(action) and is_binary(channel) and is_binary(root) do
    config = Application.get_env(:alert_router, :slack_progress, [])

    if Progress.enabled?() and team == config[:team_id] and app == config[:app_id] and
         Application.get_env(:alert_router, :mode) != :disabled and valid_user?(user) do
      Repo.transaction(fn ->
        incident =
          Repo.one(
            from(i in Incident,
              where: i.channel_id == ^channel and i.slack_root_ts == ^root,
              lock: "FOR UPDATE"
            )
          )

        case checked_change(incident, user, action) do
          {:ok, owner} ->
            updated = Progress.update_card(incident, %{owner: owner})

            AlertRouter.Slack.Notices.record(
              updated,
              "ownership",
              "负责人：#{owner}（由 #{user} 接手或转交）"
            )

            :accepted

          {:feedback, outcome} ->
            feedback = %{
              "outcome" => outcome,
              "author" => user,
              "at" => DateTime.to_iso8601(DateTime.utc_now())
            }

            updated = Progress.update_card(incident, %{feedback: feedback})

            AlertRouter.Slack.Notices.record(
              updated,
              "feedback",
              "#{user} 标记：#{Renderer.feedback_label(outcome)}（处理反馈，不替代恢复验证）"
            )

            :accepted

          result ->
            result
        end
      end)
    else
      {:error, :unauthorized}
    end
  end

  defp accept_action(_), do: {:ok, :ignored}

  defp checked_change(nil, _, _), do: :ignored

  defp checked_change(incident, user, action) do
    expected =
      "ar-#{Renderer.incident_id(incident.incident_key)}-r#{incident.desired_revision}-ownership"

    if action["block_id"] == expected,
      do: change_handling(incident, user, action),
      else: :stale_card
  end

  defp change_handling(%{owner: nil}, user, %{"action_id" => "alert_claim"}), do: {:ok, user}

  defp change_handling(%{owner: owner}, user, %{"action_id" => "alert_claim"}) do
    if owner == user, do: :unchanged, else: :already_owned
  end

  defp change_handling(%{owner: owner}, user, %{
         "action_id" => "alert_transfer",
         "selected_user" => target
       }) do
    cond do
      owner != user -> :not_owner
      target == owner -> :unchanged
      valid_user?(target) -> {:ok, target}
      true -> :ignored
    end
  end

  defp change_handling(incident, user, %{
         "action_id" => "alert_feedback",
         "selected_option" => %{"value" => outcome}
       })
       when outcome in ["needs_action", "self_recovered", "false_positive"] do
    if incident.feedback["outcome"] == outcome and incident.feedback["author"] == user,
      do: :unchanged,
      else: {:feedback, outcome}
  end

  defp change_handling(_, _, _), do: :ignored

  defp valid_user?(user), do: is_binary(user) and Regex.match?(~r/\A[UW][A-Z0-9]{1,32}\z/, user)
end
