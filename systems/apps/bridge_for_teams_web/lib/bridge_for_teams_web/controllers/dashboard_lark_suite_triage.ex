defmodule BridgeForTeamsWeb.DashboardLarkSuiteTriage do
  @moduledoc """
  Feishu / Lark triage pages for `DashboardAPIController`: Overview (each
  Swarm's Feishu and Lark connects, their monitoring switch and watched group
  chats) and Timeline (settled batches and their audited message text).
  Slack triage is `BridgeForTeamsWeb.DashboardTriage`.

  The controller admits owners and admins only. A request reads the org's
  Router roster (`BridgeForTeams.Triage.router_agents/1`), checks the
  requested Agent against it, and calls Salix for that Agent's Group only;
  the Overview reads each Group once, at most #{8} at a time.

  A list never carries message text. `reveal/3` records one access audit row
  per message and returns the text only after the rows are stored.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{LarkSuiteTriage, Triage}

  @kinds ~w(reply reaction silence delegate)
  @max_concurrency 8
  @group_timeout_ms 10_000

  # ---- Overview ----

  @doc "Every Router Agent with its Feishu and Lark connects."
  def overview(org) do
    case safely(fn -> Triage.router_agents(org) end) do
      {:ok, agents} ->
        groups =
          agents
          |> Enum.map(& &1.group_id)
          |> Enum.uniq()
          |> SystemsClock.async_stream(
            fn group_id ->
              {group_id, safely(fn -> LarkSuiteTriage.call(org, group_id, :overview, %{}) end)}
            end,
            max_concurrency: @max_concurrency,
            timeout: @group_timeout_ms,
            on_timeout: :kill_task
          )
          |> Enum.flat_map(fn
            {:ok, pair} -> [pair]
            {:exit, _reason} -> []
          end)
          |> Map.new()

        {:ok,
         %{
           "agents" =>
             agents
             |> Enum.filter(&router?(&1, groups[&1.group_id]))
             |> Enum.map(&public_agent(&1, groups[&1.group_id]))
         }}

      _error ->
        unavailable(gettext("Agents"))
    end
  end

  # A Group has one Router; another router Agent of the roster is not the one
  # a source answers as.
  defp router?(agent, {:ok, %{router_agent_id: router}}), do: router == agent.salix_agent_id
  defp router?(_agent, _unavailable), do: true

  defp public_agent(agent, result) do
    {state, sources} =
      case result do
        {:ok, %{connects: connects}} -> {if(connects == [], do: "empty", else: "ready"), connects}
        _unavailable -> {"unavailable", []}
      end

    %{
      "id" => agent.agent_id,
      "name" => agent_name(agent),
      "project_name" => agent.project_name,
      "state" => state,
      "sources" =>
        sources
        |> Enum.sort_by(&{&1.provider, &1.app_name || "", &1.connect_id})
        |> Enum.map(fn source ->
          %{
            "connect_id" => source.connect_id,
            "provider" => source.provider,
            "app_name" => source.app_name,
            "enabled" => source.enabled,
            "chats" =>
              for(
                chat <- source.chats,
                do: %{
                  "id" => chat.chat_id,
                  "name" => present(chat.chat_name),
                  "enabled" => chat.enabled
                }
              )
          }
        end)
    }
  end

  @doc "The group chats a connect's bot is in, or the one chat `chat_id` names."
  def chats(org, params) do
    with {:ok, agent} <- agent(org, params),
         {:ok, page} <-
           salix(org, agent, :chats, %{
             connect_id: text(params["connect"]),
             chat_id: present(text(params["chat_id"]))
           }) do
      {:ok,
       %{
         "chats" =>
           for(chat <- page.chats, do: %{"id" => chat.chat_id, "name" => present(chat.chat_name)}),
         "complete" => page.complete
       }}
    end
  end

  @doc "Turns a connect's triage monitoring on or off (`enabled`)."
  def set_source(org, user, connect_id, params) do
    with true <- is_boolean(params["enabled"]) || invalid(),
         {:ok, agent} <- agent(org, params),
         {:ok, _source} <-
           salix(org, agent, :set_source, %{
             connect_id: connect_id,
             enabled: params["enabled"],
             updated_by: user.id
           }) do
      {:ok,
       %{
         "notice" =>
           if(params["enabled"],
             do: gettext("Feishu / Lark triage enabled for this connection."),
             else: gettext("Feishu / Lark triage paused for this connection.")
           )
       }}
    end
  end

  @doc """
  Adds group chats to a connect (`chats`: `id` and `name`). A chat another
  Swarm watches answers 409 `chat_already_claimed` with that Swarm's name.
  """
  def add_chats(org, user, connect_id, params) do
    chats =
      for chat <- List.wrap(params["chats"]),
          is_map(chat),
          id = text(chat["id"]),
          id != "",
          do: %{chat_id: id, chat_name: present(text(chat["name"]))}

    with true <- chats != [] || invalid(),
         {:ok, agent} <- agent(org, params),
         {:ok, result} <-
           salix(org, agent, :add_chats, %{
             connect_id: connect_id,
             chats: chats,
             updated_by: user.id
           }) do
      cond do
        result.conflicts != [] ->
          claimed(org, result.conflicts, length(result.added))

        result.added == [] ->
          {:error, 422, "chats_not_added", gettext("The group chats could not be added."), %{}}

        true ->
          {:ok,
           %{
             "notice" =>
               ngettext(
                 "1 group chat added.",
                 "%{count} group chats added.",
                 length(result.added)
               )
           }}
      end
    end
  end

  @doc "Pauses or resumes one watched group chat (`enabled`)."
  def set_chat(org, _user, connect_id, chat_id, params) do
    with true <- is_boolean(params["enabled"]) || invalid(),
         {:ok, agent} <- agent(org, params) do
      case salix(org, agent, :set_chat, %{
             connect_id: connect_id,
             chat_id: chat_id,
             enabled: params["enabled"]
           }) do
        {:ok, _chat} ->
          {:ok,
           %{
             "notice" =>
               if(params["enabled"],
                 do: gettext("Group chat resumed."),
                 else: gettext("Group chat paused.")
               )
           }}

        {:error, 409, "chat_already_claimed", _message, %{"owner" => owner}} ->
          claimed(org, [%{chat_id: chat_id, chat_name: nil, group_id: owner}], 0)

        error ->
          error
      end
    end
  end

  defp claimed(org, conflicts, added) do
    [first | _] = conflicts
    swarm = LarkSuiteTriage.swarm_name(org, first.group_id)

    message =
      case {swarm, first.chat_name} do
        {nil, _chat} ->
          gettext(
            "This group chat is already watched by another Agent Swarm. Pause it there first."
          )

        {swarm, chat} when is_binary(chat) and chat != "" ->
          gettext(
            "“%{chat}” is already watched by the Agent Swarm “%{swarm}”. Pause it there first.",
            chat: chat,
            swarm: swarm
          )

        {swarm, _chat} ->
          gettext(
            "This group chat is already watched by the Agent Swarm “%{swarm}”. Pause it there first.",
            swarm: swarm
          )
      end

    {:error, 409, "chat_already_claimed", message,
     %{
       "added" => added,
       "conflicts" =>
         for(
           conflict <- conflicts,
           do: %{
             "chat_id" => conflict.chat_id,
             "chat_name" => present(conflict.chat_name),
             "swarm_name" => LarkSuiteTriage.swarm_name(org, conflict.group_id)
           }
         )
     }}
  end

  # ---- Timeline ----

  @doc "One page of the Agent's settled triage batches, without message text."
  def activity(org, params) do
    with {:ok, agent} <- agent(org, params),
         {:ok, page} <-
           salix(org, agent, :activity, %{
             kind: if(params["kind"] in @kinds, do: params["kind"]),
             chat_id: present(text(params["chat"])),
             before: cursor(params["cursor"]),
             limit: 20
           }) do
      {:ok,
       %{
         "items" => Enum.map(page.items, &public_item/1),
         "next_cursor" =>
           case page.next_cursor do
             {us, id} -> "#{us}:#{id}"
             nil -> nil
           end
       }}
    end
  end

  defp public_item(batch) do
    target = Enum.find(batch.messages_json, &(&1["message_id"] == batch.target_message_id))

    %{
      "id" => batch.id,
      "provider" => batch.provider,
      "chat_id" => batch.chat_id,
      "chat_name" => present(batch.chat_name),
      "state" => batch.state,
      "kind" => batch.decision_kind,
      "reason_code" => batch.reason_code,
      "reaction" => batch.reaction_emoji,
      "task_title" => batch.task_title,
      "task_conversation_id" => batch.task_conversation_id,
      "error_code" => batch.error_code,
      "at_ms" => ms(batch.settled_at || batch.inserted_at),
      "message_count" => length(batch.messages_json),
      "target" =>
        target &&
          %{
            "sender_name" => present(target["sender_name"]),
            "sent_at_ms" => target["sent_at_ms"]
          },
      "messages" =>
        for(
          message <- batch.messages_json,
          do: %{
            "id" => message["message_id"],
            "sender_name" => present(message["sender_name"]),
            "sent_at_ms" => message["sent_at_ms"]
          }
        )
    }
  end

  @doc """
  The text of one batch's messages (`batch`), after one audit row per message
  is stored. A failed audit write shows nothing.
  """
  def reveal(org, user, params) do
    with {:ok, agent} <- agent(org, params),
         batch_id when batch_id != "" <- text(params["batch"]),
         {:ok, batch} <- salix(org, agent, :reveal, %{batch_id: batch_id}) do
      ids = Enum.map(batch.messages, & &1.message_id)

      case ids != [] &&
             LarkSuiteTriage.record_reveals(org, user, batch.batch_id, batch.connect_id, ids) do
        :ok ->
          {:ok,
           %{
             "messages" =>
               for(
                 message <- batch.messages,
                 do: %{
                   "id" => message.message_id,
                   "sender_name" => present(message.sender_name),
                   "sent_at_ms" => message.sent_at_ms,
                   "text" => message.text
                 }
               ),
             "reply_text" => batch.reply_text
           }}

        false ->
          missing()

        {:error, :audit_failed} ->
          {:error, 503, "audit_unavailable",
           gettext("The message text could not be revealed: the access record failed to write."),
           %{}}
      end
    else
      "" -> missing()
      error -> error
    end
  end

  # ---- helpers ----

  defp agent(org, params) do
    case safely(fn -> Triage.router_agents(org) end) do
      {:ok, agents} ->
        case Enum.find(agents, &(&1.agent_id == params["agent"])) do
          nil ->
            {:error, 404, "agent_not_found", gettext("That Agent is no longer available."), %{}}

          agent ->
            {:ok, agent}
        end

      _error ->
        unavailable(gettext("Agents"))
    end
  end

  defp salix(org, agent, function, request) do
    case safely(fn -> LarkSuiteTriage.call(org, agent.group_id, function, request) end) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:chat_already_claimed, %{group_id: group_id}}} ->
        {:error, 409, "chat_already_claimed", "", %{"owner" => group_id}}

      {:error, :not_found} ->
        missing()

      {:error, :bot_identity_missing} ->
        {:error, 422, "bot_identity_missing",
         gettext(
           "This connection is missing its bot identity and cannot watch group chats. Reconnect the app first."
         ), %{}}

      {:error, reason} when reason in [:invalid_request, :owner_only_connect, :invalid] ->
        invalid()

      {:error, :tenant_not_ready} ->
        {:error, 409, "tenant_not_ready", gettext("This organization is still being set up."),
         %{}}

      _unavailable ->
        unavailable(gettext("Feishu / Lark triage"))
    end
  end

  defp cursor(value) when is_binary(value) do
    with [us, id] <- String.split(value, ":", parts: 2),
         {us, ""} <- Integer.parse(us),
         true <- byte_size(id) <= 128 do
      {us, id}
    else
      _invalid -> nil
    end
  end

  defp cursor(_value), do: nil

  defp ms(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp ms(_at), do: nil

  defp missing,
    do: {:error, 404, "not_found", gettext("That item is no longer available."), %{}}

  defp invalid,
    do: {:error, 422, "invalid_request", gettext("The request is not valid."), %{}}

  defp unavailable(label),
    do:
      {:error, 503, "runtime_unavailable", gettext("%{label} is unavailable", label: label), %{}}

  # "Router" is an execution role, not a name; such an Agent goes by its project.
  defp agent_name(%{agent_name: name, project_name: project}) do
    if is_binary(name) and String.trim(name) != "" and
         String.downcase(String.trim(name)) != "router",
       do: name,
       else: project
  end

  defp safely(read) do
    read.()
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
