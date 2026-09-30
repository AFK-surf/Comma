defmodule CommaCoreTest do
  use ExUnit.Case, async: false

  alias Comma.Repo

  defmodule ObservedS3 do
    @behaviour SalixStore.S3
    @observer_key {__MODULE__, :observer}

    def observe_puts(pid), do: :persistent_term.put(@observer_key, pid)
    def stop_observing, do: :persistent_term.erase(@observer_key)

    @impl true
    def put(key, body, opts) do
      if pid = :persistent_term.get(@observer_key, nil), do: send(pid, {:s3_put, key, opts})
      SalixStore.S3.Fake.put(key, body, opts)
    end

    @impl true
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_upload_part(key, upload_id, part_number, body),
      to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake

    @impl true
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake

    @impl true
    defdelegate get(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate stream(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate head(key), to: SalixStore.S3.Fake

    @impl true
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    @impl true
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake
  end

  defmodule RuntimeFake do
    @behaviour Comma.Salix.Client
    @table __MODULE__

    def reset! do
      ensure_table!()
      :ets.delete_all_objects(@table)
      put(:test_pid, self())
      :ok
    end

    def set_router_reconciliation_result(result),
      do: put(:router_reconciliation_result, result)

    @impl true
    def provision_workspace_scope(workspace) do
      notify({:provision_workspace_scope, workspace["id"]})
      :ok
    end

    @impl true
    def resolve_workspace_scope(workspace) do
      group_id = workspace["default_group_id"]
      key = {:router_conversation_id, group_id}

      # Concurrent callers race to allocate the Group's router conversation id
      # (the "concurrent assistant ensure" test fans out twelve at once). The
      # first insert wins; everyone else reads the id it stored.
      conversation_id =
        get(key) ||
          case put_new(key, SalixStore.Ids.new_conversation_id()) do
            {:ok, allocated} -> allocated
            :exists -> get(key)
          end

      {:ok, Map.put(workspace, "router_conversation_id", conversation_id)}
    end

    @impl true
    def ensure_group_router_conversation(workspace) do
      conversation_id = workspace["router_conversation_id"]
      now = System.system_time(:second)

      conversation = %{
        "conversation_id" => conversation_id,
        "group_id" => workspace["default_group_id"],
        "kind" => "user_chat",
        "title" => "Bridge chat",
        "status" => "active",
        "message_count" => 0,
        "created_at" => now,
        "updated_at" => now
      }

      # The conversation record is the atomic "already created" marker, so a
      # check-then-insert cannot let two concurrent callers both create. Only
      # the winner seeds messages and participants; `messages/1` and
      # `participants/1` default to `[]` for a reader that arrives in between.
      case put_new({:conversation, conversation_id}, conversation) do
        {:ok, _conversation} ->
          put({:messages, conversation_id}, [])

          put({:participants, conversation_id}, [
            %{"actor_type" => "user", "user_id" => "current", "state" => "active"},
            %{
              "actor_type" => "agent",
              "agent_id" => workspace["router_agent_id"],
              "state" => "active"
            }
          ])

          update_counter(:create_count)

        :exists ->
          :ok
      end

      case get(:router_reconciliation_result, {:ok, %{"state" => "active"}}) do
        {:ok, _router} -> get_group_conversation(workspace, conversation_id)
        {:error, _reason} = error -> error
      end
    end

    @impl true
    def append_group_router_conversation_message(workspace, attrs) do
      with {:ok, conversation} <- ensure_group_router_conversation(workspace) do
        append_group_conversation_message(
          workspace,
          conversation["conversation_id"],
          attrs
        )
      end
    end

    @impl true
    def update_workspace_vm(workspace, vm) do
      notify({:update_workspace_vm, workspace["id"], vm})
      :ok
    end

    @impl true
    def create_group_conversation(workspace, attrs) do
      request_key = {:create_request, workspace["default_group_id"], attrs["client_request_id"]}

      conversation_id =
        get(request_key) ||
          SalixStore.Ids.new_conversation_id()
          |> tap(&put(request_key, &1))

      unless get({:conversation, conversation_id}) do
        now = System.system_time(:second)
        malformed_router_participant? = take_malformed_create?()

        put({:conversation, conversation_id}, %{
          "conversation_id" => conversation_id,
          "group_id" => workspace["default_group_id"],
          "kind" => attrs["kind"] || "user_chat",
          "title" => attrs["title"] || "Conversation",
          "status" => attrs["status"] || "active",
          "message_count" => 0,
          "created_at" => now,
          "updated_at" => now
        })

        put({:messages, conversation_id}, [])

        participants = [
          %{
            "actor_type" => "user",
            "user_id" => attrs["user_id"],
            "state" => "active"
          }
        ]

        participants =
          if malformed_router_participant? do
            participants
          else
            participants ++
              [
                %{
                  "actor_type" => "agent",
                  "agent_id" => workspace["router_agent_id"],
                  "state" => "active"
                }
              ]
          end

        put({:participants, conversation_id}, participants)
      end

      update_counter(:create_count)
      notify({:create_group_conversation, workspace["default_group_id"], attrs})
      {:ok, %{"conversation_id" => conversation_id}}
    end

    @impl true
    def list_group_conversations(workspace, opts) do
      kind = Keyword.get(opts, :kind)

      conversations =
        all()
        |> Enum.flat_map(fn
          {{:conversation, _id}, conversation} -> [conversation]
          _ -> []
        end)
        |> Enum.filter(&(&1["group_id"] == workspace["default_group_id"]))
        |> Enum.filter(&(is_nil(kind) or &1["kind"] == kind))
        |> Enum.reject(&get({:hidden_from_list, &1["conversation_id"]}, false))

      {:ok, %{"data" => conversations, "next_cursor" => nil, "has_more" => false}}
    end

    @impl true
    def get_group_conversation(workspace, conversation_id) do
      update_counter({:get_count, conversation_id})
      expected_group_id = workspace["default_group_id"]

      case take_failure(conversation_id) do
        nil ->
          case get({:conversation, conversation_id}) do
            %{"group_id" => ^expected_group_id} = conversation ->
              {:ok, conversation}

            _ ->
              {:error, :not_found}
          end

        reason ->
          {:error, reason}
      end
    end

    @impl true
    def list_group_conversation_pins(workspace) do
      pins =
        get({:pins, workspace["default_group_id"]}, [])
        |> Enum.sort_by(&{&1["pinned_at"], &1["conversation_id"]}, :desc)

      {:ok, %{"data" => pins, "has_more" => false}}
    end

    @impl true
    def pin_group_conversation(workspace, conversation_id) do
      with {:ok, _conversation} <- get_group_conversation(workspace, conversation_id) do
        pin = %{
          "conversation_id" => conversation_id,
          "pinned_at" => System.system_time(:millisecond)
        }

        pins =
          get({:pins, workspace["default_group_id"]}, [])
          |> Enum.reject(&(&1["conversation_id"] == conversation_id))

        put({:pins, workspace["default_group_id"]}, [pin | pins])
        {:ok, pin}
      end
    end

    @impl true
    def unpin_group_conversation(workspace, conversation_id) do
      with {:ok, _conversation} <- get_group_conversation(workspace, conversation_id) do
        pins =
          get({:pins, workspace["default_group_id"]}, [])
          |> Enum.reject(&(&1["conversation_id"] == conversation_id))

        put({:pins, workspace["default_group_id"]}, pins)
        :ok
      end
    end

    @impl true
    def update_group_conversation(workspace, conversation_id, attrs) do
      with {:ok, conversation} <- get_group_conversation(workspace, conversation_id) do
        updated =
          conversation
          |> Map.merge(attrs)
          |> Map.put("updated_at", System.system_time(:second))

        put({:conversation, conversation_id}, updated)
        {:ok, updated}
      end
    end

    @impl true
    def get_group_conversation_with_messages(workspace, conversation_id, opts) do
      with {:ok, conversation} <- get_group_conversation(workspace, conversation_id) do
        messages = get({:messages, conversation_id}, [])

        messages =
          case Keyword.get(opts, :tail) do
            tail when is_integer(tail) and tail > 0 -> Enum.take(messages, -tail)
            _ -> Enum.take(messages, Keyword.get(opts, :limit, 200))
          end

        put({:last_snapshot_opts, conversation_id}, opts)

        {:ok,
         %{
           "conversation" => conversation,
           "messages" => messages
         }}
      end
    end

    @impl true
    def subscribe_group_conversation(workspace, conversation_id, subscriber) do
      with {:ok, conversation} <- get_group_conversation(workspace, conversation_id) do
        subscribers = get({:subscribers, conversation_id}, MapSet.new())
        put({:subscribers, conversation_id}, MapSet.put(subscribers, subscriber))

        {:ok,
         %{
           "owner_pid" => Process.whereis(Comma.AssistantChats) || self(),
           "tail_seq" => conversation["message_count"] || 0
         }}
      end
    end

    @impl true
    def ensure_group_conversation_user_participant(workspace, conversation_id, user_id) do
      with {:ok, _conversation} <- get_group_conversation(workspace, conversation_id) do
        participants = get({:participants, conversation_id}, [])

        participant = %{
          "actor_type" => "user",
          "user_id" => user_id,
          "state" => "active"
        }

        unless Enum.any?(participants, &(&1["actor_type"] == "user" and &1["user_id"] == user_id)) do
          put({:participants, conversation_id}, participants ++ [participant])
        end

        {:ok, participant}
      end
    end

    @impl true
    def reconcile_group_conversation_router_participant(_workspace, conversation_id) do
      update_counter({:router_reconciliation_count, conversation_id})
      get(:router_reconciliation_result, {:ok, %{"state" => "active"}})
    end

    @impl true
    def list_group_conversation_participants(workspace, conversation_id, opts) do
      with {:ok, _conversation} <- get_group_conversation(workspace, conversation_id) do
        participants = get({:participants, conversation_id}, [])
        limit = Keyword.get(opts, :limit, 50)
        offset = decode_participant_cursor(Keyword.get(opts, :cursor))
        page_participants = Enum.slice(participants, offset, limit)
        next_offset = offset + length(page_participants)
        has_more = next_offset < length(participants)

        update_counter({:participant_list_count, conversation_id})

        page = %{
          "conversation_id" => conversation_id,
          "participants" => page_participants,
          "has_more" => has_more
        }

        page =
          if has_more,
            do: Map.put(page, "next_cursor", encode_participant_cursor(next_offset)),
            else: page

        {:ok, page}
      end
    end

    @impl true
    def get_group_conversation_messages(_workspace, conversation_id),
      do: {:ok, get({:messages, conversation_id}, [])}

    @impl true
    def append_group_conversation_message(workspace, conversation_id, attrs) do
      with {:ok, _conversation} <- get_group_conversation(workspace, conversation_id) do
        request_id = attrs["client_request_id"]
        messages = get({:messages, conversation_id}, [])

        message =
          Enum.find(messages, &(&1["client_request_id"] == request_id)) ||
            attrs
            |> Map.put("message_id", SalixStore.Ids.new_message_id())
            |> Map.put_new("kind", "message")
            |> Map.put_new("actor_type", "user")
            |> Map.put_new("created_at", System.system_time(:second))

        messages = if(message in messages, do: messages, else: messages ++ [message])
        put({:messages, conversation_id}, messages)
        update_conversation_meta(conversation_id, length(messages))

        notify(
          {:append_group_conversation_message, workspace["default_group_id"], conversation_id,
           attrs}
        )

        notify_subscribers(conversation_id, message["message_id"], length(messages))

        {:ok, %{"conversation_id" => conversation_id, "message_id" => message["message_id"]}}
      end
    end

    @impl true
    def reserve_group_conversation_message(_workspace, conversation_id, attrs) do
      request_id = attrs["client_request_id"]
      key = {:reserved_message, conversation_id, request_id}
      message_id = get(key) || SalixStore.Ids.new_message_id() |> tap(&put(key, &1))
      {:ok, %{"conversation_id" => conversation_id, "message_id" => message_id}}
    end

    @impl true
    def accept_task_review(_workspace, conversation_id, review_version) do
      notify({:accept_task_review, conversation_id, review_version})

      case get({:conversation, conversation_id}) do
        %{
          "kind" => "agent_task",
          "status" => "ready_for_review",
          "updated_at" => ^review_version
        } = conversation ->
          accepted =
            conversation
            |> Map.put("status", "completed")
            |> Map.put("updated_at", review_version + 1)

          put({:conversation, conversation_id}, accepted)
          {:ok, accepted}

        nil ->
          {:error, :not_found}

        _conversation ->
          {:error, :conflict}
      end
    end

    @impl true
    def conversation_activity_context(_workspace, conversation_id) do
      {:ok,
       %{
         conversation_id: conversation_id,
         participant_id: SalixStore.Ids.new_participant_id()
       }}
    end

    @impl true
    def list_agent_skills(_workspace), do: {:ok, %{"skills" => []}}

    @impl true
    def write_agent_file(_workspace, path, _body), do: {:ok, %{"path" => path}}

    @impl true
    def read_agent_file(_workspace, _path, _max_bytes), do: {:error, :not_found}

    @impl true
    def read_agent_blob(_workspace, _agent_id, _ref, _max_bytes),
      do: {:error, :not_found}

    def put_conversation(workspace, attrs \\ %{}) do
      conversation_id = attrs["conversation_id"] || SalixStore.Ids.new_conversation_id()
      now = System.system_time(:second)

      conversation =
        attrs
        |> Map.put("conversation_id", conversation_id)
        |> Map.put("group_id", workspace["default_group_id"])
        |> Map.put_new("kind", "agent_task")
        |> Map.put_new("title", "Task")
        |> Map.put_new("status", "running")
        |> Map.put_new("message_count", 0)
        |> Map.put_new("created_at", now)
        |> Map.put_new("updated_at", now)

      put({:conversation, conversation_id}, conversation)
      put({:messages, conversation_id}, [])
      put({:participants, conversation_id}, [])
      conversation
    end

    def put_message(conversation_id, attrs) do
      message =
        attrs
        |> Map.put_new("message_id", SalixStore.Ids.new_message_id())
        |> Map.put_new("kind", "message")
        |> Map.put_new("created_at", System.system_time(:second))

      messages = get({:messages, conversation_id}, []) ++ [message]
      put({:messages, conversation_id}, messages)
      update_conversation_meta(conversation_id, length(messages))
      message
    end

    def put_messages(conversation_id, attrs_list) when is_list(attrs_list) do
      messages =
        Enum.map(attrs_list, fn attrs ->
          attrs
          |> Map.put_new("message_id", SalixStore.Ids.new_message_id())
          |> Map.put_new("kind", "message")
          |> Map.put_new("created_at", System.system_time(:second))
        end)

      put({:messages, conversation_id}, messages)
      update_conversation_meta(conversation_id, length(messages))
      messages
    end

    def append_agent_message(conversation_id, content) do
      put_message(conversation_id, %{
        "actor_type" => "agent",
        "agent_id" => "fake-agent",
        "content" => [%{"type" => "text", "text" => content}]
      })
    end

    def update_conversation(conversation_id, attrs) do
      conversation = get({:conversation, conversation_id}) |> Map.merge(attrs)
      put({:conversation, conversation_id}, conversation)
      conversation
    end

    def fail_get(conversation_id, reason, attempts \\ 1),
      do: put({:failure, conversation_id}, {reason, attempts})

    def hide_from_list(conversation_id), do: put({:hidden_from_list, conversation_id}, true)

    def set_now(timestamp) when is_integer(timestamp), do: put(:now, timestamp)
    def advance_now(seconds) when is_integer(seconds), do: set_now(now() + seconds)
    def now, do: get(:now, System.system_time(:second))

    def delete_conversation(conversation_id) do
      :ets.delete(@table, {:conversation, conversation_id})
      :ets.delete(@table, {:messages, conversation_id})
      :ets.delete(@table, {:participants, conversation_id})
      :ok
    end

    def replace_participants(conversation_id, participants),
      do: put({:participants, conversation_id}, participants)

    def make_next_creates_malformed(count \\ 1) when is_integer(count) and count > 0,
      do: put(:malformed_create_count, count)

    def get_call_count(conversation_id), do: get({:get_count, conversation_id}, 0)
    def create_count, do: get(:create_count, 0)
    def participants(conversation_id), do: get({:participants, conversation_id}, [])
    def messages(conversation_id), do: get({:messages, conversation_id}, [])
    def last_snapshot_opts(conversation_id), do: get({:last_snapshot_opts, conversation_id})

    def participant_list_count(conversation_id),
      do: get({:participant_list_count, conversation_id}, 0)

    defp update_conversation_meta(conversation_id, count) do
      case get({:conversation, conversation_id}) do
        nil ->
          :ok

        conversation ->
          put(
            {:conversation, conversation_id},
            conversation
            |> Map.put("message_count", count)
            |> Map.put("updated_at", System.system_time(:second))
          )
      end
    end

    defp notify_subscribers(conversation_id, message_id, seq) do
      group_id = get({:conversation, conversation_id})["group_id"]

      Enum.each(get({:subscribers, conversation_id}, MapSet.new()), fn subscriber ->
        send(
          subscriber,
          {:conversation_message_created, group_id, conversation_id, message_id, seq}
        )
      end)
    end

    defp take_failure(conversation_id) do
      case get({:failure, conversation_id}) do
        {reason, attempts} when attempts > 1 ->
          put({:failure, conversation_id}, {reason, attempts - 1})
          reason

        {reason, 1} ->
          :ets.delete(@table, {:failure, conversation_id})
          reason

        _ ->
          nil
      end
    end

    defp take_malformed_create? do
      case get(:malformed_create_count, 0) do
        count when count > 0 ->
          put(:malformed_create_count, count - 1)
          true

        _ ->
          false
      end
    end

    defp encode_participant_cursor(offset),
      do: offset |> Integer.to_string() |> Base.url_encode64(padding: false)

    defp decode_participant_cursor(nil), do: 0
    defp decode_participant_cursor(""), do: 0

    defp decode_participant_cursor(cursor) do
      with {:ok, value} <- Base.url_decode64(cursor, padding: false),
           {offset, ""} <- Integer.parse(value) do
        offset
      else
        _ -> 0
      end
    end

    defp update_counter(key),
      do: :ets.update_counter(@table, key, {2, 1}, {key, 0})

    defp notify(message), do: send(get(:test_pid, self()), message)

    # Atomic insert-if-absent, for the two create paths concurrent tests race.
    defp put_new(key, value) do
      ensure_table!()
      if :ets.insert_new(@table, {key, value}), do: {:ok, value}, else: :exists
    end

    defp put(key, value) do
      ensure_table!()
      true = :ets.insert(@table, {key, value})
      value
    end

    defp get(key, default \\ nil) do
      ensure_table!()

      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        [] -> default
      end
    end

    defp all do
      ensure_table!()
      :ets.tab2list(@table)
    end

    defp ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          try do
            :ets.new(@table, [:named_table, :public, read_concurrency: true])
          rescue
            ArgumentError -> @table
          end

        table ->
          table
      end
    end
  end

  setup do
    Process.put(:test_pid, self())
    RuntimeFake.reset!()

    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    comma_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)

    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_client = Application.get_env(:comma_core, :salix_client)
    prev_auth = Application.get_env(:comma_core, :auth)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:comma_core, :salix_client, RuntimeFake)

    Application.put_env(:comma_core, :auth,
      challenge_store: Comma.AuthChallengeStore.Memory,
      email_delivery: Comma.EmailDelivery.Logger,
      secret: "comma-core-test-secret",
      rate_limit_secret: "comma-core-test-rate-limit-secret",
      challenge_ttl_seconds: 900,
      max_attempts: 3,
      session_ttl_seconds: 3600,
      auto_create_users: true,
      resend_cooldown_seconds: 0,
      email_request_limit: 1_000_000,
      ip_request_limit: 1_000_000,
      verification_failure_limit: 1_000_000,
      provider_failure_threshold: 1_000_000,
      expose_codes: true
    )

    ensure_fake_s3!()
    Comma.Migrations.LegacyS3Fixture.reset!()
    Comma.AuthChallengeStore.Memory.reset!()

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, prev_backend)
      restore_env(:comma_core, :salix_client, prev_client)
      restore_env(:comma_core, :auth, prev_auth)
      Comma.Migrations.LegacyS3Fixture.reset!()
      Comma.AuthChallengeStore.Memory.reset!()
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(comma_owner)
    end)

    :ok
  end

  test "assistant ensure resolves and reuses the Group fixed Router Conversation" do
    {user, workspace, session} = setup_user_workspace("chat-thin@example.com")

    assert {:ok, first} =
             converge_assistant_chat(user, session, workspace["default_group_id"])

    assert {:ok, second} =
             converge_assistant_chat(user, session, workspace["default_group_id"])

    assert first["id"] == second["id"]
    assert first["kind"] == "user_chat"
    assert SalixStore.Ids.valid_conversation_id?(first["id"])
    assert RuntimeFake.create_count() == 1

    {:ok, resolved_workspace} = RuntimeFake.resolve_workspace_scope(workspace)
    assert first["id"] == resolved_workspace["router_conversation_id"]

    assert Enum.any?(RuntimeFake.participants(first["id"]), fn participant ->
             participant["actor_type"] == "agent" and
               participant["agent_id"] == workspace["router_agent_id"]
           end)

    assert Enum.any?(RuntimeFake.participants(first["id"]), fn participant ->
             participant["actor_type"] == "user" and participant["user_id"] == "current"
           end)

    assert first["group_id"] == workspace["default_group_id"]
  end

  test "concurrent assistant ensure converges on the same User x Group Chat" do
    {user, workspace, session} = setup_user_workspace("chat-race@example.com")

    statuses =
      1..12
      |> Task.async_stream(
        fn _ ->
          {:ok, conversation} =
            Comma.AssistantChats.ensure_chat(user, session, workspace["default_group_id"])

          conversation["status"]
        end,
        max_concurrency: 12,
        ordered: false
      )
      |> Enum.map(fn {:ok, status} -> status end)

    assert Enum.uniq(statuses) == ["active"]
    assert RuntimeFake.create_count() == 1

    assert {:ok, conversation} =
             converge_assistant_chat(user, session, workspace["default_group_id"])

    canonical_ids =
      for _ <- 1..12 do
        {:ok, current} =
          Comma.AssistantChats.ensure_chat(user, session, workspace["default_group_id"])

        current["id"]
      end

    assert [_one_id] = Enum.uniq(canonical_ids)
    assert hd(canonical_ids) == conversation["id"]
    assert RuntimeFake.create_count() == 1
  end

  test "a transient Chat send failure does not replace the fixed Router Conversation" do
    {user, workspace, session} = setup_user_workspace("chat-send-unavailable@example.com")

    assert {:ok, chat} = converge_assistant_chat(user, session, workspace["default_group_id"])
    salix_id = stored_salix_id(chat)
    RuntimeFake.fail_get(salix_id, {:unavailable, :timeout})

    assert {:error, {:unavailable, :timeout}} =
             Comma.Conversations.send_message(
               user,
               session,
               workspace["default_group_id"],
               chat["id"],
               %{
                 "client_request_id" => "transient-chat-send",
                 "message" => %{"content" => "retry later"}
               }
             )

    assert {:ok, current} =
             Comma.AssistantChats.ensure_chat(user, session, workspace["default_group_id"])

    assert current["id"] == chat["id"]
    assert RuntimeFake.create_count() == 1
  end

  test "Chat send fails closed before append when Router authority is missing, ambiguous, or hidden" do
    for {suffix, reason, expected} <- [
          {"missing", :router_not_configured, :router_not_configured},
          {"ambiguous", :ambiguous_router_participant, :ambiguous_router_participant},
          {"hidden", :not_found, :not_found}
        ] do
      RuntimeFake.reset!()
      {user, workspace, session} = setup_user_workspace("chat-router-#{suffix}@example.com")
      assert {:ok, chat} = converge_assistant_chat(user, session, workspace["default_group_id"])
      salix_id = stored_salix_id(chat)
      RuntimeFake.set_router_reconciliation_result({:error, reason})

      assert {:error, ^expected} =
               Comma.Conversations.send_message(
                 user,
                 session,
                 workspace["default_group_id"],
                 chat["id"],
                 %{
                   "client_request_id" => "fail-closed-#{suffix}",
                   "message" => %{"content" => "must not append"}
                 }
               )

      assert RuntimeFake.messages(salix_id) == []
    end
  end

  test "message source device is resolved in the sending workspace without granting access" do
    {user, workspace, session} = setup_user_workspace("client-device@example.com")
    {:ok, chat} = converge_assistant_chat(user, session, workspace["default_group_id"])
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    device_id = "dev_client_device"
    foreign_device_id = "dev_foreign_client"

    for {id, group, name} <- [
          {device_id, group_id, "My laptop"},
          {foreign_device_id, SalixStore.Ids.new_group_id(tenant_id), "Other workspace"}
        ] do
      assert {:ok, _, _, _} =
               SalixEnv.Registry.reserve_connector_credential(
                 tenant_id,
                 group,
                 id,
                 "conn_" <> id,
                 nil,
                 %{"name" => name}
               )
    end

    for {reported, expected} <- [
          {device_id, %{"device_id" => device_id, "name" => "My laptop"}},
          {foreign_device_id, nil},
          {"dev_deleted", nil},
          {nil, nil}
        ] do
      assert {:ok, _} =
               Comma.Conversations.send_message(user, session, group_id, chat["id"], %{
                 "client_request_id" => "client-source-#{reported}",
                 "client_device_id" => reported,
                 "metadata" => %{
                   "client_device" => %{"device_id" => foreign_device_id, "name" => "Forged"}
                 },
                 "message" => %{"content" => "this computer"}
               })

      message = RuntimeFake.messages(stored_salix_id(chat)) |> List.last()
      assert get_in(message, ["metadata", "client_device"]) == expected
      refute Map.has_key?(message["metadata"] || %{}, "allows_operations")
    end
  end

  test "Chat send and read use the canonical Salix Conversation identity" do
    {user, workspace, session} = setup_user_workspace("chat-canonical@example.com")
    {:ok, conversation} = converge_assistant_chat(user, session, workspace["default_group_id"])
    salix_id = stored_salix_id(conversation)

    attrs = %{
      "client_request_id" => "chat-send-1",
      "message" => %{"content" => "hello"}
    }

    assert {:ok, first_send} =
             Comma.Conversations.send_message(
               user,
               session,
               workspace["default_group_id"],
               conversation["id"],
               attrs
             )

    assert {:ok, second_send} =
             Comma.Conversations.send_message(
               user,
               session,
               workspace["default_group_id"],
               conversation["id"],
               attrs
             )

    assert length(first_send["messages"]) == 1
    assert length(second_send["messages"]) == 1
    assert length(RuntimeFake.messages(salix_id)) == 1

    raw_user_id = RuntimeFake.messages(salix_id) |> hd() |> Map.fetch!("message_id")
    RuntimeFake.append_agent_message(salix_id, "done")

    assert {:ok, detail} =
             Comma.Conversations.get(
               user,
               session,
               workspace["default_group_id"],
               conversation["id"]
             )

    assert Enum.map(detail["messages"], & &1["actor_type"]) == ["user", "agent"]
    assert detail["status"] == "active"
    assert hd(detail["messages"])["message_id"] == raw_user_id
    assert List.last(detail["messages"])["agent_id"] == "fake-agent"
    assert detail["id"] == salix_id
  end

  test "Chat send preserves ref-only local-file blocks in the canonical Message" do
    {user, workspace, session} = setup_user_workspace("chat-local-file@example.com")
    {:ok, conversation} = converge_assistant_chat(user, session, workspace["default_group_id"])
    salix_id = stored_salix_id(conversation)
    ref = "lfi1_" <> String.duplicate("a", 43)

    attrs = %{
      "client_request_id" => "chat-local-file-1",
      "message" => %{
        "content" => [
          %{"type" => "text", "text" => "review this"},
          %{
            "type" => "local_file",
            "local_file_ref" => ref,
            "display_name" => "report.pdf",
            "media_type" => "application/pdf",
            "size" => 12
          }
        ]
      }
    }

    assert {:ok, detail} =
             Comma.Conversations.send_message(
               user,
               session,
               workspace["default_group_id"],
               conversation["id"],
               attrs
             )

    assert [raw] = RuntimeFake.messages(salix_id)
    assert raw["content"] == attrs["message"]["content"]

    assert [canonical] = detail["messages"]
    assert canonical["message_id"] == raw["message_id"]
    assert canonical["actor_type"] == "user"

    assert canonical["content"] == [
             %{"type" => "text", "text" => "review this"},
             %{
               "type" => "local_file",
               "local_file_ref" => ref,
               "display_name" => "report.pdf",
               "media_type" => "application/pdf",
               "size" => 12
             }
           ]
  end

  test "Chat detail returns the latest bounded Salix tail and preserves canonical count" do
    {user, workspace, session} = setup_user_workspace("chat-tail@example.com")
    {:ok, chat} = converge_assistant_chat(user, session, workspace["default_group_id"])
    salix_id = stored_salix_id(chat)

    RuntimeFake.put_messages(
      salix_id,
      for index <- 1..1_005 do
        %{
          "actor_type" => "agent",
          "agent_id" => workspace["router_agent_id"],
          "content" => [%{"type" => "text", "text" => "chat-#{index}"}]
        }
      end
    )

    assert {:ok, detail} =
             Comma.Conversations.get(user, session, workspace["default_group_id"], chat["id"])

    assert RuntimeFake.last_snapshot_opts(salix_id) == [tail: 1_000]
    assert detail["message_count"] == 1_005
    assert length(detail["messages"]) == 1_000
    assert hd(detail["messages"])["content"] == [%{"type" => "text", "text" => "chat-6"}]

    assert List.last(detail["messages"])["content"] == [
             %{"type" => "text", "text" => "chat-1005"}
           ]

    assert detail["status"] == "active"
  end

  test "Conversation command matrix accepts only canonical Tasks and the fixed Router Chat" do
    {user, workspace, session} = setup_user_workspace("verbs@example.com")
    {:ok, chat} = converge_assistant_chat(user, session, workspace["default_group_id"])

    assert {:error, {:unsupported_for_kind, "user_chat", "patch"}} =
             Comma.Conversations.update(user, session, workspace["default_group_id"], chat["id"], %{
               "title" => "local title"
             })

    assert {:error, {:unsupported_for_kind, "user_chat", "cancel"}} =
             Comma.Conversations.cancel(user, session, workspace["default_group_id"], chat["id"])

    external_chat = RuntimeFake.put_conversation(workspace, %{"kind" => "user_chat"})

    assert {:error, :not_found} =
             Comma.Conversations.get(
               user,
               session,
               workspace["default_group_id"],
               external_chat["conversation_id"]
             )

    task = RuntimeFake.put_conversation(workspace)
    task_id = task["conversation_id"]

    assert {:error, :invalid_conversation_title} =
             Comma.Conversations.update(user, session, workspace["default_group_id"], task_id, %{})

    assert {:error, {:unsupported_for_kind, "agent_task", "cancel"}} =
             Comma.Conversations.cancel(user, session, workspace["default_group_id"], task_id)

    assert {:error, {:unsupported_for_kind, "agent_task", "events"}} =
             Comma.Conversations.events(user, session, workspace["default_group_id"], task_id)
  end

  test "canonical Task pins remain Group-owned and respect restricted Conversation scope" do
    {user, workspace, session} = setup_user_workspace("task-pins@example.com")
    group_id = workspace["default_group_id"]
    pinned_task = RuntimeFake.put_conversation(workspace, %{"title" => "Pinned Task"})
    other_task = RuntimeFake.put_conversation(workspace, %{"title" => "Other Task"})

    assert {:ok, pin} =
             Comma.Conversations.pin_task(
               user,
               session,
               group_id,
               pinned_task["conversation_id"]
             )

    assert pin["conversation"]["id"] == pinned_task["conversation_id"]
    assert pin["conversation"]["group_id"] == group_id

    assert {:ok, _other_pin} =
             Comma.Conversations.pin_task(
               user,
               session,
               group_id,
               other_task["conversation_id"]
             )

    assert {:ok, %{"data" => listed}} =
             Comma.Conversations.list_pinned_tasks(user, session, group_id)

    assert MapSet.new(Enum.map(listed, & &1["conversation"]["id"])) ==
             MapSet.new([pinned_task["conversation_id"], other_task["conversation_id"]])

    restricted_session =
      Map.merge(session, %{
        "restricted" => true,
        "group_id" => group_id,
        "conversation_id" => pinned_task["conversation_id"]
      })

    assert {:ok, %{"data" => [restricted_pin]}} =
             Comma.Conversations.list_pinned_tasks(user, restricted_session, group_id)

    assert restricted_pin["conversation"]["id"] == pinned_task["conversation_id"]

    assert {:error, :forbidden} =
             Comma.Conversations.unpin_task(
               user,
               restricted_session,
               group_id,
               other_task["conversation_id"]
             )

    assert :ok =
             Comma.Conversations.unpin_task(
               user,
               session,
               group_id,
               pinned_task["conversation_id"]
             )

    assert {:ok, %{"data" => [remaining]}} =
             Comma.Conversations.list_pinned_tasks(user, session, group_id)

    assert remaining["conversation"]["id"] == other_task["conversation_id"]
  end

  test "Task rename updates only the canonical title through its Group" do
    {user, workspace, session} = setup_user_workspace("task-rename@example.com")
    group_id = workspace["default_group_id"]
    task = RuntimeFake.put_conversation(workspace, %{"title" => "Original title"})
    task_id = task["conversation_id"]

    assert {:ok, renamed} =
             Comma.Conversations.update(user, session, group_id, task_id, %{
               "title" => "  Renamed Task  "
             })

    assert renamed["id"] == task_id
    assert renamed["group_id"] == group_id
    assert renamed["title"] == "Renamed Task"

    assert {:ok, listed} = Comma.Conversations.list(user, session, group_id)
    assert Enum.find(listed, &(&1["id"] == task_id))["title"] == "Renamed Task"

    assert {:error, :invalid_conversation_title} =
             Comma.Conversations.update(user, session, group_id, task_id, %{"title" => "   "})

    assert {:error, :invalid_conversation_title} =
             Comma.Conversations.update(user, session, group_id, task_id, %{
               "status" => "completed",
               "title" => "Not allowed"
             })
  end

  test "Task review acceptance forwards the exact canonical version to Salix" do
    {user, workspace, session} = setup_user_workspace("task-review@example.com")

    task =
      RuntimeFake.put_conversation(workspace, %{
        "status" => "ready_for_review",
        "updated_at" => 42_000
      })

    task_id = task["conversation_id"]

    assert {:ok, accepted} =
             Comma.Conversations.accept_task_review(
               user,
               session,
               workspace["default_group_id"],
               task_id,
               %{"review_version" => 42_000}
             )

    assert_receive {:accept_task_review, ^task_id, 42_000}
    assert accepted["id"] == task_id
    assert accepted["status"] == "completed"
    assert accepted["updated_at"] == 42_001
  end

  test "a Task preserves every historical author it shows" do
    {user, workspace, session} = setup_user_workspace("workflow-task@example.com")
    task = RuntimeFake.put_conversation(workspace, %{"title" => "Rich text notes app"})

    RuntimeFake.put_messages(task["conversation_id"], [
      %{
        "actor_type" => "agent",
        "agent_id" => workspace["router_agent_id"],
        "role_label" => "delegator",
        "content" => [%{"type" => "text", "text" => "brief"}]
      },
      %{
        "actor_type" => "system",
        "role_label" => "workflow",
        "content" => [%{"type" => "text", "text" => "负责产品定义"}]
      },
      %{
        # A Workflow binds its roles under template-authored labels, so this
        # Agent is neither the delegator nor the group's default Worker.
        "actor_type" => "agent",
        "agent_id" => "agt_workflow_product_role",
        "role_label" => "product",
        "content" => [%{"type" => "text", "text" => "MVP 产品规格"}]
      },
      %{
        "actor_type" => "user",
        "user_id" => user["id"],
        "content" => [%{"type" => "text", "text" => "看一下"}]
      }
    ])

    assert {:ok, detail} =
             Comma.Conversations.get(
               user,
               session,
               workspace["default_group_id"],
               task["conversation_id"]
             )

    assert Enum.map(
             detail["messages"],
             &{&1["actor_type"], &1["role_label"], &1["agent_id"]}
           ) ==
             [
               {"agent", "delegator", workspace["router_agent_id"]},
               {"system", "workflow", nil},
               {"agent", "product", "agt_workflow_product_role"},
               {"user", nil, nil}
             ]
  end

  test "historical system Messages retain canonical authorship" do
    {user, workspace, session} = setup_user_workspace("workflow-compat@example.com")
    task = RuntimeFake.put_conversation(workspace, %{"title" => "Compatibility"})

    RuntimeFake.put_messages(task["conversation_id"], [
      %{
        "actor_type" => "system",
        "role_label" => "workflow",
        "content" => [%{"type" => "text", "text" => "负责产品定义"}]
      }
    ])

    assert {:ok, detail} =
             Comma.Conversations.get(
               user,
               session,
               workspace["default_group_id"],
               task["conversation_id"]
             )

    [activation] = detail["messages"]

    assert activation["actor_type"] == "system"
    assert activation["role_label"] == "workflow"
    refute Map.has_key?(activation, "agent_id")
  end

  test "canonical Task long transcript, follow-up, and list stay Salix-owned" do
    {user, workspace, session} = setup_user_workspace("task@example.com")
    {:ok, chat} = converge_assistant_chat(user, session, workspace["default_group_id"])
    task = RuntimeFake.put_conversation(workspace, %{"title" => "Long Task"})

    RuntimeFake.put_messages(
      task["conversation_id"],
      for index <- 1..1_005 do
        %{
          "actor_type" => "agent",
          "agent_id" => workspace["default_worker_agent_id"],
          "content" => [%{"type" => "text", "text" => "task-#{index}"}]
        }
      end
    )

    task_id = task["conversation_id"]

    assert {:ok, detail} =
             Comma.Conversations.get(user, session, workspace["default_group_id"], task_id)

    assert RuntimeFake.last_snapshot_opts(task["conversation_id"]) == [tail: 1_000]
    assert length(detail["messages"]) == 1_000
    assert detail["message_count"] == 1_005
    assert hd(detail["messages"])["content"] == [%{"type" => "text", "text" => "task-6"}]

    assert Enum.uniq(Enum.map(detail["messages"], & &1["agent_id"])) == [
             workspace["default_worker_agent_id"]
           ]

    assert List.last(detail["messages"])["content"] == [
             %{"type" => "text", "text" => "task-1005"}
           ]

    assert detail["id"] == task_id

    assert {:ok, followed_up} =
             Comma.Conversations.send_message(
               user,
               session,
               workspace["default_group_id"],
               task_id,
               %{"client_request_id" => "task-follow-up", "message" => %{"content" => "continue"}}
             )

    assert length(followed_up["messages"]) == 1_000
    assert followed_up["message_count"] == 1_006
    assert List.last(followed_up["messages"])["client_request_id"] == "task-follow-up"

    assert {:ok, listed} =
             Comma.Conversations.list(user, session, workspace["default_group_id"])

    assert Enum.map(listed, & &1["kind"]) == ["agent_task"]
    assert Enum.any?(listed, &(&1["id"] == task_id))
    refute Enum.any?(listed, &(&1["id"] == chat["id"]))
  end

  test "Task projection uses the authoritative Conversation status" do
    {user, workspace, session} = setup_user_workspace("task-completion@example.com")

    task =
      RuntimeFake.put_conversation(workspace, %{
        "status" => "completed"
      })

    task_id = task["conversation_id"]

    assert {:ok, initial} =
             Comma.Conversations.get(user, session, workspace["default_group_id"], task_id)

    assert initial["status"] == "completed"

    RuntimeFake.update_conversation(task["conversation_id"], %{"activity_status" => "working"})

    assert {:ok, unchanged} =
             Comma.Conversations.get(user, session, workspace["default_group_id"], task_id)

    assert unchanged["status"] == "completed"

    RuntimeFake.update_conversation(task["conversation_id"], %{"status" => "active"})

    assert {:ok, refreshed} =
             Comma.Conversations.get(user, session, workspace["default_group_id"], task_id)

    assert refreshed["status"] == "active"

    assert {:ok, listed} =
             Comma.Conversations.list(user, session, workspace["default_group_id"])

    assert Enum.find(listed, &(&1["id"] == task_id))["status"] == "active"

    RuntimeFake.update_conversation(task["conversation_id"], %{"title" => "Still active"})

    assert {:ok, still_active} =
             Comma.Conversations.get(user, session, workspace["default_group_id"], task_id)

    assert still_active["status"] == "active"

    RuntimeFake.update_conversation(task["conversation_id"], %{"status" => "failed"})

    assert {:ok, failed} =
             Comma.Conversations.get(user, session, workspace["default_group_id"], task_id)

    assert failed["status"] == "failed"
  end

  test "Task preview reads one exact canonical summary without loading the transcript" do
    {user, workspace, session} = setup_user_workspace("task-preview@example.com")

    task =
      RuntimeFake.put_conversation(workspace, %{
        "title" => "Canonical preview title",
        "status" => "ready_for_review",
        "activity_status" => "working",
        "labels" => ["lbl_work"],
        "metadata" => %{"origin" => %{"provider" => "comma"}},
        "updated_at" => 123_456
      })

    RuntimeFake.put_messages(
      task["conversation_id"],
      for index <- 1..25 do
        %{
          "actor_type" => "agent",
          "content" => [%{"type" => "text", "text" => "message-#{index}"}]
        }
      end
    )

    # Restore a fixed authoritative timestamp after the fixture populated the
    # transcript so the preview assertion is independent of the test clock.
    RuntimeFake.update_conversation(task["conversation_id"], %{"updated_at" => 123_456})

    task_id = task["conversation_id"]

    reads_before = RuntimeFake.get_call_count(task["conversation_id"])
    assert RuntimeFake.last_snapshot_opts(task["conversation_id"]) == nil

    assert {:ok, preview} =
             Comma.Conversations.preview(user, session, workspace["default_group_id"], task_id)

    assert preview == %{
             "id" => task_id,
             "group_id" => workspace["default_group_id"],
             "kind" => "agent_task",
             "title" => "Canonical preview title",
             "status" => "ready_for_review",
             "activity_status" => "working",
             "labels" => ["lbl_work"],
             "origin" => "comma",
             "freshness" => %{
               "state" => "fresh",
               "refreshed_at" => preview["freshness"]["refreshed_at"]
             },
             "updated_at" => 123_456
           }

    assert RuntimeFake.get_call_count(task["conversation_id"]) == reads_before + 1
    assert RuntimeFake.last_snapshot_opts(task["conversation_id"]) == nil
    refute Map.has_key?(preview, "messages")
    assert preview["id"] == task_id
  end

  test "bounded Salix list ignores retired S3 decoys and restricted list resolves its target" do
    {user, workspace, session} = setup_user_workspace("filtered-page@example.com")
    task = RuntimeFake.put_conversation(workspace, %{"created_at" => 1})

    task_id = task["conversation_id"]

    bucket = "workspace_conversation_items/#{workspace["id"]}"

    for index <- 1..500 do
      index_id = "0000000000000/decoy-#{String.pad_leading(to_string(index), 3, "0")}"

      assert {:ok, _} =
               Comma.Migrations.LegacyS3Fixture.put(bucket, index_id, %{
                 "id" => "decoy-#{index}",
                 "workspace_id" => workspace["id"],
                 "kind" => "agent_task"
               })
    end

    assert {:ok, first_page} =
             Comma.Conversations.list_page(
               user,
               session,
               workspace["default_group_id"],
               limit: 1
             )

    assert Enum.map(first_page["data"], & &1["id"]) == [task_id]
    assert first_page["has_more"] == false
    assert first_page["next_cursor"] == nil

    restricted_session = %{
      "restricted" => true,
      "group_id" => workspace["default_group_id"],
      "conversation_id" => task_id
    }

    assert {:ok, restricted_page} =
             Comma.Conversations.list_page(
               user,
               restricted_session,
               workspace["default_group_id"],
               limit: 1
             )

    assert Enum.map(restricted_page["data"], & &1["id"]) == [task_id]
    assert restricted_page["has_more"] == false
    assert restricted_page["next_cursor"] == nil
  end

  test "Task list exposes Salix Tasks immediately without adoption retries" do
    {user, workspace, session} = setup_user_workspace("adoption-backoff@example.com")
    task = RuntimeFake.put_conversation(workspace)
    RuntimeFake.fail_get(task["conversation_id"], {:unavailable, :timeout}, 3)

    reads_before = RuntimeFake.get_call_count(task["conversation_id"])

    assert {:ok, first} =
             Comma.Conversations.list(user, session, workspace["default_group_id"])

    assert {:ok, second} =
             Comma.Conversations.list(user, session, workspace["default_group_id"])

    assert Enum.map(first, & &1["id"]) == [task["conversation_id"]]
    # Each list call stamps its own read time, which can cross a second boundary.
    for row <- first ++ second do
      assert %{"state" => "fresh", "refreshed_at" => refreshed_at} = row["freshness"]
      assert is_integer(refreshed_at)
    end

    without_read_time = fn rows ->
      Enum.map(
        rows,
        &update_in(&1, ["freshness"], fn freshness ->
          Map.delete(freshness, "refreshed_at")
        end)
      )
    end

    assert without_read_time.(second) == without_read_time.(first)
    assert RuntimeFake.get_call_count(task["conversation_id"]) == reads_before
  end

  test "Comma conversations preserve existing billing ownership and fee-control" do
    prev_observer = Application.get_env(:comma_core, :fee_control_observer)
    Application.put_env(:comma_core, :fee_control_observer, self())
    on_exit(fn -> restore_env(:comma_core, :fee_control_observer, prev_observer) end)

    {user, workspace, session} = setup_user_workspace("billing@example.com", issue_grant?: false)
    issue_billing_grant(workspace)
    {:ok, conversation} = converge_assistant_chat(user, session, workspace["default_group_id"])

    assert {:ok, _sent} =
             Comma.Conversations.send_message(
               user,
               session,
               workspace["default_group_id"],
               conversation["id"],
               %{
                 "client_request_id" => "req-billing",
                 "message" => %{"content" => "bill me"}
               }
             )

    assert_receive {:comma_fee_control_check, %BillingCore.FeeControl.Decision{allowed?: true},
                    %{
                      "billing_account_id" => billing_account_id,
                      "entrypoint" => "conversation_send"
                    }}

    assert billing_account_id == workspace["billing_account_id"]

    assert_receive {:append_group_conversation_message, group_id, _salix_id, message_attrs}

    assert group_id == workspace["default_group_id"]
    refute Map.has_key?(message_attrs["metadata"] || %{}, "billing_context")
  end

  test "Comma admits a tenant subscription route without a model credit check" do
    {_user, workspace, session} =
      setup_user_workspace("pool-admission@example.com", issue_grant?: false)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Pool admission"})
    tenant_id = tenant["tenant_id"]

    {:ok, template} =
      SalixAgent.Templates.create_private(
        %{
          "name" => "Pool",
          "model" => "gpt-5",
          "provider_config" => %{"account_pool" => "codex"}
        },
        tenant_id
      )

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Pool"}, tenant_id)

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "Pool",
          "group_id" => group["group_id"],
          "template_id" => template["template_id"]
        },
        tenant_id
      )

    conversation = %{
      "id" => "pool-conversation",
      "internal" => %{
        "billing_context" => %{
          "salix_tenant_id" => tenant_id,
          "salix_agent_id" => agent["agent_id"],
          "billing_account_id" => workspace["billing_account_id"]
        }
      }
    }

    assert {:ok, %{fee_control: %{allowed?: true, reason: "tenant_account_pool"}}} =
             Comma.AgentPolicies.authorize_send(workspace, conversation, session, %{
               "client_request_id" => "pool-admission"
             })
  end

  test "Comma accounts and passwordless auth retain their product semantics" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => " Login@Example.COM "})
    assert {:ok, found} = Comma.Accounts.get_user_by_email("login@example.com")
    assert found["id"] == user["id"]

    assert {:ok, %{"challenge_id" => challenge_id, "code" => code}} =
             Comma.AuthChallenges.request_email_login(%{"email" => "auth@example.com"})

    assert {:ok, %{"token" => "comma_sess_" <> _, "user" => auth_user}} =
             Comma.AuthChallenges.verify_email_login(%{
               "challenge_id" => challenge_id,
               "code" => code
             })

    assert auth_user["email"] == "auth@example.com"
  end

  test "restricted-session budget is consumed once per Conversation command identity" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "budget-idempotency@example.com"})

    {:ok, session} =
      Comma.Accounts.create_session(user["id"],
        restricted: true,
        session_source: "ops_api",
        interaction_budget_remaining: 1
      )

    assert {:ok, first} = Comma.Accounts.consume_budget(session, "cnv-public:req-1")
    assert first["interaction_budget_remaining"] == 0

    assert {:ok, retry} = Comma.Accounts.consume_budget(session, "cnv-public:req-1")
    assert retry["interaction_budget_remaining"] == 0

    assert {:error, :budget_exhausted} =
             Comma.Accounts.consume_budget(session, "cnv-public:req-2")
  end

  test "restricted-session budget uses a durable PostgreSQL conditional write" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "budget-cas@example.com"})

    {:ok, session} =
      Comma.Accounts.create_session(user["id"],
        restricted: true,
        session_source: "ops_api",
        interaction_budget_remaining: 1
      )

    assert {:ok, consumed} = Comma.Accounts.consume_budget(session, "cnv-public:req-cas")
    assert consumed["interaction_budget_remaining"] == 0

    persisted = Repo.get!(Comma.Accounts.AuthSession, session["id"])
    assert persisted.interaction_budget_remaining == 0
    assert Map.has_key?(persisted.consumed_interaction_ids, "cnv-public:req-cas")
  end

  test "concurrent restricted-session commands cannot overspend one durable credit" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "budget-race@example.com"})

    {:ok, session} =
      Comma.Accounts.create_session(user["id"],
        restricted: true,
        session_source: "ops_api",
        interaction_budget_remaining: 1
      )

    results =
      ["cnv-public:req-race-a", "cnv-public:req-race-b"]
      |> Enum.map(fn operation_id ->
        Task.async(fn -> Comma.Accounts.consume_budget(session, operation_id) end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :budget_exhausted}, &1)) == 1

    persisted = Repo.get!(Comma.Accounts.AuthSession, session["id"])
    assert persisted.interaction_budget_remaining == 0
    assert map_size(persisted.consumed_interaction_ids) == 1
  end

  test "Workspace group binding revision changes only with the default Group mapping" do
    {_user, workspace, _session} = setup_user_workspace("revision@example.com")
    revision = Comma.Workspaces.group_binding_revision(workspace)

    renamed =
      Map.put(workspace, "name", "Renamed") |> Map.put("updated_at", workspace["updated_at"] + 1)

    assert Comma.Workspaces.group_binding_revision(renamed) == revision

    rotated =
      Map.put(
        workspace,
        "router_agent_id",
        SalixStore.Ids.new_agent_id(workspace["default_group_id"])
      )

    assert Comma.Workspaces.group_binding_revision(rotated) == revision

    remapped =
      Map.put(
        workspace,
        "default_group_id",
        SalixStore.Ids.new_group_id(workspace["salix_tenant_id"])
      )

    refute Comma.Workspaces.group_binding_revision(remapped) == revision
  end

  defp setup_user_workspace(email, opts \\ []) do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => email})
    {:ok, created} = Comma.Workspaces.create_for_user(user["id"], %{"name" => email})

    operation =
      Comma.Repo.get_by!(Comma.Data.ExternalOperation,
        operation_type: "workspace_convergence",
        owner_id: created["id"],
        generation: 1
      )

    assert {:ok, %{status: "succeeded"}} =
             Comma.Workers.WorkspaceConvergence.run(operation.operation_id)

    {:ok, workspace} = Comma.Workspaces.get(created["id"])

    if Keyword.get(opts, :issue_grant?, true) do
      issue_billing_grant(workspace)
    end

    {:ok, session} = Comma.Accounts.create_session(user["id"])
    {user, workspace, session}
  end

  defp converge_assistant_chat(user, session, group_id) do
    Comma.AssistantChats.ensure_chat(user, session, group_id)
  end

  defp stored_salix_id(conversation), do: conversation["id"]

  defp ensure_fake_s3! do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp issue_billing_grant(%{"billing_account_id" => account_id, "id" => workspace_id}) do
    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        credits: 100,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second),
        source_type: "manual_contract",
        source_id: "comma-core-test:#{workspace_id}",
        source_event_id: "comma-core-test:#{workspace_id}",
        idempotency_key: "comma-core-test:#{workspace_id}:2026-07"
      })

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
