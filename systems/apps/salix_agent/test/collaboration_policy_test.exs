defmodule SalixAgent.CollaborationPolicyTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{CollaborationPolicy, ToolDisclosure}

  setup do
    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if previous_store,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_store),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)

    :ok
  end

  test "a Collaborative Task's Worker sees and calls nothing of the host's Group" do
    worker = %{collaboration_policy: :restricted}

    assert CollaborationPolicy.allowed_tool?(worker, "web.search")
    # Its reply: `im_api.internal.send_message` writes only where the Agent is a participant.
    assert CollaborationPolicy.allowed_tool?(worker, "im_api.internal.send_message")

    for denied <-
          ~w(memory.search memory.write fs.grep history.search drive.list browser.open
             mcp.list composio.connect env.exec agent.create_worker
             im_api.internal.read_conversation im_api.internal.task.request_review
             task_request.send condensed_workspace.update
             loop.subscribe loop.webhook loop.send) do
      refute CollaborationPolicy.allowed_tool?(worker, denied), denied
    end

    assert CollaborationPolicy.allowed_tool?(%{}, "memory.search")
    refute CollaborationPolicy.allowed_tool?(%{collaboration_policy: :bogus}, "web.search")

    names =
      ToolDisclosure.materialize_static("worker", :internal, worker)
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    assert "web.search" in names
    assert Enum.all?(names, &CollaborationPolicy.allowed_tool?(worker, &1))
  end

  defmodule HostCommand do
    def host_command?(ctx), do: ctx[:host?] == true
  end

  test "only its host's own words start, change or stop a Task together's Loop" do
    previous = SystemsRuntime.get_env(:salix_agent, :collaboration_command_mod)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :collaboration_command_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :collaboration_command_mod)
    end)

    worker = %{collaboration_policy: :restricted}
    assert CollaborationPolicy.allowed_tool?(worker, "loop.create")

    # Without an authority to ask, no Loop changes.
    SystemsRuntime.delete_env(:salix_agent, :collaboration_command_mod)

    assert_raise RuntimeError, ~r/Only the host/, fn ->
      CollaborationPolicy.host_command!(worker)
    end

    SystemsRuntime.put_env(:salix_agent, :collaboration_command_mod, HostCommand)

    assert_raise RuntimeError, ~r/Only the host/, fn ->
      CollaborationPolicy.host_command!(worker)
    end

    assert :ok = CollaborationPolicy.host_command!(Map.put(worker, :host?, true))

    # Any other Agent's round is not asked.
    assert :ok = CollaborationPolicy.host_command!(%{})
  end

  test "repo-less sandboxes are allowed for all participants while coding/PR and Mini App creation stay host-only" do
    previous = SystemsRuntime.get_env(:salix_agent, :collaboration_command_mod)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :collaboration_command_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :collaboration_command_mod)
    end)

    SystemsRuntime.put_env(:salix_agent, :collaboration_command_mod, HostCommand)

    member_round = %{collaboration_policy: :restricted, host?: false}
    host_round = %{collaboration_policy: :restricted, host?: true}

    # ToolDisclosure keeps im_api.internal.task.create for collaboration_worker even when cloud_vm_retired is false,
    # whereas an ordinary worker still omits it when cloud_vm_retired is false.
    im_entries = [
      %{
        "name" => "im_api.internal.task.create",
        "summary" => "Create one distinct durable Task.",
        "callable" => true,
        "helpable" => true,
        "manual_available" => true
      }
    ]

    disclosed =
      ToolDisclosure.materialize_prepared(
        "worker",
        :internal,
        %{collaboration_policy: :restricted, cloud_vm_retired: false},
        im_entries,
        []
      )

    disclosed_names = Enum.map(disclosed["tools"], & &1["name"])
    assert "im_api.internal.task.create" in disclosed_names

    ordinary_names =
      ToolDisclosure.materialize_prepared(
        "worker",
        :internal,
        %{collaboration_policy: :ordinary, cloud_vm_retired: false},
        im_entries,
        []
      )
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    refute "im_api.internal.task.create" in ordinary_names

    # Collaboration worker prompt directs sandbox sub-task delegation and never references a Router.
    collab_prompt =
      SalixAgent.ToolPolicy.session_prompt(
        "worker",
        %{},
        "agt_collab_prompt",
        :internal,
        Map.put(disclosed, "collaboration_policy", "restricted"),
        %{collaboration_policy: :restricted}
      )

    assert collab_prompt =~ "runs_on"
    assert collab_prompt =~ "/task/"
    assert collab_prompt =~ "stays active"
    refute collab_prompt =~ "request_review"
    refute collab_prompt =~ "goes to the Router"

    # Repo-less, non-Mini-App sandbox sub-task is allowed for both host and member/guest rounds.
    sandbox_args = %{
      "runs_on" => %{"kind" => "sandbox"},
      "content" => "Generate a PDF summary",
      "files" => ["/task/notes.md"]
    }

    assert :ok =
             CollaborationPolicy.authorize_call(
               member_round,
               "im_api.internal.task.create",
               sandbox_args
             )

    assert :ok =
             CollaborationPolicy.authorize_call(
               host_round,
               "im_api.internal.task.create",
               sandbox_args
             )

    # Non-/task/ files on task.create are blocked fail-closed.
    assert {:error, :blocked} =
             CollaborationPolicy.authorize_call(host_round, "im_api.internal.task.create", %{
               "runs_on" => %{"kind" => "sandbox"},
               "content" => "Exfiltrate",
               "files" => ["/drive/secret.txt"]
             })

    # Coding with repo, Mini App build with mini_app, and apps.create stay host-only.
    host_only_calls = [
      {"im_api.internal.task.create",
       %{"runs_on" => %{"kind" => "sandbox"}, "repo" => %{"owner" => "a", "name" => "b"}}},
      {"im_api.internal.task.create",
       %{"runs_on" => %{"kind" => "sandbox"}, "mini_app" => %{"app_id" => "app_1"}}},
      {"im_api.internal.apps.create", %{"name" => "Planner"}}
    ]

    for {tool, args} <- host_only_calls do
      assert CollaborationPolicy.allowed_tool?(member_round, tool)
      assert :ok = CollaborationPolicy.authorize_call(host_round, tool, args)
      assert {:error, msg} = CollaborationPolicy.authorize_call(member_round, tool, args)
      assert msg =~ "Only the host of this Collaborative Task"
    end

    # Discussion and web search remain allowed for member rounds.
    assert :ok =
             CollaborationPolicy.authorize_call(
               member_round,
               "im_api.internal.send_message",
               %{}
             )

    assert :ok = CollaborationPolicy.authorize_call(member_round, "web.search", %{})

    # host_command!/2 raises with action-specific polite message on non-host rounds.
    assert_raise RuntimeError,
                 ~r/Only the host of this Collaborative Task can create Mini Apps/,
                 fn ->
                   CollaborationPolicy.host_command!(member_round, "create Mini Apps")
                 end

    assert :ok = CollaborationPolicy.host_command!(host_round, "create Mini Apps")
  end

  test "a Task together's Worker keeps writes in /task/ and reads/copies sub-task attachments into /task/" do
    worker = %{collaboration_policy: :restricted}
    allowed = &CollaborationPolicy.allowed_call?(worker, &1, &2)

    assert allowed.("fs.write_file", %{"path" => "/task/plan.md", "content" => "x"})
    assert allowed.("fs.read_file", %{"path" => "/task/uploads/brief.pdf"})
    assert allowed.("fs.read_file", %{"path" => "/.conversation-attachments/msg_1/0-report.pdf"})
    assert allowed.("fs.stat_file", %{"path" => "/.conversation-attachments/msg_1/0-report.pdf"})
    assert allowed.("fs.list_files", %{"prefix" => "/task/"})
    assert allowed.("fs.copy_file", %{"from" => "/task/a.md", "to" => "/task/b.md"})

    assert allowed.("fs.copy_file", %{
             "from" => "/.conversation-attachments/msg_1/0-report.pdf",
             "to" => "/task/report.pdf"
           })

    # send_message allows /task/ and /.conversation-attachments/, blocks /drive/ and /.runtime/.
    assert allowed.("im_api.internal.send_message", %{
             "content" => [
               %{"type" => "file", "path" => "/task/report.pdf"},
               %{"type" => "file", "path" => "/.conversation-attachments/msg_1/0-report.pdf"}
             ]
           })

    refute allowed.("im_api.internal.send_message", %{
             "content" => [%{"type" => "file", "path" => "/drive/secret.pdf"}]
           })

    # /.conversation-attachments/ is strictly read-only: no writes, deletes, moves, or copy destinations.
    refute allowed.("fs.write_file", %{
             "path" => "/.conversation-attachments/msg_1/x.txt",
             "content" => "x"
           })

    refute allowed.("fs.delete_file", %{"path" => "/.conversation-attachments/msg_1/x.txt"})

    refute allowed.("fs.copy_file", %{
             "from" => "/task/a.md",
             "to" => "/.conversation-attachments/msg_1/a.md"
           })

    refute allowed.("fs.move_file", %{
             "from" => "/.conversation-attachments/msg_1/a.md",
             "to" => "/task/a.md"
           })

    # The host's Drive, the runtime projections, a climb out, a whole-tree list.
    refute allowed.("fs.read_file", %{"path" => "/drive/notes.md"})
    refute allowed.("fs.read_file", %{"path" => "/.runtime/skills/x/SKILL.md"})
    refute allowed.("fs.read_file", %{"path" => "/task/../drive/notes.md"})
    refute allowed.("fs.read_file", %{"path" => "/.conversation-attachments/../drive/notes.md"})
    refute allowed.("fs.read_file", %{"path" => "/notes.md"})
    refute allowed.("fs.list_files", %{})
    refute allowed.("fs.copy_file", %{"from" => "/task/a.md", "to" => "/drive/a.md"})
    refute allowed.("fs.copy_file", %{"from" => "/task/a.md"})
    refute allowed.("fs.read_file", %{"path" => "/task/a\\..\\b.md"})
    refute allowed.("fs.read_file", %{"path" => "/task/a.md" <> <<0>>})

    # Other tools, and any other Agent's file tools, are not asked.
    assert allowed.("web.search", %{"query" => "kyoto"})
    assert CollaborationPolicy.allowed_call?(%{}, "fs.read_file", %{"path" => "/drive/notes.md"})
  end

  test "a Collaborative Task's sandbox TaskAgent uses fail-closed sandbox_restricted policy" do
    assert CollaborationPolicy.collaboration_purpose?(CollaborationPolicy.sandbox_purpose())

    assert CollaborationPolicy.policy_for_purpose(CollaborationPolicy.sandbox_purpose()) ==
             :sandbox_restricted

    sandbox_ctx = %{collaboration_policy: :sandbox_restricted}
    assert CollaborationPolicy.restricted?(sandbox_ctx)

    assert CollaborationPolicy.allowed_tool?(sandbox_ctx, "web.search")
    assert CollaborationPolicy.allowed_tool?(sandbox_ctx, "web.read_pages")
    assert CollaborationPolicy.allowed_tool?(sandbox_ctx, "help")
    assert CollaborationPolicy.allowed_call?(sandbox_ctx, "web.search", %{"query" => "docs"})

    for denied <- ~w(
          fs.read_file
          fs.write_file
          fs.list_files
          im_api.internal.send_message
          im_api.internal.task.create
          im_api.internal.apps.create
          loop.create
          memory.search
          env.exec
          browser.open
          mcp.call
        ) do
      refute CollaborationPolicy.allowed_tool?(sandbox_ctx, denied), denied
      refute CollaborationPolicy.allowed_call?(sandbox_ctx, denied, %{}), denied
    end

    disclosed = ToolDisclosure.materialize_static("worker", :internal, sandbox_ctx)
    names = Enum.map(disclosed["tools"], & &1["name"])
    assert "web.search" in names
    assert Enum.all?(names, &CollaborationPolicy.allowed_tool?(sandbox_ctx, &1))

    # Tenant and group skills are excluded for sandbox_restricted agents too.
    scopes =
      SalixAgent.SkillStore.projection_scopes(%{
        collaboration_policy: :sandbox_restricted,
        tenant_id: "ten_1",
        group_id: "grp_1",
        agent_id: "agt_1"
      })

    refute Enum.any?(scopes, &(&1["layer"] in ["tenant", "group"]))
    assert Enum.any?(scopes, &(&1["layer"] == "global"))
    assert Enum.any?(scopes, &(&1["layer"] == "agent"))
  end
end
