defmodule CommaWeb.CollaborationNotice do
  @moduledoc """
  What the people of a Task together hear of it in their own Home: its status,
  never what is said in it (`Comma.Collaborations`). No one's Router is in the
  Task, and none reads it (`SalixIM.Provider.Internal`).

  Its host hears that it failed, or that a member left or declined; not what
  the host did themselves (marking it Done, removing someone). Each member on
  Comma hears that it is done or failed, in their own Workspace's Home. A seat
  no account took yet hears nothing here (its invitation is an email).

  Each notice is one fixed Router Message (the host's with a reference to the
  Task, which is in the host's Group) and the same fact as Router context that
  does not wake it, so asked about the Task the Router gives its status and
  nothing more. No model runs. One notice per status version and person, or per
  member's answer.
  """
  use Oban.Worker, queue: :comma_external, max_attempts: 5

  import Ecto.Query

  alias Comma.Data.TaskCollaborator
  alias Comma.Repo
  alias SalixIM.{ConversationServer, Conversations, RouterConversationInput}

  @statuses ~w(completed failed)
  @member_statuses ~w(left declined)

  @doc "Salix's status observer for a Task together. Queues one notice per status version."
  def task_status_changed(%{"agent_group_id" => group, "conversation_id" => task} = snapshot)
      when is_binary(group) and is_binary(task) do
    if snapshot["status"] in @statuses,
      do:
        enqueue(%{
          "op" => "status",
          "group_id" => group,
          "task_id" => task,
          "status" => snapshot["status"],
          "version" => snapshot["provider_status_version"] || 0
        }),
      else: :ok
  end

  def task_status_changed(_snapshot), do: :ok

  @doc "A member answered (`declined`) or left (`left`): queues one notice to the host."
  def member_changed(%{"id" => id, "status" => status}) when status in @member_statuses,
    do: enqueue(%{"op" => "member", "collaborator_id" => id, "status" => status})

  def member_changed(_row), do: :ok

  defp enqueue(args) do
    case args
         |> new(
           unique: [
             period: :infinity,
             fields: [:worker, :args],
             states: [:available, :scheduled, :executing, :retryable, :completed]
           ]
         )
         |> then(&Oban.insert(Comma.Oban, &1)) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, {:collaboration_notice_enqueue, reason}}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"op" => "status"} = args}) do
    with {:ok, task} <-
           Conversations.get_group_conversation_record(args["group_id"], args["task_id"]),
         true <- Conversations.collaboration_task?(task),
         # Told only while the Task is still in the status the notice names.
         true <- task["status"] == args["status"],
         [%TaskCollaborator{} = row | _] = rows <- seats(args["group_id"], args["task_id"]) do
      key = "collaboration-status:#{row.conversation_id}:#{args["status"]}:#{args["version"]}"
      # The host is not told of what they did themselves.
      host =
        if host_marked?(task), do: :ok, else: tell(:host, row, task, args["status"], nil, key)

      # Each person in it who is on Comma hears it in their own Home; a seat no
      # account took yet has no Home.
      members =
        for %TaskCollaborator{status: "active", user_id: user_id} <- rows, is_binary(user_id) do
          tell({:member, user_id}, row, task, args["status"], nil, key <> ":" <> user_id)
        end

      Enum.find([host | members], :ok, &match?({:error, _}, &1))
    else
      _ -> :ok
    end
  end

  def perform(%Oban.Job{args: %{"op" => "member", "collaborator_id" => id, "status" => status}}) do
    with %TaskCollaborator{status: ^status} = row <- Repo.get(TaskCollaborator, id),
         {:ok, task} <-
           Conversations.get_group_conversation_record(row.group_id, row.conversation_id),
         {:ok, member_name} <- member_display_name(row) do
      tell(:host, row, task, status, member_name, "collaboration-member:#{id}:#{status}")
    else
      _ -> :ok
    end
  end

  def perform(_job), do: :ok

  defp member_display_name(%TaskCollaborator{user_id: user_id}) when is_binary(user_id) do
    case Comma.Accounts.get_user(user_id) do
      {:ok, member} -> {:ok, member["name"] || ""}
      error -> error
    end
  end

  defp member_display_name(%TaskCollaborator{guest_name: name, invited_email: email}) do
    display =
      cond do
        is_binary(name) and String.trim(name) != "" -> String.trim(name)
        is_binary(email) and String.trim(email) != "" -> String.trim(email)
        true -> "Anonymous"
      end

    {:ok, display}
  end

  # The host marked it Done or cancelled it themselves: nothing to tell them.
  defp host_marked?(task),
    do: get_in(task, [SalixIM.TaskManualStatus.field(), "status"]) == task["status"]

  # A Task's seats: at most the people it was started with (`Comma.Collaborations`).
  defp seats(group_id, task_id) do
    from(c in TaskCollaborator,
      where: c.group_id == ^group_id and c.conversation_id == ^task_id
    )
    |> Repo.all()
  end

  # Whose Home hears it: the host's real Workspace Home default Group (never the
  # isolated collaboration Group), with a reference to the Task; or a member's,
  # in their own Workspace, in words alone.
  defp home(:host, row) do
    case Comma.Workspaces.collaboration_host(row.workspace_id) do
      {:ok, %{"default_group_id" => group}} when is_binary(group) ->
        {:ok, group, Comma.Accounts.agent_context(row.host_user_id, row.workspace_id)["locale"],
         true}

      _ ->
        :none
    end
  end

  defp home({:member, user_id}, _row) do
    case Comma.Workspaces.list_for_user(user_id) do
      {:ok, [%{"kind" => "standard", "default_group_id" => group} = workspace | _]}
      when is_binary(group) ->
        {:ok, group, Comma.Accounts.agent_context(user_id, workspace["id"])["locale"], false}

      _ ->
        :none
    end
  end

  defp tell(audience, row, task, status, member, key) do
    title = title(row, task)
    role = if audience == :host, do: :host, else: :member

    with {:ok, group, locale, ref?} <- home(audience, row),
         {:ok, home} <- RouterConversationInput.ensure(group),
         {:ok, _message} <-
           ConversationServer.append_group_conversation_agent_message(
             group,
             home["conversation_id"],
             home["router_agent_id"],
             %{
               "content" =>
                 [%{"type" => "text", "text" => text(role, status, title, member, locale)}] ++
                   if(ref?,
                     do: [
                       %{
                         "type" => "conversation_ref",
                         "conversation_id" => row.conversation_id,
                         "group_id" => row.group_id,
                         "kind" => "agent_task",
                         "presentation" => "inline"
                       }
                     ],
                     else: []
                   ),
               "client_request_id" => key,
               "metadata" => %{
                 "message_type" => "collaboration_status",
                 "task_id" => row.conversation_id,
                 "group_id" => row.group_id,
                 "status" => status
               }
             }
           ),
         {:ok, _} <-
           RouterConversationInput.append_provider_input(
             group,
             key,
             %{
               content: router_context(role, status, title, member, row.conversation_id),
               name: "Comma",
               role: "user",
               no_wake: true
             },
             %{"provider" => "comma", "event_type" => "collaboration_status"}
           ) do
      :ok
    else
      # No Home to tell (a member without a Workspace of their own yet).
      :none -> :ok
      {:error, _} = error -> error
    end
  end

  # The title the host gave it when they started it, else the Task's.
  defp title(%TaskCollaborator{title: title}, _task) when is_binary(title) and title != "",
    do: title

  defp title(_row, task), do: task["title"] || ""

  defp text(:host, "completed", title, _member, "zh-CN"), do: "「#{title}」已完成。"
  defp text(:host, "failed", title, _member, "zh-CN"), do: "「#{title}」出错停下了，需要你看一下。"
  defp text(:host, "left", title, member, "zh-CN"), do: "#{member} 退出了「#{title}」。"
  defp text(:host, "declined", title, member, "zh-CN"), do: "#{member} 没有加入「#{title}」。"
  defp text(:member, "completed", title, _member, "zh-CN"), do: "「#{title}」已完成。"
  defp text(:member, "failed", title, _member, "zh-CN"), do: "「#{title}」出错停下了。"

  defp text(:host, "completed", title, _member, _locale), do: "\"#{title}\" is done."

  defp text(:host, "failed", title, _member, _locale),
    do: "\"#{title}\" stopped with an error and needs you."

  defp text(:host, "left", title, member, _locale), do: "#{member} left \"#{title}\"."
  defp text(:host, "declined", title, member, _locale), do: "#{member} declined \"#{title}\"."

  defp text(:member, "completed", title, _member, _locale), do: "\"#{title}\" is done."
  defp text(:member, "failed", title, _member, _locale), do: "\"#{title}\" stopped with an error."

  defp router_context(role, status, title, member, task_id) do
    change =
      case status do
        "completed" ->
          "it is done"

        "failed" ->
          "it stopped with an error"

        "left" ->
          "#{member} left it"

        "declined" ->
          "#{member} declined to join it"
      end

    whose =
      if role == :host,
        do: "which the user hosts with other people",
        else: "which another person hosts and the user takes part in"

    "Comma posted this in Home for the user: in the Task together \"#{title}\" " <>
      "(conversation #{task_id}), #{whose}, #{change}. " <>
      "This is its status only. You cannot read that Task: what is said in it belongs to its " <>
      "people. If the user asks about it, give this status and point them to the Task; " <>
      "do not guess or summarize its content. This is context only, not a request."
  end
end
