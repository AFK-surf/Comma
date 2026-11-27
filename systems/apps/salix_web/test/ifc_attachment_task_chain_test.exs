defmodule SalixWeb.IFCAttachmentTaskChainTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixStore.{CasRecord, Ids, Keys, CodingSandboxes, StationTaskSessions}
  alias SalixIM.{Conversations, ProviderConnects}

  defmodule GitHub do
    @moduledoc false
    def token(_tenant, _group), do: {:ok, %{token: "ghu_group_token", expires_at: nil}}

    def user("ghu_group_token"),
      do: {:ok, %{login: "octo", id: 7, email: "7+octo@users.noreply.github.com"}}

    def repo(_token, owner, name),
      do:
        {:ok, %{full_name: "#{owner}/#{name}", default_branch: "main", private: true, push: true}}
  end

  defmodule Signer do
    @moduledoc false
    def sign(claims), do: {:ok, "assertion-for-" <> claims.workspace_id}
  end

  defmodule Station do
    @moduledoc "The sandbox's station: it joins the Task."
    def request(_run_id, method, params, _opts) do
      case method do
        "task.invite" -> {:ok, %{"session" => "ember:c-1"}}
        "task.put" -> {:ok, %{"through" => params["through"]}}
      end
    end
  end

  defmodule Delivery do
    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(agent, payload, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :attachment_chain_pid),
        {:delivered, agent, payload}
      )

      {:ok, %{}}
    end
  end

  defmodule TaskCreate do
    def runs_on(_scope, request), do: {:ok, request}
    def personal_computers(_scope), do: {:ok, []}

    def create_task_conversation(group, router, worker, attrs) do
      with {:ok, id} <-
             SalixIM.ConversationServer.reserve_task_conversation_id(group, router, worker, attrs) do
        SalixIM.TaskConversationInput.create_with_id(
          group,
          id,
          router,
          worker,
          attrs
          |> Map.put("schedule", %{"schedule_id" => nil, "command" => attrs["content"]})
          |> Map.put("initial_message_attrs", %{
            "kind" => "message",
            "actor_type" => "agent",
            "agent_id" => router,
            "content" => attrs["content"],
            "client_request_id" => "delegate-task-" <> id,
            "metadata" => %{"message_type" => "task_command"}
          })
        )
      end
    end
  end

  defmodule API do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, _) do
      {:ok, raw, conn} = read_body(conn)

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_im, :attachment_chain_pid),
        {:provider_call, conn.method, conn.request_path, raw}
      )

      if raw =~ "Package processed" do
        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_im, :attachment_chain_pid),
          {:visible_reply, conn.request_path, raw}
        )
      end

      body = %{
        "code" => 0,
        "data" => %{
          "chat_id" => "oc_1",
          "chat_type" => "public",
          "chat_mode" => "group",
          "name" => "Team",
          "message_id" => "om_sent",
          "items" => [%{"message_id" => "om_source", "chat_id" => "oc_1"}]
        }
      }

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    SalixWeb.TestSupport.CodingSandboxes.park_left!()
    SalixIM.TestSupport.Fleet.stop_all!()
    SalixAgent.TestSupport.stop_all_agents()
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    port = SalixIM.TestSupport.BanditServer.start!(fn p -> {Bandit, plug: API, port: p} end)

    overrides = [
      {:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis"},
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_store, :compute_workload_credential_secret, String.duplicate("s", 32)},
      {:salix_im, :conversation_placement, SalixIM.ConversationPlacement.LocalFleet},
      {:salix_im, :agent_delivery_mod, Delivery},
      {:salix_im, :task_create_mod, TaskCreate},
      {:salix_im, :agent_workspace_mod, Salix.Bindings.IMAgentWorkspace},
      {:salix_im, :attachment_chain_pid, SystemsRuntime.Proc.self()},
      {:salix_im, :protected_source_ref_contracts,
       [
         SalixIM.TaskExecution,
         SalixIM.TaskContinuation,
         SalixIM.TaskReplySource,
         SalixIM.IFCSourceRefs
       ]},
      {:salix_agent, :im_provider_mod, SalixIM.Provider},
      {:salix_agent, :ifc_facts_mod, SalixIM.IFC.Facts},
      {:salix_agent, :sandboxes_mod, SalixWeb.L4ES},
      {:salix_agent, :cloud_vm_retired, true},
      {:salix_web, :l4es,
       [url: "https://l4es.test", req_options: [plug: {Req.Test, __MODULE__}]]},
      {:salix_web, :l4es_assertion_signer, Signer},
      {:salix_web, :coding_github, GitHub},
      {:salix_web, :station_tasks, [connector: Station]}
    ]

    previous = Enum.map(overrides, fn {a, k, _} -> {a, k, SystemsRuntime.get_env(a, k)} end)
    for {a, k, v} <- overrides, do: SystemsRuntime.put_env(a, k, v)

    on_exit(fn ->
      SalixIM.TestSupport.Fleet.stop_all!()
      SalixAgent.TestSupport.stop_all_agents()

      for {a, k, v} <- previous do
        if is_nil(v), do: SystemsRuntime.delete_env(a, k), else: SystemsRuntime.put_env(a, k, v)
      end
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "POST" -> Req.Test.json(Plug.Conn.put_status(conn, 201), %{"state" => "scheduled"})
        "GET" -> Req.Test.json(conn, %{"state" => "running"})
        _ -> Req.Test.json(conn, %{})
      end
    end)

    Req.Test.set_req_test_to_shared()
    start_supervised!(SalixWeb.L4ESRecent)
    :ok
  end

  test "private provider attachment follows the Task to its sandbox and report to the original user" do
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "name" => "Router",
        "role" => "router"
      })["agent_id"]

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "name" => "Worker",
        "role" => "worker"
      })["agent_id"]

    {:ok, _} =
      CasRecord.update(
        Keys.ctl_group(group),
        &Map.merge(&1, %{"router_agent_id" => router, "ifc" => %{"mode" => "enforce"}})
      )

    connect = Ids.new_connect_id()

    {:ok, _} =
      CasRecord.create(Keys.ctl_im_connect(group, connect), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "connect_id" => connect,
        "provider" => "feishu",
        "status" => "connected",
        "app_id" => "cli_a",
        "app_secret" => "test-secret",
        "tenant_access_token" => "t-test"
      })

    metadata = %{
      "provider" => "feishu",
      "connect_id" => connect,
      "chat_id" => "oc_1",
      "chat_type" => "p2p",
      "message_id" => "om_source",
      "sender_open_id" => "ou_1",
      "sender_type" => "user",
      "user_placement" => "internal"
    }

    source = "im_provider:feishu:#{connect}:om_source"
    {:ok, blob} = SalixStore.Blob.put_stream(router, ["private migration package"])

    attachment = %{
      "path" => "/migration.bin",
      "file_name" => "migration.bin",
      "to_blob" => fn _ -> {:ok, blob} end,
      "ifc_label" => ["public"]
    }

    assert {:ok, :queued} =
             ProviderConnects.enqueue_group_router_im_provider_message(
               group,
               "Analyze this package",
               metadata,
               source,
               attachments: [attachment]
             )

    settle_receive({:delivered, ^router, input})
    ctx = context(tenant, group, router, "router", input)
    label = SalixAgent.AgentWorkspace.label(router, "/migration.bin")
    refute label in [nil, ["public"], ["agent_private"]]
    ref = SalixAgent.IFC.input_ref(1)

    result =
      execute(
        ctx,
        "im_api.internal.task.create",
        %{
          "agent_id" => worker,
          "connect_id" => "internal",
          "runs_on" => %{"kind" => "default"},
          "content" => "Analyze the migration package"
        },
        ref
      )

    assert result.status == "completed", inspect(result)
    task = Jason.decode!(result.content)["conversation_id"]
    settle_receive({:delivered, ^worker, assignment})
    worker_ctx = context(tenant, group, worker, "worker", assignment)

    shared =
      execute(
        ctx,
        "im_api.internal.send_message",
        %{
          "connect_id" => "internal",
          "conversation_id" => task,
          "content" => [
            %{"type" => "file", "path" => "/migration.bin", "file_name" => "migration.bin"}
          ]
        },
        ref
      )

    assert shared.status == "completed", inspect(shared)
    {:ok, messages} = Conversations.list_group_conversation_messages(group, task)
    {:ok, materialized} = SalixIM.ConversationAttachments.materialize_messages(worker, messages)

    file =
      materialized
      |> Enum.flat_map(&List.wrap(&1["content"]))
      |> Enum.find(&(is_map(&1) and &1["type"] == "file"))

    assert is_map(file)
    assert SalixAgent.AgentWorkspace.label(worker, file["path"]) == label
    view = sandbox(tenant, group, worker, task)

    read = %{
      "task" => task,
      "session" => "ember:c-1",
      "tool" => "fs.read_file",
      "args" => %{"path" => file["path"], "ifc" => %{"sources" => []}}
    }

    assert {:ok, %{"error" => false, "content" => content}} =
             SalixWeb.StationTasks.tool_call(view, read)

    assert content =~ "private migration package"
    # A second Task has a different authenticated provider requester.
    other_meta =
      Map.merge(metadata, %{
        "chat_id" => "oc_other",
        "sender_open_id" => "ou_other",
        "message_id" => "om_other"
      })

    assert {:ok, :queued} =
             ProviderConnects.enqueue_group_router_im_provider_message(
               group,
               "Read a package",
               other_meta,
               "im_provider:feishu:#{connect}:om_other"
             )

    settle_receive({:delivered, ^router, other_input})

    other =
      execute(
        context(tenant, group, router, "router", other_input),
        "im_api.internal.task.create",
        %{
          "agent_id" => worker,
          "connect_id" => "internal",
          "runs_on" => %{"kind" => "default"},
          "content" => "Read a package"
        },
        ref
      )

    assert other.status == "completed", inspect(other)
    other_task = Jason.decode!(other.content)["conversation_id"]
    other_view = sandbox(tenant, group, worker, other_task)

    assert {:ok, %{"error" => "label_not_this_task"} = denied} =
             SalixWeb.StationTasks.tool_call(other_view, Map.put(read, "task", other_task))

    refute inspect(denied) =~ "private migration package"

    report =
      execute(
        worker_ctx,
        "im_api.internal.send_message",
        %{
          "connect_id" => "internal",
          "conversation_id" => task,
          "content" => [%{"type" => "text", "text" => "Package processed"}]
        },
        ref
      )

    assert report.status == "completed", inspect(report)
    settle_receive({:delivered, ^router, report_input})
    reply_ctx = context(tenant, group, router, "router", report_input)
    assert {:ok, [audience]} = SalixIM.TaskContinuation.ifc_projection_targets(reply_ctx)
    assert audience == input[:trusted_origin]["ifc"]["label"]

    assert :none =
             SalixIM.TaskContinuation.ifc_projection_targets(%{
               reply_ctx
               | source_message_id: "unconsumed"
             })

    args = %{
      "connect_id" => connect,
      "message_id" => "om_source",
      "chat_id" => "oc_1",
      "text" => "Package processed"
    }

    assert {:ok, _, _, _} =
             SalixIM.Provider.task_execution_request("im_api.feishu.reply_text", args, reply_ctx)

    reply = execute(reply_ctx, "im_api.feishu.reply_text", args, ref)
    assert reply.status == "completed", inspect(reply)
    assert_received {:visible_reply, "/open-apis/im/v1/messages/om_source/reply", body}
    assert body =~ "Package processed"

    assert :none =
             SalixIM.Provider.task_execution_request(
               "im_api.feishu.reply_text",
               Map.put(args, "chat_id", "oc_other"),
               reply_ctx
             )

    {:ok, connect_record} = CasRecord.get(Keys.ctl_im_connect(group, connect))

    binding = %{
      "group_id" => group,
      "conversation_id" => task,
      "chat_id" => "oc_1",
      "thread_id" => "omt_bound",
      "reply_message_id" => "om_source"
    }

    bound_attachment = Map.put(attachment, "path", "/bound.bin")

    assert {:ok, _} =
             SalixIM.FeishuThreadTaskBinding.append_message(connect_record, binding, %{
               "source_message_id" => "im_provider:feishu:#{connect}:om_bound",
               "user_id" => "ou_1",
               "content" => "Follow-up package",
               "metadata" => metadata,
               "attachments" => [bound_attachment]
             })

    assert SalixAgent.AgentWorkspace.label(worker, "/bound.bin") == label
  end

  defp context(tenant, group, agent, role, payload) do
    origin = payload[:trusted_origin]
    source = origin["source_message_id"]

    input = %{
      id: 1,
      role: "user",
      content: payload[:content],
      source_message_id: source,
      trusted_origin: origin
    }

    ctx =
      %{
        tenant_id: tenant,
        group_id: group,
        agent_id: agent,
        session_id: payload[:session_id],
        role: role,
        runtime_kind: :internal,
        trusted_origin: origin,
        source_message_id: source,
        source_message_ids: [source],
        ifc_mode: :enforce,
        input_messages: [input],
        ifc:
          SalixAgent.IFC.Context.build(%{messages: [input]},
            source_message_id: source,
            source_message_ids: [source],
            trusted_origin: origin
          )
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, SalixAgent.ToolDisclosure.materialize(role, :internal, ctx))
  end

  defp execute(ctx, name, args, ref) do
    [result] =
      SalixAgent.SessionToolDispatch.execute(
        [
          %{
            id: Ids.new_message_id(),
            name: name,
            args: args,
            ifc: %{"request" => ref, "sources" => [ref]}
          }
        ],
        ctx
      )

    result
  end

  defp sandbox(tenant, group, worker, task) do
    repo = %{"owner" => "ann", "name" => "api", "base_ref" => "main", "branch" => "comma/code"}

    r = %{
      tenant_id: tenant,
      group_id: group,
      conversation_id: task,
      device_id: CodingSandboxes.device_id(task),
      agent_id: worker,
      start: %{"requester" => worker <> "@agents.salix", "runtime" => "claude", "repo" => repo},
      repo: repo
    }

    :ok = SalixWeb.CodingSandboxes.reserve(r)
    {:ok, w} = CodingSandboxes.get_by_conversation(tenant, task)

    {:ok, _} =
      CodingSandboxes.update(w.id, fn w -> {:ok, Map.put(w.spec, "next_check_at", "0")} end)

    SalixWeb.CodingSandboxes.check_due()
    {:ok, w} = CodingSandboxes.get_by_conversation(tenant, task)
    transport = CodingSandboxes.transport_id(task)

    {:ok, ^transport, record} =
      SalixEnv.Registry.connect(
        "test-node",
        %{
          "tenant_id" => tenant,
          "group_id" => group,
          "device_id" => r.device_id,
          "connector_id" => CodingSandboxes.connector_id(task),
          "workload_id" => w.id,
          "workload_generation" => w.generation,
          "name" => "Coding sandbox"
        },
        transport_id: transport
      )

    view = %{
      tenant_id: tenant,
      group_id: group,
      device_id: r.device_id,
      connector_run_id: record["connector_run_id"],
      workload_id: w.id,
      workload_generation: w.generation
    }

    SalixWeb.CodingSandboxes.connected(view)
    assert {:ok, [%{session: "ember:c-1"}]} = StationTaskSessions.of_task(group, task)
    view
  end
end
