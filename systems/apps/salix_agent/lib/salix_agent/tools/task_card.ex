defmodule SalixAgent.Tools.TaskCard do
  @moduledoc false

  # Use the same authorization, archive, timeout and provider delivery path as
  # an explicit provider tool call. Only an admitted human source supplies
  # the destination. A worker result cannot publish a new Task surface.
  def after_create(result, %{trusted_origin: %{"provider" => "telegram"}} = ctx) do
    origin = ctx.trusted_origin
    target = origin["provider_context"] || %{}

    if result["created"] == true and origin["source_actor_type"] == "provider_user" and
         origin["agent_group_id"] == ctx[:group_id] and
         origin["source_message_id"] == ctx[:source_message_id] and
         target["chat_type"] == "private" and target["app_authored"] != true do
      call = %{
        id: to_string(ctx[:tool_call_id]) <> ":task-topic",
        name: "im_api.telegram.open_task_topic",
        ifc: ctx[:ifc_declaration],
        args: %{
          "connect_id" => target["connect_id"],
          "conversation_id" => result["conversation_id"],
          "chat_id" => target["chat_id"]
        }
      }

      receipt = publish_with_budget(call, ctx)

      receipt =
        if receipt["status"] == "failed",
          do:
            Map.put(
              receipt,
              "next_action",
              "The Task exists. Check open_task_topic for this conversation_id only; never recreate the Task. An uncertain topic creation requires operator recovery."
            ),
          else: receipt

      Map.put(result, "task_topic", receipt)
    else
      result
    end
  end

  def after_create(result, ctx) do
    with true <- result["created"] == true,
         %{} = origin <- ctx[:trusted_origin],
         "slack" <- origin["provider"],
         "provider_user" <- origin["source_actor_type"],
         nil <- origin["triage_delegation"],
         true <- origin["agent_group_id"] == ctx[:group_id],
         source when is_binary(source) <- origin["source_message_id"],
         true <- source == ctx[:source_message_id],
         %{} = target <- origin["provider_context"],
         false <- target["app_authored"] == true,
         connect when is_binary(connect) and connect != "" <- target["connect_id"],
         channel when is_binary(channel) and channel != "" <- target["channel_id"],
         thread when is_binary(thread) and thread != "" <-
           target["thread_ts"] || target["message_ts"] do
      call = %{
        id: to_string(ctx[:tool_call_id]) <> ":task-card",
        name: "im_api.slack.post_task_card",
        # The card projects the created Task, not unrelated session history.
        # Keep the create call's dependencies, including private ones.
        ifc: ctx[:ifc_declaration],
        args: %{
          "connect_id" => connect,
          "conversation_id" => result["conversation_id"],
          "channel" => channel,
          "thread_ts" => thread
        }
      }

      Map.put(result, "task_card", publish_with_budget(call, ctx))
    else
      _ -> result
    end
  end

  # Reserve time to return the committed Task receipt before the parent tool
  # deadline. Bound the whole child dispatch, including authorization.
  defp publish_with_budget(call, ctx) do
    remaining =
      (ctx[:tool_deadline_ms] || System.monotonic_time(:millisecond)) -
        System.monotonic_time(:millisecond) - 1_000

    if remaining > 0 do
      previous = Process.flag(:trap_exit, true)
      task = Task.async(fn -> publish(call, ctx) end)

      try do
        case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
          {:ok, receipt} -> receipt
          _ -> failed_delivery()
        end
      after
        receive do
          {:EXIT, pid, _} when pid == task.pid -> :ok
        after
          0 -> :ok
        end

        Process.flag(:trap_exit, previous)
      end
    else
      failed_delivery()
    end
  end

  defp failed_delivery do
    %{
      "status" => "failed",
      "error" => "Task card delivery did not complete within the remaining create budget",
      "next_action" => "The Task exists. Retry only post_task_card with its conversation_id."
    }
  end

  defp publish(call, ctx) do
    case SalixAgent.SessionToolDispatch.execute(
           [call],
           ctx
           |> Map.delete(:calls_prepared)
           |> Map.delete(:defer_tool_observations)
           |> Map.put(:llm_tool_envelope, false)
         ) do
      [%{content: content} = receipt] ->
        case Jason.decode(content) do
          {:ok, %{"status" => "ready", "message_thread_id" => _} = details} ->
            details

          {:ok, %{"delivery_status" => status} = details}
          when status in ["queued", "delivered"] ->
            details
            |> Map.put("status", status)
            |> Map.put("target", call.args)

          _ ->
            %{
              "status" => "failed",
              "error" => receipt[:error_class] || content,
              "next_action" =>
                "The Task exists. Retry only post_task_card with its conversation_id."
            }
        end
    end
  rescue
    error ->
      %{
        "status" => "failed",
        "error" => Exception.message(error),
        "next_action" => "The Task exists. Retry only post_task_card with its conversation_id."
      }
  catch
    :exit, _ ->
      %{
        "status" => "failed",
        "error" => "Task card delivery interrupted",
        "next_action" => "The Task exists. Retry only post_task_card with its conversation_id."
      }
  end
end
