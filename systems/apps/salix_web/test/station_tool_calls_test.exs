defmodule SalixWeb.StationToolCallsTest do
  @moduledoc """
  A sandbox Task's Session lists and calls Salix tools as the Task's Worker
  (`task.tools`, `task.tool_call`; `SalixWeb.StationTasks.tool_call/2`):
  only from the Task's current sandbox, the tools the Worker may call in
  Salix, with a real effect in the Worker's VFS. L4ES, the station
  and the Task are fakes; the sandbox Workload is real.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixEnv.Registry
  alias SalixStore.CodingSandboxes, as: Store
  alias SalixStore.StationTaskSessions
  alias SalixWeb.{CodingSandboxes, StationTasks}

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

  defmodule Facts do
    @moduledoc """
    The production IFC facts (`SalixIM.IFC.Facts`), each request kept for the
    test to read. The Task's readers (`source_refs.ifc_members`, sealed when a
    Task is made from a person's request) are added here: the Task of these
    tests is the fake port's, so the production facts have no record of it.
    """
    def mode(tenant_id, group_id), do: SalixIM.IFC.Facts.mode(tenant_id, group_id)

    def resolve(request) do
      Process.put(:ifc_test_requests, [request | Process.get(:ifc_test_requests, [])])

      with {:ok, reply} <- SalixIM.IFC.Facts.resolve(request) do
        [atom] = task_label()
        members = Process.get(:ifc_test_task_members, ["comma_user|usr_owner"])

        {:ok, put_in(reply, ["membership", atom], %{"members" => members, "revision" => 1})}
      end
    end

    def consume_receipt(request), do: SalixIM.IFC.Facts.consume_receipt(request)

    def task_label do
      SalixIM.IFC.Ingress.conversation_block(%{
        "conversation_id" => "cnv_tools",
        "conversation_kind" => "agent_task"
      })["label"]
    end
  end

  defmodule Task do
    @moduledoc "The Task: its record, Worker and Messages."
    def last(_group, _conversation), do: {:ok, %{"message_id" => "msg_latest"}}

    use Agent

    def start_link(state), do: SystemsRuntime.Agent.start_link(fn -> state end, name: __MODULE__)
    def messages, do: SystemsRuntime.Agent.get(__MODULE__, & &1.messages)

    def task(_group, _conversation), do: {:ok, SystemsRuntime.Agent.get(__MODULE__, & &1.record)}

    def owner(_group, _conversation) do
      case SystemsRuntime.Agent.get(__MODULE__, &Map.get(&1, :owner, "usr_owner")) do
        nil -> {:error, :no_owner}
        owner -> {:ok, owner}
      end
    end

    def status(_group, _conversation), do: {:ok, "active"}

    def participants(_group, _conversation),
      do: {:ok, SystemsRuntime.Agent.get(__MODULE__, & &1.participants)}

    def append(_group, _conversation, _agent, attrs) do
      SystemsRuntime.Agent.get_and_update(__MODULE__, fn state ->
        message = Map.put(attrs, "seq", length(state.messages) + 1)
        {{:ok, message}, %{state | messages: state.messages ++ [message]}}
      end)
    end

    def messages_after(_group, _conversation, after_seq, limit),
      do: {:ok, messages() |> Enum.filter(&(&1["seq"] > after_seq)) |> Enum.take(limit)}
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

  setup do
    SalixWeb.TestSupport.CodingSandboxes.park_left!()

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Tool calls"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Tool calls"}, tenant["tenant_id"])

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    repo = %{"owner" => "ann", "name" => "api", "base_ref" => "main", "branch" => "comma/code"}

    start_supervised!(
      {Task,
       %{
         record: %{"repo" => repo},
         messages: [],
         participants: [
           %{
             "participant_id" => "ptp_worker",
             "actor_type" => "agent",
             "agent_id" => worker["agent_id"],
             "role_label" => "worker",
             "state" => "active"
           }
         ]
       }}
    )

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.method do
        "POST" -> Req.Test.json(Plug.Conn.put_status(conn, 201), %{"state" => "scheduled"})
        "GET" -> Req.Test.json(conn, %{"state" => "running"})
        _ -> Req.Test.json(conn, %{})
      end
    end)

    Req.Test.set_req_test_to_shared()

    for {key, value} <- [
          l4es: [url: "https://l4es.test", req_options: [plug: {Req.Test, __MODULE__}]],
          l4es_assertion_signer: Signer,
          coding_github: GitHub,
          station_tasks: [conversations: Task, connector: Station]
        ],
        do: SystemsRuntime.put_env(:salix_web, key, value)

    # The Cloud VM is retired here: a sandbox's Worker creates sandbox Tasks.
    sandboxes_mod = SystemsRuntime.get_env(:salix_agent, :sandboxes_mod)
    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SalixWeb.L4ES)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_retired, true)

    previous = SystemsRuntime.get_env(:salix_store, :compute_workload_credential_secret)

    SystemsRuntime.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("s", 32)
    )

    on_exit(fn ->
      for key <- [:l4es, :l4es_assertion_signer, :coding_github, :station_tasks],
          do: SystemsRuntime.delete_env(:salix_web, key)

      SystemsRuntime.delete_env(:salix_agent, :cloud_vm_retired)

      if sandboxes_mod,
        do: SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, sandboxes_mod),
        else: SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod)

      if previous,
        do: SystemsRuntime.put_env(:salix_store, :compute_workload_credential_secret, previous),
        else: SystemsRuntime.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    r = %{
      tenant_id: tenant["tenant_id"],
      group_id: group["group_id"],
      conversation_id: "cnv_tools",
      device_id: Store.device_id("cnv_tools"),
      agent_id: worker["agent_id"],
      start: %{
        "requester" => worker["agent_id"] <> "@agents.salix",
        "runtime" => "claude",
        "repo" => repo
      },
      repo: repo
    }

    start_supervised!(SalixWeb.L4ESRecent)
    SalixWeb.L4ESRecent.forget(r.group_id)

    # The sandbox is made, its station connects with this generation and takes
    # part in the Task.
    :ok = CodingSandboxes.reserve(r)
    {:ok, w} = Store.get_by_conversation(r.tenant_id, r.conversation_id)
    {:ok, _} = Store.update(w.id, fn w -> {:ok, Map.put(w.spec, "next_check_at", "0")} end)
    CodingSandboxes.check_due()
    view = connect!(r)

    assert {:ok, [%{session: "ember:c-1"}]} =
             StationTaskSessions.of_task(r.group_id, r.conversation_id)

    {:ok, r: r, view: view}
  end

  defp connect!(r) do
    {:ok, w} = Store.get_by_conversation(r.tenant_id, r.conversation_id)
    transport = Store.transport_id(r.conversation_id)

    {:ok, ^transport, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => r.tenant_id,
          "group_id" => r.group_id,
          "device_id" => r.device_id,
          "connector_id" => Store.connector_id(r.conversation_id),
          "workload_id" => w.id,
          "workload_generation" => w.generation,
          "name" => "Coding sandbox"
        },
        transport_id: transport
      )

    view = %{
      tenant_id: r.tenant_id,
      group_id: r.group_id,
      device_id: r.device_id,
      connector_run_id: record["connector_run_id"],
      workload_id: w.id,
      workload_generation: w.generation
    }

    CodingSandboxes.connected(view)
    view
  end

  defp params(more), do: Map.merge(%{"task" => "cnv_tools", "session" => "ember:c-1"}, more)

  test "the current sandbox lists the Worker's tools, and calls one with an effect in the Worker's VFS",
       %{view: view} do
    assert {:ok, %{"tools" => tools}} = StationTasks.tools(view, params(%{}))
    names = Enum.map(tools, & &1["name"])
    assert "fs.write_file" in names
    assert "fs.read_file" in names
    assert "help" in names
    # What a Worker on the Cloud VM or a Station calls, a sandbox calls too.
    assert "env.exec" in names
    assert "preview.publish_html" in names
    # One sandbox Task of its own, where sandboxes are set up (they are here).
    assert "im_api.internal.task.create" in names

    write = Enum.find(tools, &(&1["name"] == "fs.write_file"))
    assert is_binary(write["description"]) and write["description"] != ""
    assert %{"type" => "object"} = write["input_schema"]

    assert {:ok, %{"tool" => "fs.write_file", "error" => false, "content" => wrote}} =
             StationTasks.tool_call(
               view,
               params(%{
                 "tool" => "fs.write_file",
                 "args" => %{
                   "path" => "/from-sandbox.md",
                   "content" => "written from the sandbox"
                 }
               })
             )

    assert wrote =~ "/from-sandbox.md"

    assert {:ok, %{"error" => false, "content" => read}} =
             StationTasks.tool_call(
               view,
               params(%{"tool" => "fs.read_file", "args" => %{"path" => "/from-sandbox.md"}})
             )

    assert read =~ "written from the sandbox"

    # The Worker's skills, as its own round sees them.
    assert {:ok, %{"error" => false, "content" => index}} =
             StationTasks.tool_call(
               view,
               params(%{
                 "tool" => "fs.read_file",
                 "args" => %{"path" => "/.runtime/skills/index.md"}
               })
             )

    assert index =~ "website-manager"
    refute index =~ "No skills are visible"
    # Nothing is written into the Task by a call.
    assert Task.messages() == []
  end

  test "a sandbox call acts for the Task's owner: their credential is usable, another's is not",
       %{view: view} do
    bind = fn alias_name, owner ->
      connection = "conn-#{alias_name}"

      :ok =
        SalixStore.OAuth.put(connection, %{
          "provider" => "github",
          "access_token" => "tok-#{alias_name}",
          "status" => "active",
          "owner" => owner
        })

      {:ok, _binding, _previous} =
        Salix.Control.OAuthBindings.put(
          view.tenant_id,
          view.group_id,
          "github",
          alias_name,
          connection
        )
    end

    {:ok, _app} =
      Salix.Control.OAuthApps.put(view.tenant_id, "github", %{
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    bind.("mine", "comma_user|usr_owner")
    bind.("theirs", "comma_user|usr_other")

    assert {:ok, %{"error" => false, "content" => listed}} =
             StationTasks.tool_call(
               view,
               params(%{"tool" => "oauth.list_credentials", "args" => %{}})
             )

    usable =
      for entry <- Jason.decode!(listed)["credentials"],
          into: %{},
          do: {entry["alias"], entry["usable"]}

    assert usable == %{"mine" => true, "theirs" => false}
  end

  test "a sandbox asks its person for a secret: the card is in the Task, and the call returns with their answer",
       %{view: view} do
    call =
      SystemsRuntime.Task.async(fn ->
        StationTasks.tool_call(
          view,
          params(%{
            "tool" => "oauth.request_authorization",
            "args" => %{
              "provider" => "secret",
              "alias" => "openai",
              "reason" => "The script needs it.",
              "label" => "OpenAI API Key"
            }
          })
        )
      end)

    request = eventually_pending_request(view)
    oauth = request["request_payload"]["oauth_authorization"]
    assert oauth["input"] == %{"kind" => "secret", "label" => "OpenAI API Key"}

    SalixWeb.OAuthFlow.submit_secret(oauth["state"], "sk-typed")

    assert {:ok, %{"error" => false, "content" => content}} =
             SystemsRuntime.Task.await(call, :infinity)

    assert %{"status" => "completed", "provider" => "secret", "alias" => "openai"} =
             Jason.decode!(content)

    refute content =~ "sk-typed"
  end

  test "a Task with no owner acts for the Comma person who asked for it", %{view: view} do
    SystemsRuntime.Agent.update(Task, fn state ->
      state
      |> Map.put(:owner, nil)
      |> put_in([:record, "source_refs"], %{"ifc_requester" => "comma_user|usr_asker"})
    end)

    assert {:ok, %{"kept" => true}} =
             StationTasks.login_keep(view, params(%{"program" => "gh", "archive" => "dGFy"}))

    assert {:ok, "dGFy"} =
             SalixWeb.OAuthFlow.kept_login(
               view.tenant_id,
               view.group_id,
               "comma_user|usr_asker",
               "gh"
             )
  end

  test "a sandbox's CLI login has a card in the Task, and its files are kept for that person alone",
       %{view: view} do
    card = fn args ->
      assert {:ok, %{"error" => false}} =
               StationTasks.tool_call(
                 view,
                 params(%{"tool" => "oauth.login_card", "args" => args})
               )
    end

    card.(%{
      "login" => "login-1",
      "program" => "gh",
      "reason" => "Push the branch.",
      "url" => "https://github.com/login/device",
      "code" => "ABCD-1234"
    })

    request = eventually_pending_request(view)
    oauth = request["request_payload"]["oauth_authorization"]
    assert oauth["provider"] == "cli"
    assert oauth["input"] == %{"kind" => "device", "code" => "ABCD-1234"}
    assert oauth["authorization_url"] == "https://github.com/login/device"
    # Its receipt stays under the reply to the Task's latest message.
    assert request["surface_ref"]["message_id"] == "msg_latest"

    card.(%{"login" => "login-1", "program" => "gh", "ended" => "done"})

    assert {:ok, %{"status" => "completed", "response_payload" => %{"status" => "connected"}}} =
             SalixAgent.CapabilityRequests.get(
               view.group_id,
               request["request_id"],
               view.tenant_id
             )

    assert {:ok, %{}} = StationTasks.login_restore(view, params(%{"program" => "gh"}))

    assert {:ok, %{"kept" => true}} =
             StationTasks.login_keep(view, params(%{"program" => "gh", "archive" => "dGFy"}))

    assert {:ok, %{"archive" => "dGFy"}} =
             StationTasks.login_restore(view, params(%{"program" => "gh"}))

    # Another person's sandbox has nothing of it.
    assert :none =
             SalixWeb.OAuthFlow.kept_login(
               view.tenant_id,
               view.group_id,
               "comma_user|usr_other",
               "gh"
             )
  end

  defp eventually_pending_request(view) do
    settle()

    {:ok, [request]} =
      SalixAgent.CapabilityRequests.list_conversation(view.group_id, view.tenant_id, "cnv_tools")

    request
  end

  test "under enforce, the call acts for the Task's owner under the Task's label: a write and its read go through",
       %{view: view} do
    previous = SystemsRuntime.get_env(:salix_agent, :ifc_facts_mod)
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)

    {:ok, _} =
      Salix.Control.Groups.update(
        view.group_id,
        %{"ifc" => %{"mode" => "enforce"}},
        view.tenant_id
      )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod)
    end)

    assert {:ok, %{"error" => false} = written} =
             StationTasks.tool_call(
               view,
               params(%{
                 "tool" => "fs.write_file",
                 "args" => %{"path" => "/enforced.md", "content" => "kept under the Task's label"}
               })
             )

    assert written["content"] =~ "wrote", "the write did not go through: " <> written["content"]

    assert {:ok, %{"error" => false, "content" => read}} =
             StationTasks.tool_call(
               view,
               params(%{"tool" => "fs.read_file", "args" => %{"path" => "/enforced.md"}})
             )

    assert read =~ "kept under the Task's label"

    # The kernel decided for the Task's owner, delegated through this station,
    # with the Task's own label as the activation's scope.
    # (The write's own decision; the read-back's reader check asks as the owner.)
    delegated = fn request ->
      match?({:ok, {:schedule, _, _}}, SalixIFC.Codec.decode_principal(request["requester"]))
    end

    assert request = Enum.find(Process.get(:ifc_test_requests, []), delegated)

    assert {:ok, {:schedule, "station:dev-sbx-cnv_tools", {:comma_user, "usr_owner"}}} =
             SalixIFC.Codec.decode_principal(request["requester"])

    assert %{"provider" => "schedule", "schedule_id" => "station:dev-sbx-cnv_tools"} =
             request["trusted_origin"]

    # A manual is a record of this round, labelled as the Task's: the owner reads it.
    assert {:ok, %{"error" => false, "content" => manual}} =
             StationTasks.tool_call(
               view,
               params(%{"tool" => "help", "args" => %{"tool" => "fs.read_file"}})
             )

    assert manual =~ "fs.read_file"

    # The same file, once the Task's readers are someone else: not for this requester.
    Process.put(:ifc_test_task_members, ["comma_user|usr_other"])

    assert {:ok, %{"error" => "label_not_this_task"}} =
             StationTasks.tool_call(
               view,
               params(%{"tool" => "fs.read_file", "args" => %{"path" => "/enforced.md"}})
             )
  end

  test "under enforce, a Task asked for in a provider chat acts for that person, and a Task with no one is refused",
       %{view: view} do
    previous = SystemsRuntime.get_env(:salix_agent, :ifc_facts_mod)
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)

    {:ok, _} =
      Salix.Control.Groups.update(
        view.group_id,
        %{"ifc" => %{"mode" => "enforce"}},
        view.tenant_id
      )

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod)
    end)

    # A Slack or Feishu person has no Comma account, so the Task has no owner;
    # its creation recorded who asked (`ifc_requester`).
    person = "provider_user|imc_lark|ou_asker"
    Process.put(:ifc_test_task_members, [person])

    SystemsRuntime.Agent.update(Task, fn state ->
      state
      |> Map.put(:owner, nil)
      |> put_in([:record, "source_refs"], %{"ifc_requester" => person})
    end)

    assert {:ok, %{"error" => false} = written} =
             StationTasks.tool_call(
               view,
               params(%{
                 "tool" => "fs.write_file",
                 "args" => %{"path" => "/asked.md", "content" => "for the person who asked"}
               })
             )

    assert written["content"] =~ "wrote", "the write did not go through: " <> written["content"]

    assert {:ok, %{"error" => false, "content" => read}} =
             StationTasks.tool_call(
               view,
               params(%{"tool" => "fs.read_file", "args" => %{"path" => "/asked.md"}})
             )

    assert read =~ "for the person who asked"

    assert Enum.any?(Process.get(:ifc_test_requests, []), fn request ->
             SalixIFC.Codec.decode_principal(request["requester"]) ==
               {:ok,
                {:schedule, "station:dev-sbx-cnv_tools", {:provider_user, "imc_lark", "ou_asker"}}}
           end)

    SystemsRuntime.Agent.update(Task, &put_in(&1, [:record, "source_refs"], %{}))

    assert {:ok, %{"error" => "no_requester"}} =
             StationTasks.tool_call(
               view,
               params(%{"tool" => "fs.read_file", "args" => %{"path" => "/asked.md"}})
             )
  end

  test "under audit, a result for someone else still goes back: the refusal is only recorded",
       %{view: view} do
    previous = SystemsRuntime.get_env(:salix_agent, :ifc_facts_mod)
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)

    {:ok, _} =
      Salix.Control.Groups.update(view.group_id, %{"ifc" => %{"mode" => "audit"}}, view.tenant_id)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :ifc_facts_mod)
    end)

    assert {:ok, %{"error" => false}} =
             StationTasks.tool_call(
               view,
               params(%{
                 "tool" => "fs.write_file",
                 "args" => %{"path" => "/audited.md", "content" => "someone else's"}
               })
             )

    Process.put(:ifc_test_task_members, ["comma_user|usr_other"])

    assert {:ok, %{"error" => false, "content" => read}} =
             StationTasks.tool_call(
               view,
               params(%{"tool" => "fs.read_file", "args" => %{"path" => "/audited.md"}})
             )

    assert read =~ "someone else's"
  end

  test "a malformed request is a bad request", %{view: view} do
    assert {:error, :bad_request} = StationTasks.tool_call(view, params(%{"tool" => ""}))

    assert {:error, :bad_request} =
             StationTasks.tool_call(view, params(%{"tool" => "help", "args" => "x"}))

    assert {:error, :bad_request} = StationTasks.tool_call(view, params(%{}))
  end

  test "another device or Session, or a replaced sandbox generation, has no authority", %{
    r: r,
    view: view
  } do
    call = params(%{"tool" => "fs.read_file", "args" => %{"path" => "/none"}})

    assert {:error, :not_taking_part} =
             StationTasks.tool_call(%{view | device_id: "laptop"}, call)

    assert {:error, :not_taking_part} =
             StationTasks.tools(view, params(%{"session" => "ember:x"}))

    {:ok, w} = Store.get_by_conversation(r.tenant_id, r.conversation_id)

    {:ok, _} =
      Store.update(w.id, fn current -> {:ok, Map.merge(current.spec, %{"state" => "stopped"})} end)

    {:ok, _next} = Store.advance(w.id)

    assert {:error, :station_connection_changed} = StationTasks.tool_call(view, call)
    assert {:error, :station_connection_changed} = StationTasks.tools(view, params(%{}))
  end
end
