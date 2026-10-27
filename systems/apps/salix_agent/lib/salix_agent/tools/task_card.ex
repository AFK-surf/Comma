defmodule SalixAgent.Tools.TaskCard do
  require SystemsRuntime.Proc

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

  def after_create(result, %{trusted_origin: %{"provider" => "qq"} = origin} = ctx) do
    target = origin["provider_context"] || %{}

    if result["created"] == true and origin["source_actor_type"] == "provider_user" and
         is_nil(origin["triage_delegation"]) and origin["agent_group_id"] == ctx[:group_id] and
         present?(origin["source_message_id"]) and
         origin["source_message_id"] == ctx[:source_message_id] and
         target["app_authored"] != true and present?(target["connect_id"]) and
         present?(target["chat_id"]) do
      call = %{
        id: to_string(ctx[:tool_call_id]) <> ":task-card",
        name: "im_api.qq.post_task_card",
        ifc: ctx[:ifc_declaration],
        args: %{
          "connect_id" => target["connect_id"],
          "conversation_id" => result["conversation_id"],
          "chat_id" => target["chat_id"]
        }
      }

      Map.put(result, "task_card", publish_with_budget(call, ctx))
    else
      result
    end
  end

  def after_create(result, %{trusted_origin: %{"provider" => "feishu"} = origin} = ctx) do
    target = origin["provider_context"] || %{}
    chat_type = if target["chat_type"] == "p2p", do: "p2p", else: "group"

    reply_to =
      Enum.find([target["root_message_id"], target["message_id"]], &(is_binary(&1) and &1 != ""))

    if result["created"] == true and origin["source_actor_type"] == "provider_user" and
         is_nil(origin["triage_delegation"]) and origin["agent_group_id"] == ctx[:group_id] and
         is_binary(origin["source_message_id"]) and
         origin["source_message_id"] == ctx[:source_message_id] and
         target["app_authored"] != true and present?(target["connect_id"]) and
         present?(target["chat_id"]) and is_binary(reply_to) do
      call = %{
        id: to_string(ctx[:tool_call_id]) <> ":task-card",
        name: "im_api.feishu.post_task_card",
        ifc: ctx[:ifc_declaration],
        args: %{
          "connect_id" => target["connect_id"],
          "conversation_id" => result["conversation_id"],
          "chat_id" => target["chat_id"],
          "message_id" => reply_to,
          "chat_type" => chat_type
        }
      }

      Map.put(result, "task_card", publish_with_budget(call, ctx))
    else
      result
    end
  end

  # A Task a person asked for in Lark gets its card under that message, or
  # under the root message of its thread.
  def after_create(result, %{trusted_origin: %{"provider" => "lark"} = origin} = ctx) do
    target = origin["provider_context"] || %{}
    chat_type = if target["chat_type"] == "p2p", do: "p2p", else: "group"

    reply_to =
      Enum.find([target["root_message_id"], target["message_id"]], &(is_binary(&1) and &1 != ""))

    if result["created"] == true and origin["source_actor_type"] == "provider_user" and
         is_nil(origin["triage_delegation"]) and origin["agent_group_id"] == ctx[:group_id] and
         is_binary(origin["source_message_id"]) and
         origin["source_message_id"] == ctx[:source_message_id] and
         target["app_authored"] != true and present?(target["connect_id"]) and
         present?(target["chat_id"]) and is_binary(reply_to) do
      call = %{
        id: to_string(ctx[:tool_call_id]) <> ":task-card",
        name: "im_api.lark.post_task_card",
        ifc: ctx[:ifc_declaration],
        args: %{
          "connect_id" => target["connect_id"],
          "conversation_id" => result["conversation_id"],
          "chat_id" => target["chat_id"],
          "message_id" => reply_to,
          "chat_type" => chat_type
        }
      }

      Map.put(result, "task_card", publish_with_budget(call, ctx))
    else
      result
    end
  end

  # A Slack bot or app, a Worker report and a schedule get no Slack card. The
  # kernel adds no card obligation for this status, so a person's Slack reply
  # target that arrives later is not turned into a card that nobody publishes.
  @no_slack_card %{
    "status" => "not_applicable",
    "next_action" => "No Slack Task card is published or required for this Task's source."
  }

  def after_create(result, ctx) do
    case ctx[:trusted_origin] do
      %{"provider" => "slack"} = origin ->
        after_slack_create(result, origin, ctx)

      origin ->
        if result["created"] == true and no_person?(origin),
          do: Map.put(result, "task_card", @no_slack_card),
          else: result
    end
  end

  # The current turn source is the activation's last unanswered person when
  # one is present. A Worker report or a schedule means no person is present.
  # A person keeps the existing card rule.
  defp no_person?(nil), do: true

  defp no_person?(%{"source_actor_type" => type}) when type in ["user", "provider_user"],
    do: false

  defp no_person?(%{} = origin), do: Map.get(origin, "provider") in [nil, "internal"]
  defp no_person?(_origin), do: false

  defp after_slack_create(result, origin, ctx) do
    with true <- result["created"] == true,
         nil <- origin["triage_delegation"],
         true <- origin["agent_group_id"] == ctx[:group_id],
         source when is_binary(source) <- origin["source_message_id"],
         true <- source == ctx[:source_message_id],
         %{} = target <- origin["provider_context"] do
      if origin["source_actor_type"] == "provider_user" and target["app_authored"] != true,
        do: publish_slack_card(result, target, ctx),
        else: Map.put(result, "task_card", @no_slack_card)
    else
      _ -> result
    end
  end

  defp publish_slack_card(result, target, ctx) do
    with connect when is_binary(connect) and connect != "" <- target["connect_id"],
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
      (ctx[:tool_deadline_ms] || SystemsClock.monotonic_time(:millisecond)) -
        SystemsClock.monotonic_time(:millisecond) - 1_000

    if remaining > 0 do
      previous = SystemsRuntime.Proc.trap_exit(true)
      task = SystemsRuntime.Task.async(fn -> publish(call, ctx) end)

      try do
        case SystemsClock.yield(task, remaining) ||
               SystemsRuntime.Task.shutdown(task, :brutal_kill) do
          {:ok, receipt} -> receipt
          _ -> failed_delivery()
        end
      after
        SystemsRuntime.Proc.receive do
          {:EXIT, pid, _} when pid == task.pid -> :ok
        after
          0 -> :ok
        end

        SystemsRuntime.Proc.trap_exit(previous)
      end
    else
      failed_delivery()
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

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
