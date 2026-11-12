defmodule CommaWeb.TaskRequestTools do
  @moduledoc """
  The Comma side of the `task_request.*` Router tools (`SalixAgent.Tools.TaskRequests`).

  The requester is the sender of the message the turn answers, from its
  server-sealed principal (`SalixAgent.IFC.principal/1`):

    * a chat user of a provider connect (Slack, ...): the Comma account linked
      to them (`Comma.ProviderUserLinks`); without one the tools answer
      `link_required` with a link for the Router to post them, and wait
      until they link it;
    * a Comma user, only in their own Workspace's Group: the Workspace owner
      asking their own Router.

  Everything else (who may receive, limits, what runs) is `Comma.TaskRequests`
  with the requester as the signed-in sender. A chat user's own Workspaces are
  targets too, without a grant: the Router is how they reach their own Comma.

  It is also Salix IM's way to send one a person asked for by naming the
  recipient in their Router chat (`SalixIM.Ports.TaskRequests`,
  `SalixIM.RequestMention`): there the requester is the message's author,
  only in their own Workspace's Group.
  """

  @behaviour SalixIM.Ports.TaskRequests

  alias Comma.{ProviderUserLinks, TaskRequests}

  @link_path "/#/settings?category=task-requests&link="

  def targets(ctx) do
    with {:ok, user} <- requester(ctx),
         {:ok, own} <- own_targets(user, ctx),
         {:ok, targets} <- TaskRequests.list_targets(user, %{}) do
      {:ok,
       %{
         "status" => "ok",
         "targets" =>
           Enum.map(own, &Map.put(&1, "own", true)) ++
             Enum.map(targets, fn target ->
               owner = get_in(target, ["workspace", "owner"]) || %{}

               %{
                 "grant_id" => target["grant_id"],
                 "person" => owner["name"] || owner["email"],
                 "email" => owner["email"],
                 "workspace" => get_in(target, ["workspace", "name"]),
                 "left_today" => max(target["daily_limit"] - target["sent_today"], 0),
                 "accepts_automatically" => target["mode"] == "auto_accept"
               }
             end)
       }}
    else
      {:link_required, _} = link -> link
      other -> other
    end
  end

  def send_request(%{"workspace_id" => workspace_id} = args, ctx)
      when is_binary(workspace_id) and not is_map_key(args, "grant_id") do
    with {:ok, user} <- requester(ctx),
         {:ok, own} <- own_targets(user, ctx),
         true <- Enum.any?(own, &(&1["workspace_id"] == workspace_id)) || {:error, :not_found},
         {:ok, sent} <-
           TaskRequests.send_own_request(
             user,
             workspace_id,
             %{
               "content" => args["content"],
               "title" => args["title"],
               "client_request_id" => request_key(ctx, args)
             },
             source(ctx)
           ) do
      {:ok, %{"status" => "sent", "request_status" => sent["status"], "to" => "own_workspace"}}
    end
  end

  def send_request(%{"grant_id" => _grant_id} = args, ctx) do
    with {:ok, user} <- requester(ctx),
         {:ok, sent} <-
           TaskRequests.send_request(
             user,
             %{},
             args["grant_id"],
             %{
               "content" => args["content"],
               "title" => args["title"],
               "client_request_id" => request_key(ctx, args)
             },
             sender_group(ctx)
           ) do
      {:ok,
       %{
         "status" => "sent",
         "request_status" => sent["status"],
         "to" => get_in(sent, ["workspace", "owner", "name"])
       }}
    else
      {:link_required, _} = link -> link
      {:error, :not_found} -> {:error, :no_grant_for_this_requester}
      other -> other
    end
  end

  def send_request(_args, _ctx), do: {:error, :invalid_task_request}

  @doc "The Router of the Workspace a request was sent to reports what its sender gets."
  def report(%{"request_id" => id, "task_id" => task, "content" => content}, %{group_id: group})
      when is_binary(id) and is_binary(task) and is_binary(content) and content != "" do
    with {:ok, %{"kind" => "agent_task"} = record} <-
           SalixIM.Conversations.get_group_conversation_record(group, task),
         {:ok, _request} <- CommaWeb.TaskRequestReceipts.report(id, group, record, content) do
      {:ok, %{"status" => "reported"}}
    else
      {:ok, _other_kind} -> {:error, :not_a_task}
      other -> other
    end
  end

  def report(_args, _ctx), do: {:error, :invalid_task_request}

  @doc "Whether a Task of this Group may name the request (`internal.task.create`)."
  def request_accepted?(id, group),
    do: match?({:ok, _request}, TaskRequests.accepted_in_group(id, group))

  # A chat user's own Workspaces. A Comma user is already in theirs.
  defp own_targets(user, ctx) do
    case SalixAgent.IFC.principal(ctx[:trusted_origin] || %{}) do
      {:provider_user, _connect, _subject} -> TaskRequests.own_targets(user)
      _other -> {:ok, []}
    end
  end

  # A Comma user's own Router is told how their request went. A chat user's
  # Router serves a Group that is not theirs: it replies with the result in
  # the chat message the request was asked in.
  defp sender_group(ctx) do
    case SalixAgent.IFC.principal(ctx[:trusted_origin] || %{}) do
      {:comma_user, _subject} -> [sender_group_id: ctx[:group_id]]
      _other -> source(ctx)
    end
  end

  # Where the provider would take a reply to the message, never who sent it.
  @source_fields ~w(connect_id workspace_id channel_id channel_type thread_ts message_ts chat_id chat_type conversation_id message_thread_id message_id root_message_id tenant_key)

  # The chat message the turn answers, from its server-sealed origin.
  defp source(ctx) do
    origin = ctx[:trusted_origin] || %{}

    with {:provider_user, _connect, _subject} <- SalixAgent.IFC.principal(origin),
         group when is_binary(group) and group != "" <- ctx[:group_id],
         true <- origin["agent_group_id"] == group,
         provider when is_binary(provider) and provider != "" <- origin["provider"],
         message when is_binary(message) and message != "" <- origin["source_message_id"],
         %{} = context <- origin["provider_context"] do
      [
        source: %{
          "group_id" => group,
          "provider" => provider,
          "message_id" => message,
          "context" => Map.take(context, @source_fields)
        }
      ]
    else
      _other -> []
    end
  end

  @impl SalixIM.Ports.TaskRequests
  def send_from_router(group_id, user_id, grant_id, content, key) do
    with {:ok, %{"owner_user_id" => ^user_id}} <- Comma.Workspaces.get_by_group(group_id),
         {:ok, sent} <-
           TaskRequests.send_request(
             %{"id" => user_id},
             %{},
             grant_id,
             %{"content" => content, "client_request_id" => key},
             sender_group_id: group_id
           ) do
      {:ok, %{"status" => sent["status"], "to" => get_in(sent, ["workspace", "owner", "name"])}}
    else
      {:ok, _workspace} -> {:error, :requester_unknown}
      {:error, _reason} = error -> error
    end
  end

  # `{:ok, user}`, `{:link_required, link}` for an unlinked chat user (the
  # tool waits for it, `SalixAgent.Tools.TaskRequests`), or an error.
  defp requester(ctx) do
    origin = ctx[:trusted_origin] || %{}

    case SalixAgent.IFC.principal(origin) do
      {:provider_user, connect, subject} ->
        case ProviderUserLinks.resolve(connect, subject) do
          {:ok, user_id} ->
            # A link from before it said which account it is learns it now.
            if ProviderUserLinks.unknown_account?(connect, subject),
              do:
                ProviderUserLinks.remember(
                  connect,
                  subject,
                  chat_account(ctx, origin, connect, subject)
                )

            {:ok, %{"id" => user_id}}

          :none ->
            about = chat_account(ctx, origin, connect, subject)

            with {:ok, pending} <-
                   ProviderUserLinks.start(
                     provider(origin),
                     connect,
                     subject,
                     get_in(origin, ["provider_context", "sender_name"]) || about["name"],
                     about
                   ),
                 do:
                   {:link_required,
                    %{
                      "link_id" => pending["id"],
                      "link_url" => link_url(pending["token"]),
                      "expires_at" => pending["expires_at"]
                    }}
        end

      {:comma_user, subject} ->
        case Comma.Workspaces.get_by_group(ctx[:group_id]) do
          {:ok, %{"owner_user_id" => ^subject}} -> {:ok, %{"id" => subject}}
          _ -> {:error, :requester_unknown}
        end

      _ ->
        {:error, :requester_unknown}
    end
  end

  # Which account the chat user is, as the chat app says it, for the person to
  # see with the link.
  defp chat_account(ctx, %{"provider" => provider}, connect_id, subject),
    do: SalixIM.ProviderAccounts.who(ctx[:group_id], connect_id, provider, subject)

  defp chat_account(_ctx, _origin, _connect_id, _subject), do: %{}

  @doc "The Agent tool call that waits for a pending link (`Comma.ProviderUserLinks.await/2`)."
  def await_link(link_id, waiting), do: ProviderUserLinks.await(link_id, waiting)

  # A retry of the same call is the same request.
  defp request_key(ctx, args) do
    origin = ctx[:trusted_origin] || %{}

    "agent:" <>
      (:crypto.hash(
         :sha256,
         Enum.join(
           [
             ctx[:group_id],
             origin["source_message_id"] || origin["message_id"],
             args["grant_id"] || args["workspace_id"],
             args["content"]
           ],
           "\n"
         )
       )
       |> Base.url_encode64(padding: false))
  end

  defp provider(origin), do: origin["provider"] || "chat"

  defp link_url(token),
    do:
      String.trim_trailing(SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin), "/") <>
        @link_path <> token
end
