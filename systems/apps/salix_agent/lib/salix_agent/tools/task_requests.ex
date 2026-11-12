defmodule SalixAgent.Tools.TaskRequests do
  @moduledoc """
  A Router asks a Comma Workspace for a Task on behalf of the person it serves
  (Comma Task Requests): another person's, or, for a chat user, their own. The requester is the sender of the
  message the turn answers, from its server-sealed principal, never from the
  model: a Comma user, or a chat user (Slack, ...) linked to a Comma account.
  A chat user without a link gets a link URL to post back to them, and the
  call waits until they open it and sign in to Comma; then it returns, and
  the Router goes on with their request without asking again. The
  product adapter (`:task_request_adapter_mod`) owns accounts, grants and
  limits.
  """

  alias SalixAgent.{CapabilityRequestStore, Waits}
  alias SalixAgent.Tools.AsyncPolicy

  @user_interaction_auto_wait_seconds AsyncPolicy.user_interaction_tool_auto_wait_seconds()
  @normal_auto_wait_seconds AsyncPolicy.normal_tool_auto_wait_seconds()

  def defs do
    [
      {"task_request.targets",
       "List the Comma Workspaces the requester (the person who sent the message you are answering) may send Task requests to: their own (own: true, a workspace_id), which is their Comma, and other people's (a grant_id), with how many they may still send today. " <>
         "A requester from a chat app who has not linked a Comma account gets status link_required and a link_url: post that link to them in this chat at once. The call then waits until they open it and sign in to Comma, and returns linked: go on with what they asked, without asking them again.",
       empty_schema(), &__MODULE__.targets/2, @user_interaction_auto_wait_seconds,
       [safety: "read", roles: ["router"], runtimes: [:internal]]},
      {"task_request.send",
       "Send one Task request from the requester to one Workspace from task_request.targets: their own by its workspace_id, another person's by its grant_id. It waits in that Workspace's Inbox; its owner decides whether and how it runs, and nothing runs until they accept, unless they set that person's requests to accept automatically. " <>
         "Write content as the requester's ask in their words, complete enough to act on without this chat. Tell the requester it was sent and that the receiver decides. A link_required status is answered as in task_request.targets.",
       send_schema(), &__MODULE__.send_request/2, @user_interaction_auto_wait_seconds,
       [safety: "write", roles: ["router"], runtimes: [:internal]]},
      {"task_request.report",
       "Send back the result of a Task request made to the person you serve, once its Task has finished: you were given its request_id with the request. content is all the requester gets: write what answers them and leave out what they need not see. The Task's own words go nowhere unless you put them here. It goes once: a different report later is refused. A request answers through its own finished Task only, the one made with its task_request_id; open one if you have none.",
       report_schema(), &__MODULE__.report/2, @normal_auto_wait_seconds,
       [safety: "write", roles: ["router"], runtimes: [:internal]]}
    ]
  end

  def targets(_args, ctx), do: answer(adapter().targets(ctx), "task_request.targets", ctx)

  def send_request(args, ctx),
    do: answer(adapter().send_request(args, ctx), "task_request.send", ctx)

  def report(args, ctx), do: answer(adapter().report(args, ctx), "task_request.report", ctx)

  defp answer({:ok, result}, _tool, _ctx), do: Jason.encode!(result)

  defp answer({:link_required, link}, tool, ctx), do: await_link(link, tool, ctx)

  defp answer({:error, reason}, _tool, _ctx),
    do: raise("task request rejected: #{inspect(reason)}")

  # The requester has no linked account yet. The call stays open as a
  # capability request until they link it (the product completes it,
  # `SalixAgent.CapabilityRequests.complete_account_link/3`) or it expires; the
  # Agent posts the link meanwhile.
  defp await_link(
         %{"link_url" => url, "link_id" => link_id, "expires_at" => expires_at},
         tool,
         ctx
       ) do
    {:ok, %{tenant: tenant, group_id: group_id}} =
      SalixAgent.OAuthStore.agent_oauth_context(ctx.agent_id)

    session_id = ctx.session_id
    tool_call_id = ctx[:tool_call_id] || random_id()

    {:ok, request} =
      CapabilityRequestStore.create_capability_request(%{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "source_agent_id" => ctx.agent_id,
        "source_session_id" => session_id,
        "tool_call_id" => tool_call_id,
        "request_type" => "account_link",
        "request_payload" => %{"account_link" => %{"link_url" => url, "tool_name" => tool}},
        "expires_at" => expires_at
      })

    :ok =
      adapter().await_link(link_id, %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "request_id" => request["request_id"]
      })

    content =
      Jason.encode!(%{
        "status" => "link_required",
        "tool_call_id" => tool_call_id,
        "link_url" => url,
        "instructions" =>
          "The requester has not linked a Comma account. Post link_url to them in this chat now, through the current reply path. " <>
            "This call returns status linked once they open it and sign in; then go on with what they asked."
      })

    wait =
      Waits.build(
        "account link",
        @user_interaction_auto_wait_seconds,
        "auto_wait",
        %{"tool_call_id" => tool_call_id, "tool_name" => tool}
      )

    {content,
     [
       %{
         "type" => "async_tool_call_started",
         "session_id" => session_id,
         "tool_call_id" => tool_call_id,
         "tool_name" => tool,
         "input" => "{}",
         "status" => "running",
         "completion_mode" => "external_callback",
         "started_at" => SystemsClock.system_time(:millisecond),
         "auto_wait_seconds" => @user_interaction_auto_wait_seconds
       }
       |> Map.merge(CapabilityRequestStore.execution_fields(request)),
       Waits.event(session_id, wait)
     ]}
  end

  defp random_id, do: SystemsRuntime.Proc.random_bytes(8) |> Base.encode16(case: :lower)

  defp adapter do
    case SystemsRuntime.get_env(:salix_agent, :task_request_adapter_mod) do
      nil -> raise "Task requests are not available here"
      module -> module
    end
  end

  defp empty_schema,
    do: %{"type" => "object", "additionalProperties" => false, "properties" => %{}}

  defp report_schema do
    %{
      "type" => "object",
      "properties" => %{
        "request_id" => %{"type" => "string"},
        "task_id" => %{"type" => "string", "description" => "The request's finished Task."},
        "content" => %{"type" => "string"}
      },
      "required" => ["request_id", "task_id", "content"]
    }
  end

  defp send_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["content"],
      "properties" => %{
        "grant_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
        "workspace_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
        "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
        "content" => %{"type" => "string", "minLength" => 1, "maxLength" => 16_000}
      }
    }
  end
end
