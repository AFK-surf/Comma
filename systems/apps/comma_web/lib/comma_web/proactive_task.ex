defmodule CommaWeb.ProactiveTask do
  @moduledoc """
  Tasks that need their owner, as proactive matters.

  Salix calls `task_status_changed/1` when it publishes the status of an owned
  Task. A Task that becomes escalated or failed is handed to the owner's Router
  as a Home matter, like an arrived source item: the Router alone decides
  whether to notify. One escalation hands over once. The matter closes when the
  Task leaves that status, or when the owner has answered in the Task.

  The matter key is `["task", task_id]`. Its observation is the status and the
  Task's message position when the status was entered, so a later escalation
  starts new attention and a title change does not.
  """
  use Oban.Worker, queue: :comma_external, max_attempts: 5

  require Logger
  alias CommaWeb.HomeMail
  alias SalixIM.{ConversationServer, Conversations, MailInteraction}

  @attention ~w(escalated failed)
  @account "task"
  # Open task matters checked for an owner reply per collection.
  @reconcile_limit 8
  @read_tail 12

  @doc """
  The Salix status observer. Queues one check of the Task. Returning an error
  keeps Salix's publication recovery, so the observation is retried.
  """
  def task_status_changed(%{"agent_group_id" => group, "conversation_id" => task} = snapshot)
      when is_binary(group) and is_binary(task) do
    # Only a Task that needs its owner queues work here. A Task that moves on
    # closes its matter at the next collection (`reconcile/3`), so other
    # status changes, of every product's Tasks, touch no Comma state.
    if snapshot["status"] in @attention, do: enqueue(group, task, snapshot), else: :ok
  end

  def task_status_changed(_snapshot), do: :ok

  defp enqueue(group, task, snapshot) do
    args = %{
      "group_id" => group,
      "task_id" => task,
      "version" => snapshot["provider_status_version"] || 0
    }

    case args
         # Salix re-runs status publication recovery after every message, with
         # the same status version. One check per version, also once it ran.
         |> new(
           unique: [
             period: :infinity,
             fields: [:worker, :args],
             states: [:available, :scheduled, :executing, :retryable, :completed]
           ]
         )
         |> then(&Oban.insert(Comma.Oban, &1)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:task_attention_enqueue, reason}}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"group_id" => group, "task_id" => task_id}}) do
    with {:ok, task} <- Conversations.get_group_conversation_record(group, task_id),
         %{"kind" => "agent_task", "owner_user_id" => owner} when is_binary(owner) <- task,
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(owner),
         {:ok, workspace, ctx, home} <- HomeMail.context(user, %{}, group),
         true <- workspace["owner_user_id"] == owner do
      case apply_status(ctx, home, owner, task) do
        {:error, :proactive_budget_exhausted} -> {:snooze, 15 * 60}
        {:error, :mail_operation_pending} -> {:snooze, 30}
        {:error, reason} when reason in [:proactive_disabled, :mail_source_handled] -> :ok
        {:error, _} = error -> error
        _ -> :ok
      end
    else
      # The Task, its owner or the owner's workspace is gone: nothing to tell.
      _ -> :ok
    end
  end

  @doc """
  Closes the owner's open task matters that the owner already answered or
  whose Task moved on. The collection chain calls it; it reads at most
  #{@reconcile_limit} matters from Home metadata and never lists Tasks.
  """
  def reconcile(ctx, home, owner) do
    with {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home) do
      conversation
      |> MailInteraction.entries()
      # Matters whose Task has not been seen leaving: open ones, and handled
      # ones that must still record the leave to re-arm the next escalation.
      |> Enum.filter(fn {_key, value} ->
        value["owner_id"] == owner and value["account_id"] == @account and
          not String.starts_with?(value["message_id"] || "", "left:")
      end)
      |> Enum.take(@reconcile_limit)
      |> Enum.each(fn {_key, value} ->
        with {:ok, task} <-
               Conversations.get_group_conversation_record(ctx.group_id, value["thread_id"]) do
          cond do
            task["status"] not in @attention ->
              ctx |> close(home, owner, task, value, "left:" <> version(task)) |> log_close()

            value["state"] not in ~w(handled quiet) and
                answered?(ctx.group_id, task, owner, value) ->
              ctx |> close(home, owner, task, value, value["message_id"]) |> log_close()

            true ->
              :ok
          end
        end
      end)
    end

    :ok
  end

  defp apply_status(ctx, home, owner, task) do
    with {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home) do
      key = MailInteraction.key(@account, task["conversation_id"])
      current = MailInteraction.entries(conversation)[key]

      cond do
        task["status"] in @attention ->
          observation = task["status"] <> ":" <> Integer.to_string(task["message_tail_seq"] || 0)

          # The same escalation hands over once, also after the owner answered;
          # a title change is no new need. Leaving the status re-arms it.
          if is_map(current) and
               String.starts_with?(current["message_id"] || "", task["status"] <> ":"),
             do: :ok,
             else: present(ctx, home, owner, task, key, current, observation)

        # Leaving is recorded even when the matter was already handled, so the
        # next escalation of the same status starts new attention.
        is_map(current) and not String.starts_with?(current["message_id"] || "", "left:") ->
          close(ctx, home, owner, task, current, "left:" <> version(task))

        true ->
          :ok
      end
    end
  end

  defp present(ctx, home, owner, task, key, current, observation) do
    id = task["conversation_id"]

    command = %{
      "action" => "present",
      "automatic" => true,
      "urgency" => "high",
      "key" => key,
      # A repeated status later in the Task is a new escalation: its status
      # version, not only its observation, names the handoff.
      "request_id" =>
        "task:" <>
          Base.encode16(:crypto.hash(:sha256, key <> observation <> ":" <> version(task)),
            case: :lower
          ),
      "generation" => if(is_map(current), do: current["generation"]),
      "account_id" => @account,
      "thread_id" => id,
      "message_id" => observation,
      "subject" => task["title"] || "",
      "source_url" => "",
      "task_id" => id,
      "read" => %{
        "tool" => "im_api.internal.read_conversation",
        "arguments" => %{
          "connect_id" => "internal",
          "conversation_id" => id,
          "tail" => @read_tail
        }
      },
      "text" => text(task)
    }

    ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, command)
  end

  defp close(ctx, home, owner, task, value, observation) do
    ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, %{
      "action" => "handled",
      "key" => MailInteraction.key(@account, task["conversation_id"]),
      "generation" => value["generation"],
      "request_id" => "task-closed:" <> task["conversation_id"] <> ":" <> observation,
      "message_id" => observation
    })
  end

  # A reconcile close that loses a race is tried again at the next collection.
  defp log_close({:error, reason}),
    do: Logger.info("proactive_task close skipped reason=#{inspect(reason)}")

  defp log_close(_result), do: :ok

  # The owner wrote in the Task after it asked for them.
  defp answered?(group, task, owner, value) do
    since =
      case String.split(value["message_id"] || "", ":") do
        [_status, seq] -> String.to_integer(seq)
        _ -> task["message_tail_seq"] || 0
      end

    case Conversations.list_group_conversation_messages(group, task["conversation_id"],
           tail: 5,
           limit: 5
         ) do
      {:ok, messages} ->
        Enum.any?(messages, fn message ->
          message["kind"] == "message" and message["actor_type"] == "user" and
            message["user_id"] == owner and (message["seq"] || 0) > since
        end)

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp version(task), do: Integer.to_string(task["provider_status_version"] || 0)

  # Evidence for the Router, never sent as is. The Router reads the Task itself.
  defp text(%{"status" => "failed"} = task),
    do: "The Task \"#{task["title"]}\" failed and may need the owner to decide what happens next."

  defp text(task),
    do: "The Task \"#{task["title"]}\" stopped and asks the owner for a decision or input."
end
