defmodule CommaWeb.RouterCreatedWorkersTest do
  @moduledoc """
  A new Comma Workspace starts with its Router alone. Its Router's and
  product Tasks run on its Group's Task agent, and the Router creates Workers
  with a catalog model.
  """
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  @moduletag :capture_log

  alias SalixAgent.{AccountPool, AgentManagement}

  @admin_token "test-token"
  @effortful "gpt-5.5"

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SalixAgent.TestSupport.stop_all_agents()

    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_agent, :agent_management_ports},
            {:salix_agent, :llm},
            {:comma_core, :salix_client},
            {:comma_web, :api_token}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :agent_management_ports, CommaWeb.AgentManagement)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SalixAgent.LLM.Mock.script([])
    SalixAgent.TestSupport.configure_platform_models!()
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{
          "email" => "workers-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"], %{"name" => "Atelier"})
    fund!(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    %{user: user, workspace: workspace, token: session["token"]}
  end

  test "the Router manages no Worker: a Task without agent_id runs on the Group's Task agent",
       c do
    router_id = c.workspace["router_agent_id"]

    assert {:ok, config} = SalixAgent.RoundConfig.build_round_config(router_id, "router", %{})
    tools = MapSet.new(config.session_config.tool_disclosure["tools"], & &1["name"])
    assert MapSet.member?(tools, "agent.models")
    refute MapSet.member?(tools, "agent.create_worker")
    refute MapSet.member?(tools, "agent.list")

    assert {:ok, %{"created" => true, "conversation_id" => conversation_id}} =
             SalixIM.Provider.call_api(router_id, "internal", "internal.task.create", %{
               "connect_id" => "internal",
               "params" => %{"content" => "Summarize this week's notes."}
             })

    # The Workspace had no Worker: the Task made its Group's Task agent.
    assert [worker] = workers(c.workspace)
    assert worker["agent_id"] == SalixAgent.TaskAgent.id(c.workspace["default_group_id"])

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               c.workspace["default_group_id"],
               conversation_id
             )

    assert Enum.any?(participants, &(&1["agent_id"] == worker["agent_id"]))
    # The Group records it.
    assert {:ok, worker["agent_id"]} == SalixAgent.TaskAgent.get(c.workspace["default_group_id"])
  end

  test "a Workspace's adopted Worker runs its Router's Tasks, under its own name", c do
    workspace = CommaWeb.TestWorkers.with_default_worker!(c.workspace)
    worker = workspace["default_worker_agent_id"]
    group = workspace["default_group_id"]
    {:ok, %{"name" => name}} = SalixAgent.Control.get_record(worker)

    assert {:ok, %{"created" => true, "conversation_id" => conversation_id}} =
             SalixIM.Provider.call_api(
               workspace["router_agent_id"],
               "internal",
               "internal.task.create",
               %{
                 "connect_id" => "internal",
                 "params" => %{"content" => "Draft the weekly update."}
               }
             )

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(group, conversation_id)

    assert Enum.any?(participants, &(&1["agent_id"] == worker))
    assert {:ok, ^worker} = SalixAgent.TaskAgent.get(group)
    assert {:ok, %{"name" => ^name}} = SalixAgent.Control.get_record(worker)
    # Product Tasks run on it too.
    assert {:ok, ^worker} = CommaWeb.AgentManagement.workspace_task_agent(workspace)
    assert [%{"agent_id" => ^worker}] = workers(workspace)
    assert {:error, :not_found} = SalixAgent.Control.get_record(SalixAgent.TaskAgent.id(group))
  end

  test "a release records each Workspace's Task Worker as its Group's Task agent, once", c do
    workspace = CommaWeb.TestWorkers.with_default_worker!(c.workspace, adopt: false)
    worker = workspace["default_worker_agent_id"]
    group = workspace["default_group_id"]

    other_user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{
          "email" => "no-worker-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    bare = create_ready_workspace!(other_user["id"], %{"name" => "Bare"})

    assert {:ok, _counts} = Comma.Migrations.GroupTaskAgents.run(Comma.Repo)
    assert {:ok, ^worker} = SalixAgent.TaskAgent.get(group)
    # A Workspace without a Worker gets none from the pass.
    assert {:ok, nil} = SalixAgent.TaskAgent.get(bare["default_group_id"])
    assert workers(bare) == []

    # A pass run again keeps what the Group has.
    assert {:ok, _counts} = Comma.Migrations.GroupTaskAgents.run(Comma.Repo)
    assert {:ok, ^worker} = SalixAgent.TaskAgent.get(group)
    assert [%{"agent_id" => ^worker}] = workers(workspace)
  end

  test "meeting entries without a Worker converge on the Group's Task agent", c do
    group = c.workspace["default_group_id"]

    entries =
      for n <- 1..3 do
        %{
          "occurrence_id" => "occurrence-000000#{n}",
          "name" => "Standup #{n}",
          "started_at" => 1_790_000_000_000 + n,
          "archive_date" => "2026-10-02"
        }
      end

    tasks =
      entries
      |> Task.async_stream(
        fn entry ->
          user_req(c.token, :post, "/v1/comma/groups/#{group}/meeting-tasks", json: entry)
          |> expect_status(200)
          |> Map.fetch!(:body)
        end,
        timeout: 60_000
      )
      |> Enum.map(fn {:ok, task} -> task end)

    task_workers =
      for task <- tasks do
        {:ok, record} =
          SalixIM.Conversations.get_group_conversation_record(group, task["task_id"])

        record["task_worker_agent_id"]
      end

    assert [worker] = Enum.uniq(task_workers)
    assert worker == SalixAgent.TaskAgent.id(group)
    assert [%{"agent_id" => ^worker}] = workers(c.workspace)

    # The Workspace Group's Cloud VM switch decides for the Task agent too.
    {:ok, record} = SalixAgent.Control.get(worker, c.workspace["salix_tenant_id"])
    assert SalixAgent.CloudVM.allowed?(record) == (c.workspace["vm"]["enabled"] == true)

    # A retried entry returns the same Task.
    retried =
      user_req(c.token, :post, "/v1/comma/groups/#{group}/meeting-tasks", json: hd(entries))
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert retried["task_id"] == hd(tasks)["task_id"]

    # Later product Tasks use it instead of creating another.
    assert {:ok, ^worker} = CommaWeb.AgentManagement.workspace_task_agent(c.workspace)
    assert length(workers(c.workspace)) == 1
  end

  test "Quick Chat sends ordinary Home words and the Router can answer without a Task", c do
    group = c.workspace["default_group_id"]
    home = home(c.token, group)
    home_id = home["id"]
    request = quick_chat("quick-chat-0000000001", "What did I just ask?")

    SalixAgent.LLM.Mock.script([
      home_send(home_id, "You asked what you just asked."),
      {:final, "done"}
    ])

    accepted = send_words(c.token, group, home_id, request)
    message_id = accepted["accepted_message_id"]
    assert SalixStore.Ids.valid_message_id?(message_id)
    assert accepted["id"] == home_id
    # The Router's round may wait on the clock (its Session waits for the
    # Agent's ownership claim), so settle until it answered.
    settle_until(fn -> answered?(group, home_id, "You asked what you just asked.") end)

    assert [said] = Enum.filter(home_messages(group, home_id), &(&1["actor_type"] == "user"))
    assert said["message_id"] == message_id
    assert said["user_id"] == c.user["id"]
    assert said["content"] == [%{"type" => "text", "text" => "What did I just ask?"}]
    assert said["metadata"]["message_type"] == "quick_chat"

    assert answered?(group, home_id, "You asked what you just asked.")

    assert workers(c.workspace) == []

    # An unknown-outcome retry keeps the accepted Message even after the
    # Router replied. Reusing that id for different words fails closed.
    retried = send_words(c.token, group, home_id, request)
    assert retried["accepted_message_id"] == message_id

    user_req(c.token, :post, "/v1/comma/groups/#{group}/conversations/#{home_id}/messages",
      json: put_in(request, ["message", "text"], "changed")
    )
    |> expect_status(409)

    assert Enum.filter(home_messages(group, home_id), &(&1["actor_type"] == "user")) == [said]

    next = send_words(c.token, group, home_id, quick_chat("quick-chat-0000000002", "Thanks"))

    assert [first, second] =
             Enum.filter(home_messages(group, home_id), &(&1["actor_type"] == "user"))

    assert first["message_id"] == message_id
    assert second["message_id"] == next["accepted_message_id"]
    assert first["seq"] < second["seq"]
  end

  test "Home words naming a model start a Task with it, without the Router's turn", c do
    group = c.workspace["default_group_id"]
    home_id = home(c.token, group)["id"]
    {:ok, _key} = key(c.workspace["salix_tenant_id"], "openai", "sk-proj-0123456789abcdefgh")
    # The Router is never woken: nothing is scripted for it.
    SalixAgent.LLM.Mock.script([])

    request = %{
      "client_request_id" => "model-task-0000000001",
      "message" => %{
        "type" => "text",
        "text" =>
          "[GPT 5.5 · High](comma:model/#{@effortful}?effort=high) Draft the release notes.\nKeep it short."
      }
    }

    accepted = send_words(c.token, group, home_id, request)
    settle()

    assert [task] = tasks(c.token, group)
    assert task["title"] == "Draft the release notes."
    assert task["parent_message_id"] == accepted["accepted_message_id"]

    # The Group's Task agent runs it with the named model and effort.
    task_agent = SalixAgent.TaskAgent.id(group)

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group, task["id"])

    # Naming a model chooses it as the menu lists it: an API key serves it when no subscription can.
    assert %{
             "payload" => %{
               "session_model" => %{
                 "model" => @effortful,
                 "reasoning_effort" => "high",
                 "allow_paid" => true
               }
             }
           } = Enum.find(participants, &(&1["agent_id"] == task_agent))

    # The person owns it and wrote its first Message: their words without the mention.
    {:ok, [first | _]} =
      SalixIM.Conversations.list_group_conversation_messages(group, task["id"], limit: 5)

    assert first["actor_type"] == "user"
    assert first["user_id"] == c.user["id"]

    assert first["content"] == [
             %{"type" => "text", "text" => "Draft the release notes.\nKeep it short."}
           ]

    # Home: the words, delivered to no one, then the Router's line naming the Task.
    assert [said, answer] = shown(group, home_id)
    assert said["message_id"] == accepted["accepted_message_id"]
    assert said["delivery_filter"] == %{"participant_ids" => []}
    assert answer["agent_id"] == c.workspace["router_agent_id"]

    assert [%{"type" => "text"}, %{"type" => "conversation_ref", "conversation_id" => id}] =
             answer["content"]

    assert id == task["id"]

    # The Router is told, without a round: its next one knows the Task.
    assert [told] =
             Enum.filter(home_messages(group, home_id), &(&1["actor_type"] == "system"))

    assert told["agent_input"]["no_wake"] == true
    assert told["delivery_filter"]["participant_ids"] != []

    # Sent again, it is the same message: no second Task.
    assert send_words(c.token, group, home_id, request)["accepted_message_id"] ==
             accepted["accepted_message_id"]

    settle()
    assert [_one] = tasks(c.token, group)

    # An effort the model does not take starts none, and says why.
    send_words(c.token, group, home_id, %{
      "client_request_id" => "model-task-0000000002",
      "message" => %{
        "type" => "text",
        "text" => "[GPT 5.5](comma:model/#{@effortful}?effort=ultra) Draft it again."
      }
    })

    settle()
    assert [_one] = tasks(c.token, group)

    assert %{"content" => [%{"type" => "text", "text" => "Could not start a Task" <> _}]} =
             List.last(shown(group, home_id))

    # Naming a model and nothing else starts none, and says why.
    send_words(c.token, group, home_id, %{
      "client_request_id" => "model-task-0000000003",
      "message" => %{"type" => "text", "text" => "[GPT 5.5](comma:model/#{@effortful})"}
    })

    settle()

    assert %{"content" => [%{"type" => "text", "text" => "Write what the Task should do" <> _}]} =
             List.last(shown(group, home_id))
  end

  test "the files a person attaches to Home words naming a model reach the Task", c do
    group = c.workspace["default_group_id"]
    home_id = home(c.token, group)["id"]
    {:ok, _key} = key(c.workspace["salix_tenant_id"], "openai", "sk-proj-0123456789abcdefgh")
    SalixAgent.LLM.Mock.script([])

    # The composer uploaded it into the Router's VFS and names it in the words.
    path = "/uploads/AAAAAAAAAAAAAAAAAAAAAA-notes.txt"
    {:ok, _file} = SalixAgent.Workspace.write(c.workspace["router_agent_id"], path, "Q3: 42")

    send_words(c.token, group, home_id, %{
      "client_request_id" => "model-task-0000000004",
      "message" => %{
        "type" => "text",
        "text" =>
          "[GPT 5.5](comma:model/#{@effortful}) Summarize the notes.\n\n" <>
            "Attached files in your workspace:\n- notes.txt (workspace file: #{path})"
      }
    })

    settle()

    assert [_task] = tasks(c.token, group)
    # The Task agent reads it where the words say it is.
    assert {:ok, "Q3: 42"} = SalixAgent.Workspace.read(SalixAgent.TaskAgent.id(group), path)

    # An upload the Router's VFS does not have starts none, and says which.
    send_words(c.token, group, home_id, %{
      "client_request_id" => "model-task-0000000005",
      "message" => %{
        "type" => "text",
        "text" =>
          "[GPT 5.5](comma:model/#{@effortful}) Summarize these.\n\n" <>
            "Attached files in your workspace:\n" <>
            "- gone.txt (workspace file: /uploads/BBBBBBBBBBBBBBBBBBBBBB-gone.txt)"
      }
    })

    settle()
    assert [_one] = tasks(c.token, group)

    assert %{"content" => [%{"type" => "text", "text" => "Could not start a Task" <> refusal}]} =
             List.last(shown(group, home_id))

    assert refusal =~ "gone.txt"
  end

  test "a model mention counts the files from the person's computer it cannot pass on" do
    content = [
      %{"type" => "text", "text" => "[GPT 5.5](comma:model/gpt-5.5) Read these."},
      %{"type" => "local_file", "local_file_ref" => "lfi1_" <> String.duplicate("a", 43)},
      %{"type" => "local_file", "local_file_ref" => "lfi1_" <> String.duplicate("b", 43)}
    ]

    assert {:ok, %{text: "Read these.", uploads: [], local_files: 2}} =
             SalixIM.ModelMentionTask.parse("[GPT 5.5](comma:model/gpt-5.5) Read these.", content)
  end

  test "a Task the Router makes from spoken words names their Message in the Task list", c do
    group = c.workspace["default_group_id"]
    home_id = home(c.token, group)["id"]

    SalixAgent.LLM.Mock.script([
      {:assistant, "",
       [
         %{
           id: "task-create-spoken",
           name: "call",
           args: %{
             "tool" => "im_api.internal.task.create",
             "params" => %{
               "connect_id" => "internal",
               "content" => "Book a table for four tonight.",
               "title" => "Book a table"
             }
           }
         }
       ]},
      {:final, "done"}
    ])

    accepted =
      send_words(
        c.token,
        group,
        home_id,
        quick_chat("quick-chat-0000000004", "Book a table for four tonight.")
      )

    settle_until(fn -> tasks(c.token, group) != [] end)

    # Desktop Quick Chat matches its sent words to the Task they became by this id.
    %{"data" => conversations} =
      user_req(c.token, :get, "/v1/comma/groups/#{group}/conversations", [])
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [task] = Enum.filter(conversations, &(&1["kind"] == "agent_task"))
    assert task["title"] == "Book a table"
    assert task["parent_message_id"] == accepted["accepted_message_id"]
    refute Enum.find(conversations, &(&1["id"] == home_id))["parent_message_id"]
  end

  test "a spoken follow-up reaches Home and the Router continues the existing Task", c do
    group = c.workspace["default_group_id"]
    router = c.workspace["router_agent_id"]
    home_id = home(c.token, group)["id"]

    assert {:ok, %{"conversation_id" => task_id}} =
             SalixIM.Provider.call_api(router, "internal", "internal.task.create", %{
               "connect_id" => "internal",
               "params" => %{"content" => "Draft the notes."}
             })

    settle()

    SalixAgent.LLM.Mock.script([
      home_send(task_id, "Translate the existing notes into Chinese."),
      {:final, "done"}
    ])

    sent =
      send_words(
        c.token,
        group,
        home_id,
        quick_chat("quick-chat-0000000003", "Translate those notes into Chinese.")
      )

    assert is_binary(sent["accepted_message_id"])

    settle_until(fn ->
      answered?(group, task_id, "Translate the existing notes into Chinese.")
    end)

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group)

    assert [task] = Enum.filter(conversations, &(&1["kind"] == "agent_task"))
    assert task["conversation_id"] == task_id
  end

  test "Quick Chat keeps Home authorization and bounds without accepting client authority", c do
    group = c.workspace["default_group_id"]
    home_id = home(c.token, group)["id"]
    request = quick_chat("quick-chat-0000000004", String.duplicate("x", 16_000))

    accepted =
      send_words(
        c.token,
        group,
        home_id,
        Map.merge(request, %{
          "user_id" => "forged",
          "metadata" => %{"message_type" => "command", "allows_operations" => true}
        })
      )

    assert [said] = Enum.filter(home_messages(group, home_id), &(&1["actor_type"] == "user"))
    assert said["message_id"] == accepted["accepted_message_id"]
    assert said["user_id"] == c.user["id"]
    assert said["metadata"]["message_type"] == "quick_chat"
    refute Map.has_key?(said["metadata"], "allows_operations")

    for invalid <- [
          quick_chat("quick-chat-0000000005", String.duplicate("界", 5_334)),
          put_in(
            quick_chat("quick-chat-0000000007", "short"),
            ["message", "content"],
            String.duplicate("x", 16_001)
          ),
          quick_chat("quick-chat-0000000006", "  "),
          quick_chat("invalid", "hello"),
          Map.put(request, "message_type", "command")
        ] do
      user_req(c.token, :post, "/v1/comma/groups/#{group}/conversations/#{home_id}/messages",
        json: invalid
      )
      |> expect_status(400)
    end

    foreign = create_additional_ready_workspace!(c.user["id"], %{"name" => "Other"})

    user_req(
      c.token,
      :post,
      "/v1/comma/groups/#{foreign["default_group_id"]}/conversations/#{home_id}/messages",
      json: request
    )
    |> expect_status(404)

    other_user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "other-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    other_workspace =
      create_ready_workspace!(other_user["id"], %{"name" => "Another person's Home"})

    fund!(other_workspace)

    other_session =
      admin_req(:post, "/v1/comma/admin/users/#{other_user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    other_group = other_workspace["default_group_id"]
    other_home = home(other_session["token"], other_group)["id"]
    other_accepted = send_words(other_session["token"], other_group, other_home, request)
    assert other_accepted["accepted_message_id"] != accepted["accepted_message_id"]

    assert [other_said] =
             Enum.filter(home_messages(other_group, other_home), &(&1["actor_type"] == "user"))

    assert other_said["user_id"] == other_user["id"]

    user_req(
      other_session["token"],
      :post,
      "/v1/comma/groups/#{group}/conversations/#{home_id}/messages",
      json: request
    )
    |> expect_status(404)

    assert Enum.filter(home_messages(group, home_id), &(&1["actor_type"] == "user")) == [said]
  end

  @tag :subscriptions
  test "the Router creates a Worker with a catalog model and effort", c do
    workspace = c.workspace
    tenant = workspace["salix_tenant_id"]
    {:ok, openai} = key(tenant, "openai", "sk-proj-0123456789abcdefgh")
    {:ok, anthropic} = key(tenant, "anthropic", "sk-ant-0123456789abcdefgh")

    Repo.update_all(from(u in Comma.Accounts.User, where: u.id == ^c.user["id"]),
      set: [locale: "zh-CN"]
    )

    Repo.insert!(%Comma.Data.RecommendationProfile{
      workspace_id: workspace["id"],
      user_id: c.user["id"],
      timezone: "Asia/Shanghai"
    })

    assert {:ok, listed} = AgentManagement.run(:models, %{"query" => @effortful}, ctx(c, "m"))
    assert listed["user"] == %{"locale" => "zh-CN", "timezone" => "Asia/Shanghai"}

    assert %{"served_by" => "api_key", "requires_allow_paid" => true} =
             Enum.find(listed["models"], &(&1["id"] == @effortful))

    model = %{
      "kind" => "catalog",
      "model" => @effortful,
      "reasoning_effort" => "high",
      "allow_paid" => true
    }

    assert {:ok, created} = AgentManagement.run(:create, create_args(model), ctx(c, "create"))
    worker = created["agent"]["agent_id"]
    assert created["agent"]["model"]["model_id"] == @effortful

    # The Worker stores the choice itself.
    {:ok, record} = SalixAgent.Control.get(worker, tenant)
    assert record["model"] == model
    assert SalixAgent.CloudVM.allowed?(record) == (workspace["vm"]["enabled"] == true)

    # A replay with another model is a different invocation.
    assert {:error, %{"code" => "invocation_conflict"}} =
             AgentManagement.run(
               :create,
               create_args(%{model | "reasoning_effort" => "low"}),
               ctx(c, "create")
             )

    # The settings path's validation: the model's efforts, and a pinned
    # Profile that serves the model.
    for {bad, call} <- [
          {%{model | "reasoning_effort" => "ultra"}, "bad-effort"},
          {Map.put(model, "profile_id", anthropic["id"]), "bad-profile"}
        ] do
      assert {:error, %{"code" => "invalid_model_configuration"}} =
               AgentManagement.run(:create, create_args(bad), ctx(c, call))
    end

    assert [%{"agent_id" => ^worker}] = workers(workspace)

    # A pinned Profile that serves the model is accepted.
    assert {:ok, _} =
             AgentManagement.run(
               :create,
               create_args(Map.put(model, "profile_id", openai["id"])),
               ctx(c, "pinned")
             )
  end

  # The Router's send to Home, as an internal session calls a capability tool.
  defp home_send(conversation_id, text) do
    {:assistant, "",
     [
       %{
         id: "home-send-#{conversation_id}",
         name: "call",
         args: %{
           "tool" => "im_api.internal.send_message",
           "params" => %{
             "connect_id" => "internal",
             "conversation_id" => conversation_id,
             "content" => [%{"type" => "text", "text" => text}]
           }
         }
       }
     ]}
  end

  defp create_args(model) do
    %{
      "name" => "Linnea",
      "purpose" => "General research and writing for this Workspace",
      "creation_reason" => "The Workspace has no Worker",
      "runtime" => %{"kind" => "internal"},
      "model" => model
    }
  end

  defp ctx(c, call) do
    %{
      agent_id: c.workspace["router_agent_id"],
      session_id: "router-session",
      tool_call_id: call
    }
  end

  # A test Workspace's model calls need a funded billing account.
  defp fund!(%{"billing_account_id" => account_id, "id" => workspace_id}) do
    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace_id
      })

    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        credits: 100,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at:
          SystemsClock.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second),
        source_type: "manual_contract",
        source_id: "router-created-workers-test:#{workspace_id}",
        source_event_id: "router-created-workers-test:#{workspace_id}",
        idempotency_key: "router-created-workers-test:#{workspace_id}:2026-06"
      })

    :ok
  end

  defp quick_chat(id, text),
    do: %{
      "client_request_id" => id,
      "message_type" => "quick_chat",
      "message" => %{"type" => "text", "text" => text}
    }

  defp home(token, group) do
    user_req(token, :post, "/v1/comma/groups/#{group}/assistant-chat", json: %{})
    |> expect_status(200)
    |> Map.fetch!(:body)
  end

  defp send_words(token, group, home, request) do
    user_req(token, :post, "/v1/comma/groups/#{group}/conversations/#{home}/messages",
      json: request
    )
    |> expect_status(202)
    |> Map.fetch!(:body)
  end

  defp answered?(group, conversation, text) do
    Enum.any?(
      home_messages(group, conversation),
      &(&1["content"] == [%{"type" => "text", "text" => text}])
    )
  end

  defp home_messages(group, home) do
    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(group, home, limit: 50)

    messages
  end

  # Home as people see it: no message only Agents read.
  defp shown(group, home),
    do: Enum.reject(home_messages(group, home), &(&1["actor_type"] == "system"))

  defp tasks(token, group) do
    user_req(token, :get, "/v1/comma/groups/#{group}/conversations", [])
    |> expect_status(200)
    |> get_in([Access.key(:body), "data"])
    |> Enum.filter(&(&1["kind"] == "agent_task"))
  end

  defp workers(workspace) do
    {:ok, page} =
      SalixAgent.Control.page_workers(
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        limit: 50
      )

    page.items
  end

  defp key(tenant, source, api_key) do
    AccountPool.create(tenant, %{
      "credential_kind" => "provider_api_key",
      "source" => source,
      "api_key" => api_key
    })
  end

  defp admin_req(method, path, opts),
    do: req([{"authorization", "Bearer " <> @admin_token}], method, path, opts)

  defp user_req(token, method, path, opts),
    do: req([{"authorization", "Bearer " <> token}], method, path, opts)

  defp req(headers, method, path, opts) do
    Req.request!(
      [
        method: method,
        url: CommaWeb.Application.base_url() <> path,
        headers: headers,
        retry: false
      ] ++ opts
    )
  end

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp
  end
end
