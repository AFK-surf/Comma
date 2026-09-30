defmodule SalixIM.Provider.Slack.ConversationIngress do
  @moduledoc """
  Slack thread ingress for direct-Worker and explicitly bound Task conversations.

  Slack thread binding and field translation live here. Conversation aggregate
  mutations are delegated exclusively to `SalixIM.ConversationServer`.

  Modeled in `tla/salix/SlackTaskThreadHandover.tla` for create-once binding,
  exact retry, and supervision-link idempotency. Mixed-version generation
  alignment, guarded Participant mutation, strict completion, future-fence
  compatibility, and Stage A/B release gates are modeled in
  `tla/salix/SlackTaskThreadGenerationFence.tla` and
  `tla/salix/SlackTaskThreadRollout.tla`.
  """

  require Logger

  alias SalixIM.{
    ConversationServer,
    Conversations,
    GroupDirectory,
    ProviderConnects,
    ProviderConversationInput,
    ProviderRecipientIdentity
  }

  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixStore.{CasRecord, Crypto, Ids, Keys, S3, TenantConfigs}

  @id_retries 8
  @worker_binding_identity_fields ~w(provider group_id connect_id channel_id thread_ts worker_agent_id conversation_id)
  @task_binding_identity_fields ~w(version binding_type binding_token provider group_id connect_id channel_id thread_ts conversation_id)
  @task_thread_binding_type "task"
  @timestamp ~r/\A\d{1,20}\.\d{1,12}\z/

  def append_worker_thread_message(connect, worker_agent_id, attrs)
      when is_map(connect) and is_map(attrs),
      do: append_worker_thread_message(connect, worker_agent_id, attrs, @id_retries)

  def get_thread_binding(group_id, connect_id, channel_id, thread_ts) do
    key = Keys.ctl_im_slack_thread_binding(group_id, connect_id, channel_id, thread_ts)

    with {:ok, binding} <- read_thread_binding(key) do
      validate_binding(binding, group_id, connect_id, channel_id, thread_ts)
    end
  end

  # Inside one callback's read scope the binding is read once, and a miss is
  # an answer too (a root message usually has none); `thread_binding_key/1`
  # forgets it before any write in the same scope.
  @doc false
  def read_thread_binding(key) do
    case SalixStore.ReadScope.fetch({:binding, key}, fn -> {:ok, CasRecord.get(key)} end) do
      {:ok, result} -> result
      other -> other
    end
  end

  def task_thread_binding?(%{"version" => 3, "binding_type" => "task"} = binding),
    do: binding["binding_status"] in [nil, "active"]

  def task_thread_binding?(_binding), do: false

  @doc false
  def task_thread_binding_current?(connect, binding)
      when is_map(connect) and is_map(binding) do
    if task_thread_binding?(binding) do
      true
    else
      with %{
             "version" => 3,
             "binding_type" => "task",
             "binding_status" => "binding",
             "conversation_id" => conversation_id
           } <- binding,
           scope <- task_route_scope(connect, binding),
           {:ok, claim_identity} <- ThreadRouteOwner.task_claim_identity(scope, conversation_id),
           {:ok, :task} <- ThreadRouteOwner.verify_claim(scope, :task, claim_identity) do
        true
      else
        _not_committed -> false
      end
    end
  end

  def task_thread_binding_current?(_connect, _binding), do: false

  def task_thread_binding_record?(%{"version" => 3, "binding_type" => "task"} = binding),
    do: binding["binding_status"] in [nil, "active"]

  def task_thread_binding_record?(%{
        "version" => 4,
        "binding_type" => "task",
        "binding_status" => "unbinding"
      }),
      do: true

  def task_thread_binding_record?(_binding), do: false

  def task_thread_unbinding?(%{
        "version" => 4,
        "binding_type" => "task",
        "binding_status" => "unbinding"
      }),
      do: true

  def task_thread_unbinding?(_binding), do: false

  def bind_thread_to_task(
        %{
          agent: %{"role" => "router"},
          group_id: group_id,
          agent_id: agent_id
        },
        connect,
        %{
          "conversation_id" => conversation_id,
          "channel" => channel_id,
          "thread_ts" => thread_ts
        }
      )
      when is_map(connect) do
    group_id = trim(group_id)
    agent_id = trim(agent_id)
    conversation_id = trim(conversation_id)
    connect_id = trim(connect["connect_id"])
    channel_id = trim(channel_id)
    thread_ts = trim(thread_ts)
    created_at = now()

    request = %{
      "version" => 3,
      "binding_type" => "task",
      "binding_status" => "binding",
      "binding_token" => binding_token(),
      "provider" => "slack",
      "group_id" => group_id,
      "connect_id" => connect_id,
      "channel_id" => channel_id,
      "thread_ts" => thread_ts,
      "conversation_id" => conversation_id,
      "created_at" => created_at,
      "updated_at" => created_at
    }

    with true <- trim(connect["group_id"]) == group_id,
         true <- Ids.valid_group_id?(group_id),
         true <- Ids.valid_agent_id?(agent_id),
         true <- Ids.valid_conversation_id?(conversation_id),
         true <- connect_id != "" and channel_id != "" and Regex.match?(@timestamp, thread_ts),
         {:ok, conversation} <-
           Conversations.get_group_conversation_record(group_id, conversation_id),
         true <-
           conversation["kind"] == "agent_task" and
             conversation["agent_group_id"] == group_id and
             conversation["created_by_agent_id"] == agent_id,
         {:ok, binding, created?} <- ensure_task_thread_binding(request),
         {:ok, binding} <- claim_and_activate_task_thread_binding(connect, binding),
         {:ok, participant} <-
           ensure_thread_participant(
             group_id,
             binding,
             connect,
             %{
               "channel_id" => channel_id,
               "thread_ts" => thread_ts,
               "message_ts" => thread_ts,
               "created_at" => created_at
             }
           ) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participant_id" => participant["participant_id"],
         "channel" => channel_id,
         "thread_ts" => thread_ts,
         "binding_status" => if(created?, do: "created", else: "exists")
       }}
    else
      false -> {:error, "invalid Slack Task thread binding request"}
      {:error, _reason} = error -> error
    end
  end

  def bind_thread_to_task(_scope, _connect, _params),
    do: {:error, "invalid Slack Task thread binding request"}

  def append_task_thread_message(connect, attrs) when is_map(connect) and is_map(attrs) do
    group_id = trim(connect["group_id"])
    connect_id = trim(connect["connect_id"])
    channel_id = trim(attrs["channel_id"])
    thread_ts = trim(attrs["thread_ts"])
    source_message_id = trim(attrs["source_message_id"])

    with {:ok, group_id} <- require_id(group_id, "group_id", &Ids.valid_group_id?/1),
         :ok <- require_nonblank(connect_id, "connect_id"),
         :ok <- require_nonblank(channel_id, "channel_id"),
         :ok <- require_nonblank(thread_ts, "thread_ts"),
         :ok <- require_nonblank(source_message_id, "source_message_id"),
         {:ok, binding} <- get_thread_binding(group_id, connect_id, channel_id, thread_ts),
         {:ok, binding} <- recover_committed_task_thread_binding(connect, binding),
         {:ok, conversation} <-
           Conversations.get_group_conversation_record(group_id, binding["conversation_id"]),
         true <-
           conversation["kind"] == "agent_task" and
             conversation["agent_group_id"] == group_id,
         {:ok, worker_agent_id} <-
           require_id(
             conversation["task_worker_agent_id"],
             "task_worker_agent_id",
             &Ids.valid_agent_id?/1
           ) do
      append_to_bound_task(
        group_id,
        binding,
        connect,
        Map.put(attrs, "source_message_id", source_message_id),
        worker_agent_id,
        %{}
      )
    else
      false -> {:error, :invalid_slack_thread_binding}
      {:error, _reason} = error -> error
    end
  end

  defp append_worker_thread_message(_connect, _worker_agent_id, _attrs, 0),
    do: {:error, :id_collision}

  defp append_worker_thread_message(connect, worker_agent_id, attrs, attempts) do
    group_id = trim(connect["group_id"])
    connect_id = trim(connect["connect_id"])
    channel_id = trim(attrs["channel_id"])
    thread_ts = trim(attrs["thread_ts"])
    source_message_id = trim(attrs["source_message_id"])
    task_materialization = task_materialization(attrs)

    binding_request = %{
      "group_id" => group_id,
      "connect_id" => connect_id,
      "channel_id" => channel_id,
      "thread_ts" => thread_ts,
      "worker_agent_id" => worker_agent_id,
      "task_materialization" => task_materialization
    }

    with {:ok, group_id} <- require_id(group_id, "group_id", &Ids.valid_group_id?/1),
         :ok <- require_nonblank(connect_id, "connect_id"),
         :ok <- require_nonblank(channel_id, "channel_id"),
         :ok <- require_nonblank(thread_ts, "thread_ts"),
         :ok <- require_nonblank(source_message_id, "source_message_id"),
         :ok <- validate_task_materialization(task_materialization),
         {:ok, binding} <- ensure_thread_binding(binding_request) do
      case materialize_and_append(
             group_id,
             binding,
             connect,
             Map.put(attrs, "source_message_id", source_message_id)
           ) do
        {:error, :exists} ->
          retry_with_new_binding(connect, attrs, binding, attempts)

        {:error, {:conflict, "conversation_id is already assigned to another task"}} ->
          retry_with_new_binding(connect, attrs, binding, attempts)

        {:error, {:participant_id_collision, _participant_id}} ->
          append_worker_thread_message(
            connect,
            binding["worker_agent_id"],
            attrs,
            attempts - 1
          )

        result ->
          result
      end
    end
  end

  defp materialize_and_append(group_id, binding, connect, attrs) do
    conversation_id = binding["conversation_id"]
    worker_agent_id = binding["worker_agent_id"]
    created_at = attrs["created_at"] || now()
    materialization = binding["task_materialization"]

    with {:ok, task} <-
           SalixIM.TaskConversationInput.ensure_with_id(
             group_id,
             conversation_id,
             worker_agent_id,
             materialization
           ),
         worker_participant_id when is_binary(worker_participant_id) <-
           task["worker_participant_id"] do
      append_to_bound_task(
        group_id,
        binding,
        connect,
        Map.put_new(attrs, "created_at", created_at),
        worker_agent_id,
        worker_message_audience(worker_participant_id)
      )
    else
      nil -> {:error, {:bad_request, "task worker participant is missing"}}
      other -> other
    end
  end

  defp append_to_bound_task(
         group_id,
         binding,
         connect,
         attrs,
         worker_agent_id,
         audience
       ) do
    conversation_id = binding["conversation_id"]
    created_at = attrs["created_at"] || now()

    with {:ok, participant} <-
           ensure_thread_participant(group_id, binding, connect, attrs),
         participant_id <- participant["participant_id"],
         {:ok, staged_attachments, failed_attachments} <-
           ProviderConversationInput.stage_worker_attachments(
             worker_agent_id,
             List.wrap(attrs["attachments"] || [])
           ),
         message <-
           Map.merge(
             %{
               "kind" => "message",
               "participant_id" => participant_id,
               "actor_type" => "provider_user",
               "provider" => "slack",
               "user_id" => trim(attrs["user_id"]),
               "user_name" => user_name(attrs),
               "display_name" => user_display_name(attrs),
               "role_label" => "slack_user",
               "content" =>
                 ProviderConversationInput.content_with_attachments(
                   staged_attachments,
                   attrs["content"],
                   failed_attachments
                 ),
               "metadata" => attrs["metadata"] || %{},
               "source_message_id" => attrs["source_message_id"],
               "created_at" => created_at
             },
             audience
           )
           |> ProviderRecipientIdentity.mark_trusted_provider_message()
           |> mark_task_thread_participant_incarnation(binding),
         {:ok, result} <-
           ConversationServer.append_group_conversation_message(
             group_id,
             conversation_id,
             message
           ) do
      {:ok,
       result
       |> Map.put("conversation_id", conversation_id)
       |> Map.put("conversation_kind", "agent_task")
       |> Map.put("worker_agent_id", worker_agent_id)}
    end
  end

  defp ensure_thread_participant(group_id, binding, connect, attrs) do
    conversation_id = binding["conversation_id"]

    with {:ok, participant_attrs} <- provider_participant_attrs(connect, attrs),
         participant_attrs <- put_task_thread_binding_token(participant_attrs, binding),
         {:ok, participant} <-
           resolve_thread_participant(
             group_id,
             conversation_id,
             binding,
             connect,
             participant_attrs
           ),
         {:ok, participant_id} <-
           require_id(
             participant["participant_id"],
             "participant_id",
             &Ids.valid_participant_id?/1
           ),
         {:ok, _binding} <- complete_thread_binding(binding, participant_id),
         :ok <- maybe_send_conversation_link(group_id, conversation_id, participant_id) do
      {:ok, participant}
    end
  end

  defp resolve_thread_participant(
         group_id,
         conversation_id,
         %{"version" => version} = binding,
         _connect,
         participant_attrs
       )
       when version in [1, 2] do
    if valid_worker_binding?(binding) do
      ConversationServer.ensure_group_conversation_provider_participant(
        group_id,
        conversation_id,
        participant_attrs
      )
    else
      {:error, :slack_thread_binding_conflict}
    end
  end

  defp resolve_thread_participant(
         group_id,
         conversation_id,
         %{"version" => 3, "binding_type" => "task"} = binding,
         _connect,
         participant_attrs
       ) do
    if task_thread_binding?(binding) do
      ConversationServer.ensure_group_conversation_provider_participant_incarnation(
        group_id,
        conversation_id,
        participant_attrs,
        participant_incarnation_contract(binding)
      )
    else
      {:error, :slack_thread_binding_conflict}
    end
  end

  defp resolve_thread_participant(
         _group_id,
         _conversation_id,
         _binding,
         _connect,
         _participant_attrs
       ),
       do: {:error, :slack_thread_binding_conflict}

  defp participant_incarnation_contract(binding) do
    incomplete? = not Ids.valid_participant_id?(binding["participant_id"])

    required =
      Map.new(@task_binding_identity_fields, fn field ->
        {field, Map.get(binding, field)}
      end)

    %{
      "payload_field" => "task_thread_binding_token",
      "required_payload" => %{"task_thread_binding_type" => @task_thread_binding_type},
      "allow_create" => incomplete?,
      "allow_reactivation" => incomplete?,
      "record_guard" => %{
        "record_key" => thread_binding_key(binding),
        "required" => required,
        "one_of" => %{"binding_status" => [nil, "active"]},
        "optional_expected" => %{}
      }
    }
  end

  defp put_task_thread_binding_token(
         participant_attrs,
         %{"version" => 3, "binding_type" => "task"} = binding
       ) do
    Map.update!(participant_attrs, "payload", fn payload ->
      payload = Map.put(payload, "task_thread_binding_type", @task_thread_binding_type)

      case binding["binding_token"] do
        token when is_binary(token) and token != "" ->
          Map.put(payload, "task_thread_binding_token", token)

        _legacy ->
          Map.delete(payload, "task_thread_binding_token")
      end
    end)
  end

  defp put_task_thread_binding_token(participant_attrs, _binding), do: participant_attrs

  defp mark_task_thread_participant_incarnation(
         message,
         %{"version" => 3, "binding_type" => "task"} = binding
       ) do
    ProviderRecipientIdentity.mark_trusted_participant_incarnation(
      message,
      "task_thread_binding_token",
      binding["binding_token"],
      %{"task_thread_binding_type" => @task_thread_binding_type}
    )
  end

  defp mark_task_thread_participant_incarnation(message, _binding), do: message

  defp worker_message_audience(worker_participant_id) do
    %{"mentions" => %{"participant_ids" => [worker_participant_id]}}
  end

  defp ensure_thread_binding(request), do: ensure_thread_binding(request, @id_retries)
  defp ensure_thread_binding(_request, 0), do: {:error, :id_collision}

  defp ensure_thread_binding(request, attempts) do
    group_id = request["group_id"]
    connect_id = request["connect_id"]

    key = thread_binding_key(request)

    with {:ok, _group} <- GroupDirectory.get_group(group_id),
         {:ok, _connect} <-
           ProviderConnects.get_active_connect_by_id(group_id, connect_id, "slack"),
         {:ok, worker_agent} <- GroupDirectory.get_agent(request["worker_agent_id"]),
         :ok <- require_worker(worker_agent, group_id) do
      case CasRecord.get(key) do
        {:ok, binding} ->
          with {:ok, binding} <-
                 validate_binding(
                   binding,
                   group_id,
                   connect_id,
                   request["channel_id"],
                   request["thread_ts"]
                 ) do
            ensure_binding_task_materialization(binding, request["task_materialization"])
          end

        {:error, :not_found} ->
          binding =
            Map.merge(request, %{
              "version" => 2,
              "provider" => "slack",
              "conversation_id" => Ids.new_conversation_id(),
              "created_at" => now(),
              "updated_at" => now()
            })

          case CasRecord.create(key, binding) do
            {:ok, created} ->
              {:ok, created}

            {:error, :exists} ->
              ensure_thread_binding(request, attempts - 1)

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_task_thread_binding(request),
    do: ensure_task_thread_binding(request, @id_retries)

  defp ensure_task_thread_binding(_request, 0), do: {:error, :slack_thread_binding_conflict}

  defp ensure_task_thread_binding(request, attempts) do
    key = thread_binding_key(request)

    case CasRecord.get(key) do
      {:ok, binding} ->
        with {:ok, binding} <-
               validate_binding(
                 binding,
                 request["group_id"],
                 request["connect_id"],
                 request["channel_id"],
                 request["thread_ts"]
               ),
             true <-
               task_thread_binding_record_matches_request?(binding) and
                 binding["conversation_id"] == request["conversation_id"] do
          {:ok, binding, false}
        else
          false -> {:error, :slack_thread_binding_conflict}
          {:error, _reason} = error -> error
        end

      {:error, :not_found} ->
        case CasRecord.create(key, request) do
          {:ok, created} -> {:ok, created, true}
          {:error, :exists} -> ensure_task_thread_binding(request, attempts - 1)
          {:error, {:ambiguous, _reason}} -> ensure_task_thread_binding(request, attempts - 1)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_and_activate_task_thread_binding(connect, binding) do
    scope = task_route_scope(connect, binding)

    with {:ok, claim_identity} <-
           ThreadRouteOwner.task_claim_identity(scope, binding["conversation_id"]),
         {:ok, :task} <- ThreadRouteOwner.claim_task(scope, claim_identity),
         {:ok, active} <- activate_task_thread_binding(binding) do
      {:ok, active}
    else
      {:conflict, _owner} -> {:error, :slack_thread_binding_conflict}
      {:error, _reason} = error -> error
      _unavailable -> {:error, :slack_thread_route_unavailable}
    end
  end

  defp recover_committed_task_thread_binding(connect, binding) do
    cond do
      task_thread_binding?(binding) ->
        {:ok, binding}

      task_thread_binding_current?(connect, binding) ->
        activate_task_thread_binding(binding)

      true ->
        {:error, :slack_thread_binding_conflict}
    end
  end

  defp activate_task_thread_binding(binding) do
    key = thread_binding_key(binding)

    case CasRecord.update(
           key,
           fn current ->
             if task_binding_identity_matches?(current, binding) do
               case current["binding_status"] do
                 "binding" ->
                   current
                   |> Map.put("binding_status", "active")
                   |> Map.put("updated_at", now())

                 status when status in [nil, "active"] ->
                   {:unchanged, current}

                 _other ->
                   {:error, :slack_thread_binding_conflict}
               end
             else
               {:error, :slack_thread_binding_conflict}
             end
           end,
           create: false
         ) do
      {:ok, %{"version" => 3, "binding_type" => "task"} = active} ->
        if task_thread_binding?(active),
          do: {:ok, active},
          else: {:error, :slack_thread_binding_conflict}

      {:error, _reason} = error ->
        error
    end
  end

  defp task_thread_binding_record_matches_request?(
         %{"version" => 3, "binding_type" => "task"} = binding
       ),
       do: binding["binding_status"] in [nil, "active", "binding"]

  defp task_thread_binding_record_matches_request?(_binding), do: false

  defp task_binding_identity_matches?(current, expected)
       when is_map(current) and is_map(expected) do
    Enum.all?(@task_binding_identity_fields, fn field ->
      Map.get(current, field) == Map.get(expected, field)
    end)
  end

  defp task_binding_identity_matches?(_current, _expected), do: false

  defp task_route_scope(connect, binding) do
    %{
      "tenant_id" => trim(connect["tenant_id"]),
      "group_id" => binding["group_id"],
      "connect_id" => binding["connect_id"],
      "connect_generation" => task_route_generation(connect),
      "workspace_id" => trim(connect["workspace_id"]),
      "channel_id" => binding["channel_id"],
      "root_thread_ts" => canonical_route_thread_ts(binding["thread_ts"])
    }
  end

  defp canonical_route_thread_ts(thread_ts) when is_binary(thread_ts) do
    case String.split(thread_ts, ".", parts: 2) do
      [seconds, fraction] when byte_size(fraction) in 1..6 ->
        seconds <> "." <> String.pad_trailing(fraction, 6, "0")

      _other ->
        thread_ts
    end
  end

  defp canonical_route_thread_ts(thread_ts), do: thread_ts

  defp task_route_generation(connect) do
    case trim(connect["connect_generation"]) do
      "" ->
        Crypto.hex([
          "comma.slack-task-route-legacy-generation.v1",
          trim(connect["tenant_id"]),
          trim(connect["group_id"]),
          trim(connect["connect_id"]),
          trim(connect["workspace_id"])
        ])

      generation ->
        generation
    end
  end

  defp provider_participant_attrs(connect, attrs) do
    channel_id = trim(attrs["channel_id"])
    thread_ts = trim(attrs["thread_ts"])
    user_id = trim(attrs["user_id"])
    user_name = user_name(attrs)
    display_name = user_display_name(attrs)
    created_at = attrs["created_at"] || now()

    target = %{
      "provider" => "slack",
      "connect_id" => trim(connect["connect_id"]),
      "workspace_id" => trim(connect["workspace_id"]),
      "channel_id" => channel_id,
      "thread_ts" => thread_ts
    }

    with :ok <- require_nonblank(target["connect_id"], "connect_id"),
         :ok <- require_nonblank(channel_id, "channel_id"),
         :ok <- require_nonblank(thread_ts, "thread_ts") do
      target = strip_empty_values(target)

      {:ok,
       ProviderConversationInput.provider_participant(target, %{
         "role_label" => "slack_thread",
         "user_id" => user_id,
         "user_name" => user_name,
         "display_name" => display_name,
         "notification_filter" => %{"messages" => "all", "statuses" => "none"},
         "payload" =>
           %{
             "thread_url" => thread_url(connect["workspace_id"], channel_id, thread_ts),
             "created_from_message_ts" => attrs["message_ts"],
             "created_from_user_id" => user_id,
             "created_from_user_name" => user_name,
             "created_from_user_display_name" => display_name
           }
           |> strip_empty_values(),
         "created_at" => created_at,
         "updated_at" => created_at
       })
       |> strip_empty_values()}
    end
  end

  defp complete_thread_binding(binding, participant_id) do
    conversation_id = binding["conversation_id"]

    key = thread_binding_key(binding)

    case CasRecord.update(key, fn
           nil ->
             {:error, :not_found}

           current ->
             if binding_completion_matches?(current, binding, participant_id) do
               current
               |> Map.put("participant_id", participant_id)
               |> Map.put("updated_at", now())
             else
               {:error, :slack_thread_binding_conflict}
             end
         end) do
      {:ok,
       %{
         "conversation_id" => ^conversation_id,
         "participant_id" => ^participant_id
       } = completed} ->
        {:ok, completed}

      {:ok, _binding} ->
        {:error, :slack_thread_binding_conflict}

      {:error, _reason} = error ->
        error
    end
  end

  defp binding_completion_matches?(
         %{"version" => 3, "binding_type" => "task"} = current,
         %{"version" => 3, "binding_type" => "task"} = binding,
         participant_id
       ) do
    Enum.all?(@task_binding_identity_fields, fn field ->
      Map.get(current, field) == Map.get(binding, field)
    end) and
      current["participant_id"] in [nil, "", participant_id] and
      task_thread_binding?(binding) and task_thread_binding?(current)
  end

  defp binding_completion_matches?(current, binding, participant_id) do
    valid_worker_binding?(current) and valid_worker_binding?(binding) and
      current["conversation_id"] == binding["conversation_id"] and
      current["participant_id"] in [nil, "", participant_id]
  end

  defp maybe_send_conversation_link(group_id, conversation_id, participant_id) do
    case conversation_link_notification(group_id, conversation_id, participant_id) do
      {:ok, attrs} ->
        with {:ok, _result} <-
               ConversationServer.send_provider_participant_message(
                 group_id,
                 conversation_id,
                 participant_id,
                 attrs,
                 delivery_kind: "conversation_link"
               ) do
          :ok
        end

      :ok ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp conversation_link_notification(group_id, conversation_id, participant_id) do
    with {:ok, conversation} <-
           Conversations.get_group_conversation(group_id, conversation_id),
         {:ok, template, tenant_id} <- conversation_url_template(group_id),
         {:ok, url} <- render_conversation_url(template, tenant_id, conversation) do
      {:ok,
       %{
         "idempotency_key" => "conversation-link:" <> conversation_id <> ":" <> participant_id,
         "role_label" => "product",
         "content" => [%{"type" => "text", "text" => url}],
         "metadata" => %{
           "source" => "conversation_link",
           "link_type" => "supervision",
           "url" => url
         },
         "created_at" => now()
       }}
    else
      {:error, :not_configured} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "conversation link delivery skipped " <>
            inspect(%{
              group_id: group_id,
              conversation_id: conversation_id,
              participant_id: participant_id,
              reason: reason
            })
        )

        {:error, reason}
    end
  end

  defp conversation_url_template(group_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         tenant_id when tenant_id != "" <- trim(group["tenant_id"]),
         {:ok, config} <- tenant_config(tenant_id, "conversation_links") do
      case trim(config["conversation_url_template"]) do
        "" -> {:error, :not_configured}
        template -> {:ok, template, tenant_id}
      end
    else
      "" -> {:error, :not_configured}
      {:error, :not_found} -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  # Discrete tenant configs live in Postgres now
  # (docs/storage-search.md). A store fault reads as
  # unavailable (the retired S3 read surfaced its faults the same way).
  defp tenant_config(tenant_id, name) do
    case TenantConfigs.get(tenant_id, name) do
      {:ok, %{"value" => value}} when is_map(value) -> {:ok, value}
      {:ok, _} -> {:ok, %{}}
      {:error, :not_found} -> {:ok, %{}}
    end
  rescue
    _exception -> {:error, :unavailable}
  end

  defp render_conversation_url(template, tenant_id, conversation) do
    with tenant_id when tenant_id != "" <- trim(tenant_id),
         group_id when group_id != "" <- trim(conversation["agent_group_id"]),
         conversation_id when conversation_id != "" <- trim(conversation["conversation_id"]) do
      {:ok,
       template
       |> String.replace("{tenant_id}", url_segment(tenant_id))
       |> String.replace("{group_id}", url_segment(group_id))
       |> String.replace("{conversation_id}", url_segment(conversation_id))}
    else
      "" -> {:error, :missing_conversation_link_identity}
      other -> {:error, other}
    end
  end

  defp retry_with_new_binding(connect, attrs, binding, attempts) do
    with :ok <- delete_binding_if_matches(binding) do
      append_worker_thread_message(
        connect,
        binding["worker_agent_id"],
        attrs,
        attempts - 1
      )
    end
  end

  defp delete_binding_if_matches(binding) do
    key = thread_binding_key(binding)

    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        with {:ok, current} when is_map(current) <- Jason.decode(body),
             true <- current["conversation_id"] == binding["conversation_id"] do
          case S3.delete(key, if_match: etag) do
            :ok -> :ok
            {:error, :not_found} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          false -> :ok
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_slack_thread_binding}
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_binding_task_materialization(%{"version" => 2} = binding, _current),
    do: {:ok, binding}

  defp ensure_binding_task_materialization(%{"version" => 3, "binding_type" => "task"}, _current),
    do: {:error, :slack_thread_binding_conflict}

  defp ensure_binding_task_materialization(%{"version" => 1} = binding, current) do
    with {:ok, %{"kind" => "agent_task"} = conversation} <-
           Conversations.get_group_conversation(
             binding["group_id"],
             binding["conversation_id"]
           ),
         materialization =
           conversation["task_materialization"] || task_materialization(conversation),
         :ok <- validate_task_materialization(materialization) do
      {:ok, Map.put(binding, "task_materialization", materialization)}
    else
      {:error, :not_found} ->
        upgrade_orphan_binding(binding, current)

      {:ok, _conversation} ->
        {:error, :slack_thread_binding_conflict}

      {:error, _reason} = error ->
        error
    end
  end

  defp upgrade_orphan_binding(binding, materialization) do
    identity = Map.take(binding, @worker_binding_identity_fields)

    key = thread_binding_key(binding)

    case CasRecord.update(
           key,
           fn stored ->
             cond do
               Map.take(stored, @worker_binding_identity_fields) != identity ->
                 {:error, :slack_thread_binding_conflict}

               stored["version"] == 1 ->
                 stored
                 |> Map.put("version", 2)
                 |> Map.put("task_materialization", materialization)
                 |> Map.put("updated_at", now())

               stored["version"] == 2 ->
                 {:unchanged, stored}

               true ->
                 {:error, :invalid_slack_thread_binding}
             end
           end,
           create: false
         ) do
      {:ok, %{"version" => 2} = upgraded} ->
        validate_binding(
          upgraded,
          binding["group_id"],
          binding["connect_id"],
          binding["channel_id"],
          binding["thread_ts"]
        )

      {:ok, _binding} ->
        {:error, :invalid_slack_thread_binding}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_binding(binding, group_id, connect_id, channel_id, thread_ts) do
    valid_binding? =
      case binding do
        %{"version" => 1} ->
          valid_worker_binding?(binding)

        %{"version" => 2} ->
          valid_worker_binding?(binding) and
            validate_task_materialization(binding["task_materialization"]) == :ok

        %{"version" => 3, "binding_type" => "task"} ->
          binding["binding_status"] in [nil, "active", "binding"] and
            valid_optional_binding_token?(binding["binding_token"]) and
            is_nil(binding["worker_agent_id"]) and
            Ids.valid_conversation_id?(binding["conversation_id"])

        %{
          "version" => 4,
          "binding_type" => "task",
          "binding_status" => "unbinding"
        } ->
          valid_optional_binding_token?(binding["binding_token"]) and
            is_nil(binding["worker_agent_id"]) and
            Ids.valid_conversation_id?(binding["conversation_id"])

        _ ->
          false
      end

    if valid_binding? and binding["provider"] == "slack" and
         binding["group_id"] == group_id and binding["connect_id"] == connect_id and
         binding["channel_id"] == channel_id and binding["thread_ts"] == thread_ts and
         valid_optional_participant_id?(binding["participant_id"]) do
      {:ok, binding}
    else
      {:error, :invalid_slack_thread_binding}
    end
  end

  defp valid_worker_binding?(binding) do
    is_nil(binding["binding_type"]) and
      Ids.valid_agent_id?(binding["worker_agent_id"]) and
      Ids.valid_conversation_id?(binding["conversation_id"])
  end

  # Every binding write addresses its key through here; the scoped read of
  # that key is forgotten first.
  defp thread_binding_key(binding) do
    key =
      Keys.ctl_im_slack_thread_binding(
        binding["group_id"],
        binding["connect_id"],
        binding["channel_id"],
        binding["thread_ts"]
      )

    SalixStore.ReadScope.invalidate({:binding, key})
    key
  end

  defp valid_optional_participant_id?(value),
    do: value in [nil, ""] or Ids.valid_participant_id?(value)

  defp valid_optional_binding_token?(nil), do: true
  defp valid_optional_binding_token?(value) when is_binary(value), do: trim(value) != ""
  defp valid_optional_binding_token?(_value), do: false

  defp validate_task_materialization(
         %{"title" => title, "command" => command, "created_at" => created_at} = materialization
       )
       when map_size(materialization) == 3 and is_binary(title) and is_binary(command) and
              is_integer(created_at),
       do: require_nonblank(title, "task materialization title")

  defp validate_task_materialization(_materialization),
    do: {:error, {:bad_request, "invalid task materialization"}}

  defp require_worker(%{"group_id" => group_id, "role" => role}, group_id)
       when role != "router",
       do: :ok

  defp require_worker(agent, group_id) do
    {:error,
     {:bad_request,
      "target agent #{agent["agent_id"] || "(unknown)"} is not a worker in group #{group_id}"}}
  end

  defp task_title(attrs) do
    summary =
      case content_text(attrs["content"]) |> String.trim() do
        "" -> "#{trim(attrs["channel_id"])} #{trim(attrs["thread_ts"])}"
        text -> String.slice(text, 0, 80)
      end

    "Slack task: " <> summary
  end

  defp task_materialization(attrs) do
    %{
      "title" => attrs["title"] || task_title(attrs),
      "command" => get_in(attrs, ["schedule", "command"]) || content_text(attrs["content"] || []),
      "created_at" => attrs["created_at"] || now()
    }
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp content_text(%{"text" => text}) when is_binary(text), do: text

  defp content_text(content) when is_map(content) do
    content
    |> Map.values()
    |> Enum.map(&content_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp content_text(_content), do: ""

  defp user_name(attrs) do
    metadata = if is_map(attrs["metadata"]), do: attrs["metadata"], else: %{}

    first_nonblank([attrs["user_name"], metadata["user_name"]])
    |> readable_user_name(trim(attrs["user_id"]))
  end

  defp user_display_name(attrs) do
    metadata = if is_map(attrs["metadata"]), do: attrs["metadata"], else: %{}
    user_id = trim(attrs["user_id"])

    first_nonblank([
      attrs["user_display_name"],
      metadata["user_display_name"],
      attrs["user_real_name"],
      metadata["user_real_name"],
      attrs["display_name"],
      metadata["display_name"],
      user_name(attrs)
    ])
    |> readable_user_name(user_id)
  end

  defp readable_user_name(value, user_id) do
    value = trim(value)

    cond do
      value == "" -> ""
      value == trim(user_id) -> ""
      Regex.match?(~r/^[UW][A-Z0-9]{7,}$/, value) -> ""
      true -> value
    end
  end

  defp first_nonblank(values) do
    values
    |> Enum.map(&trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp thread_url(workspace_id, channel_id, thread_ts) do
    workspace_id = trim(workspace_id)
    channel_id = trim(channel_id)
    thread_ts = trim(thread_ts)

    if workspace_id != "" and channel_id != "" and thread_ts != "" do
      "https://app.slack.com/client/" <>
        url_segment(workspace_id) <>
        "/" <>
        url_segment(channel_id) <>
        "/thread/" <>
        url_segment(channel_id <> "-" <> thread_ts)
    else
      ""
    end
  end

  defp url_segment(value), do: value |> trim() |> URI.encode(&URI.char_unreserved?/1)
  defp now, do: System.system_time(:millisecond)

  defp binding_token,
    do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp require_nonblank(value, field) do
    if trim(value) == "", do: {:error, {:bad_request, "#{field} is required"}}, else: :ok
  end

  defp require_id(value, field, valid?) do
    value = trim(value)

    cond do
      value == "" -> {:error, {:bad_request, "#{field} is required"}}
      valid?.(value) -> {:ok, value}
      true -> {:error, {:bad_request, "invalid #{field}"}}
    end
  end

  defp strip_empty_values(map), do: Map.reject(map, fn {_key, value} -> value in [nil, ""] end)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
