defmodule SalixIM.ProviderThreadTaskBinding do
  @moduledoc """
  The group-thread controls Feishu and Lark share: the Router leaves a thread,
  or hands it to one of its Tasks. `SalixIM.FeishuThreadTaskBinding` and
  `SalixIM.LarkThreadTaskBinding` name the provider, its storage keys and its
  message reads; Slack keeps its own `SalixIM.Provider.Slack.ConversationIngress`.

  A binding is a routing fact of one `(group, connect, chat, thread)`: from
  then on a person's message of that thread enters the bound Task instead of
  the Router, and the Task's visible replies go back to that thread through an
  ordinary provider Participant. It names one Task for good: a binding to
  another Task is refused. The Participant and the supervision link are
  ensured again by every message, so a binding whose Participant write failed
  converges on the next message.

  Conversation mutations go through `SalixIM.ConversationServer` only.
  """

  require Logger

  alias SalixIM.{
    ConversationServer,
    Conversations,
    GroupDirectory,
    ProviderAttachments,
    ProviderConversationInput,
    ProviderRecipientIdentity
  }

  alias SalixStore.{CasRecord, Ids, TenantConfigs}

  import SalixIM.Provider.Util, only: [str: 1]

  @type provider :: %{
          required(:provider) => String.t(),
          required(:key) => (String.t(), String.t(), String.t(), String.t() -> String.t()),
          required(:message_address) => (map(), String.t() -> {:ok, map()} | {:error, term()}),
          required(:leave) => (map(), String.t(), String.t() -> :ok | {:error, term()})
        }

  # ---- leave ----

  @doc """
  The Router stops following one thread: unmentioned messages of it no longer
  reach the Router until a mention admits one and the Router answers there
  again. Idempotent: leaving a thread never followed is `status: "left"` too.
  """
  def leave_thread(provider, scope, connect, params) do
    chat_id = str(params["chat_id"])
    thread_id = str(params["thread_id"])

    with :ok <- authorize_router(provider, scope, connect),
         :ok <- require_thread(provider, chat_id, thread_id),
         :ok <- provider.leave.(connect, chat_id, thread_id) do
      {:ok, %{"chat_id" => chat_id, "thread_id" => thread_id, "status" => "left"}}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "#{label(provider)} thread was not left: #{inspect(reason)}"}
    end
  end

  # ---- bind ----

  @doc """
  Hands one thread to an existing Task the calling Router created. Returns
  `binding_status` `"created"`, or `"exists"` for the same Task again.
  """
  def bind_thread_to_task(provider, scope, connect, params) do
    group_id = str(connect["group_id"])
    conversation_id = str(params["conversation_id"])
    chat_id = str(params["chat_id"])
    thread_id = str(params["thread_id"])
    message_id = str(params["message_id"])

    with :ok <- authorize_router(provider, scope, connect),
         :ok <- require_thread(provider, chat_id, thread_id),
         :ok <- require_value(message_id, "message_id"),
         true <-
           Ids.valid_conversation_id?(conversation_id) || {:error, "invalid conversation_id"},
         {:ok, conversation} <- task_conversation(group_id, conversation_id, scope.agent_id),
         {:ok, reply_message_id} <-
           verify_address(provider, connect, message_id, chat_id, thread_id),
         {:ok, binding, created?} <-
           ensure_binding(provider, connect, conversation, chat_id, thread_id, reply_message_id),
         {:ok, participant} <- ensure_participant(provider, connect, binding) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participant_id" => participant["participant_id"],
         "chat_id" => chat_id,
         "thread_id" => thread_id,
         "binding_status" => if(created?, do: "created", else: "exists")
       }}
    end
  end

  @doc "The active binding of one thread, or `:none`."
  @spec active_binding(provider(), map(), term(), term()) :: {:ok, map()} | :none
  def active_binding(provider, connect, chat_id, thread_id) when is_map(connect) do
    ids = [connect["group_id"], connect["connect_id"], chat_id, thread_id]

    with true <- Enum.all?(ids, &(str(&1) != "")),
         [group_id, connect_id, chat_id, thread_id] = Enum.map(ids, &str/1),
         {:ok, %{"binding_status" => "active"} = binding} <-
           CasRecord.get(provider.key.(group_id, connect_id, chat_id, thread_id)),
         true <-
           binding["provider"] == provider.provider and binding["group_id"] == group_id and
             binding["connect_id"] == connect_id and binding["chat_id"] == chat_id and
             binding["thread_id"] == thread_id do
      {:ok, binding}
    else
      _none -> :none
    end
  end

  @doc """
  Appends one person's message of a bound thread to the bound Task. `attrs`:
  `"source_message_id"` (the same source ID the Router input would carry, so a
  redelivery is one message), `"content"`, `"metadata"`, `"user_id"`,
  `"attachments"` and `"created_at"`.
  """
  def append_message(provider, connect, binding, attrs) do
    group_id = binding["group_id"]
    conversation_id = binding["conversation_id"]

    with :ok <- require_value(str(attrs["source_message_id"]), "source_message_id"),
         {:ok, conversation} <-
           Conversations.get_group_conversation_record(group_id, conversation_id),
         true <-
           (conversation["kind"] == "agent_task" and conversation["agent_group_id"] == group_id) ||
             {:error, :invalid_thread_binding},
         worker_agent_id = str(conversation["task_worker_agent_id"]),
         true <- Ids.valid_agent_id?(worker_agent_id) || {:error, :task_worker_missing},
         {:ok, participant} <- ensure_participant(provider, connect, binding),
         {:ok, staged, failed} <-
           ProviderAttachments.stage(
             worker_agent_id,
             List.wrap(attrs["attachments"]),
             ProviderAttachments.ingress_label(group_id, attrs["metadata"] || %{})
           ),
         message =
           %{
             "kind" => "message",
             "participant_id" => participant["participant_id"],
             "actor_type" => "provider_user",
             "provider" => provider.provider,
             "user_id" => str(attrs["user_id"]),
             "role_label" => provider.provider <> "_user",
             "content" =>
               ProviderConversationInput.content_with_attachments(
                 staged,
                 attrs["content"],
                 failed
               ),
             "metadata" => attrs["metadata"] || %{},
             "source_message_id" => attrs["source_message_id"],
             "created_at" => attrs["created_at"] || now()
           }
           |> ProviderRecipientIdentity.mark_trusted_provider_message(),
         {:ok, result} <-
           ConversationServer.append_group_conversation_message(
             group_id,
             conversation_id,
             message
           ) do
      {:ok, Map.put(result, "conversation_id", conversation_id)}
    end
  end

  # ---- authorization and validation ----

  # The connect's Router, of the connect's Group, only. A Feishu or Lark
  # connect delivers to the Group's Router: the Group record names it.
  defp authorize_router(provider, %{agent: %{"role" => "router"}} = scope, connect) do
    group_id = str(connect["group_id"])

    with true <- group_id != "" and str(scope[:group_id]) == group_id,
         {:ok, group} <- GroupDirectory.get_group(group_id),
         true <- str(group["router_agent_id"]) == str(scope[:agent_id]) do
      :ok
    else
      _other -> {:error, "only the connect's Router can control a #{label(provider)} thread"}
    end
  end

  defp authorize_router(provider, _scope, _connect),
    do: {:error, "only the connect's Router can control a #{label(provider)} thread"}

  defp require_thread(provider, chat_id, thread_id) do
    if chat_id != "" and thread_id != "",
      do: :ok,
      else: {:error, "chat_id and thread_id of a #{label(provider)} group thread are required"}
  end

  defp require_value("", name), do: {:error, "#{name} is required"}
  defp require_value(_value, _name), do: :ok

  defp task_conversation(group_id, conversation_id, agent_id) do
    case Conversations.get_group_conversation_record(group_id, conversation_id) do
      {:ok,
       %{"kind" => "agent_task", "agent_group_id" => ^group_id, "created_by_agent_id" => creator} =
           conversation} ->
        if creator == agent_id,
          do: {:ok, conversation},
          else: {:error, "only the Router that created this Task can bind a thread to it"}

      {:ok, _other} ->
        {:error, "conversation_id must identify a Task conversation in this group"}

      {:error, _reason} ->
        {:error, "conversation_id must identify a Task conversation in this group"}
    end
  end

  # The IFC destination is the chat the call names, so the named message must
  # really be of that chat and that thread before anything is written. Its
  # thread's root is what a reply of the Task answers.
  defp verify_address(provider, connect, message_id, chat_id, thread_id) do
    case provider.message_address.(connect, message_id) do
      {:ok, %{"chat_id" => ^chat_id, "thread_id" => ^thread_id} = address} ->
        {:ok, if(address["root_id"] == "", do: message_id, else: address["root_id"])}

      {:ok, %{"chat_id" => ^chat_id}} ->
        {:error, "message_id is not a message of thread_id"}

      {:ok, _other} ->
        {:error, "message_id does not belong to chat_id"}

      {:error, reason} ->
        {:error, "cannot read the #{label(provider)} message: #{reason_text(reason)}"}
    end
  end

  # ---- the binding record ----

  defp ensure_binding(provider, connect, conversation, chat_id, thread_id, reply_message_id) do
    group_id = str(connect["group_id"])
    connect_id = str(connect["connect_id"])
    timestamp = now()

    record = %{
      "version" => 1,
      "binding_status" => "active",
      "provider" => provider.provider,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "chat_id" => chat_id,
      "thread_id" => thread_id,
      "reply_message_id" => reply_message_id,
      "conversation_id" => conversation["conversation_id"],
      "created_at" => timestamp,
      "updated_at" => timestamp
    }

    key = provider.key.(group_id, connect_id, chat_id, thread_id)
    conversation_id = conversation["conversation_id"]

    case CasRecord.create(key, record) do
      {:ok, binding} ->
        {:ok, binding, true}

      {:error, :exists} ->
        case CasRecord.get(key) do
          {:ok, %{"conversation_id" => ^conversation_id} = binding} ->
            {:ok, binding, false}

          {:ok, _other} ->
            {:error, "this #{label(provider)} thread is already bound to another Task"}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  # ---- the thread Participant ----

  defp ensure_participant(provider, connect, binding) do
    group_id = binding["group_id"]
    conversation_id = binding["conversation_id"]

    target = %{
      "provider" => provider.provider,
      "connect_id" => str(connect["connect_id"]),
      "chat_id" => binding["chat_id"],
      "message_thread_id" => binding["thread_id"]
    }

    attrs =
      ProviderConversationInput.provider_participant(target, %{
        "role_label" => provider.provider <> "_thread",
        "notification_filter" => %{"messages" => "all", "statuses" => "none"},
        "payload" => %{
          "chat_type" => "group",
          "root_message_id" => binding["reply_message_id"]
        }
      })

    with {:ok, participant} <-
           ConversationServer.ensure_group_conversation_provider_participant(
             group_id,
             conversation_id,
             attrs
           ),
         :ok <- send_conversation_link(group_id, conversation_id, participant["participant_id"]) do
      {:ok, participant}
    end
  end

  # The thread learns where its Task is supervised, once per Participant
  # (the idempotency key), when the tenant configured a link template.
  defp send_conversation_link(group_id, conversation_id, participant_id) do
    with {:ok, template, tenant_id} <- conversation_url_template(group_id),
         {:ok, url} <- conversation_url(template, tenant_id, group_id, conversation_id),
         {:ok, _queued} <-
           ConversationServer.send_provider_participant_message(
             group_id,
             conversation_id,
             participant_id,
             %{
               "idempotency_key" =>
                 "conversation-link:" <> conversation_id <> ":" <> participant_id,
               "role_label" => "product",
               "content" => [%{"type" => "text", "text" => url}],
               "metadata" => %{
                 "source" => "conversation_link",
                 "link_type" => "supervision",
                 "url" => url
               },
               "created_at" => now()
             },
             delivery_kind: "conversation_link"
           ) do
      :ok
    else
      :not_configured ->
        :ok

      {:error, reason} = error ->
        Logger.warning("thread conversation link not sent: #{inspect(reason)}")
        error
    end
  end

  defp conversation_url_template(group_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         tenant_id when tenant_id != "" <- str(group["tenant_id"]),
         {:ok, %{"value" => %{} = value}} <- TenantConfigs.get(tenant_id, "conversation_links"),
         template when template != "" <- str(value["conversation_url_template"]) do
      {:ok, template, tenant_id}
    else
      {:error, :not_found} -> :not_configured
      {:error, _reason} = error -> error
      _missing -> :not_configured
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp conversation_url(template, tenant_id, group_id, conversation_id) do
    {:ok,
     template
     |> String.replace("{tenant_id}", url_segment(tenant_id))
     |> String.replace("{group_id}", url_segment(group_id))
     |> String.replace("{conversation_id}", url_segment(conversation_id))}
  end

  defp url_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp label(%{provider: "feishu"}), do: "Feishu"
  defp label(%{provider: "lark"}), do: "Lark"

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)

  defp now, do: SystemsClock.system_time(:millisecond)
end
