defmodule CommaWeb.CollaborationMiniAppTest do
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias Comma.{MiniApps, Repo}
  alias Comma.MiniApps.App

  @admin_token "test-token"
  @branch_head "0123456789abcdef0123456789abcdef01234567"

  defmodule GitHub do
    @moduledoc false
    use Agent

    @branch_head "0123456789abcdef0123456789abcdef01234567"

    def start_link(_), do: Agent.start_link(fn -> %{token_groups: []} end, name: __MODULE__)

    def token_groups, do: Agent.get(__MODULE__, &Enum.reverse(&1.token_groups))

    def token(_tenant, group_id) do
      Agent.update(__MODULE__, &%{&1 | token_groups: [group_id | &1.token_groups]})
      {:ok, %{token: "ghu_collab", expires_at: nil}}
    end

    def user("ghu_collab"),
      do: {:ok, %{login: "hostdev", id: 42, email: "42+hostdev@users.noreply.github.com"}}

    def generate_from_template("ghu_collab", _template, owner, name),
      do: {:ok, %{owner: owner, name: name, default_branch: "main"}}

    def commit_on_branch("ghu_collab", _owner, _name, @branch_head, "comma/app"), do: :ok
    def commit_on_branch(_, _, _, _, _), do: {:error, :commit_not_on_branch}
  end

  defmodule Places do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(group_id, delegator, target, attrs),
      do:
        Salix.Bindings.AgentConversations.create_task_conversation(
          group_id,
          delegator,
          target,
          attrs
        )

    @impl true
    def runs_on(_scope, request), do: {:ok, request}

    @impl true
    def session_model(_scope, choice), do: {:ok, choice}

    @impl true
    def task_worker(scope), do: SalixAgent.TaskAgent.ensure(scope)
  end

  defmodule Stations do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskStations

    @impl true
    def invite(_invitation), do: {:ok, "ember:c-collab"}
    @impl true
    def joined(_row), do: :ok
    @impl true
    def moved(_move), do: :ok
    @impl true
    def sessions(_group_id, _conversation_id), do: {:ok, %{}}
    @impl true
    def sandbox(_reservation), do: :ok
    @impl true
    def task_status(_group_id, _conversation_id, _status), do: :ok
    @impl true
    def appended(_group_id, _conversation_id), do: :ok
    @impl true
    def standing(_group_id, _conversation_id), do: :not_station
    @impl true
    def session_status(_group_id, _conversation_id), do: :unknown
  end

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SalixAgent.TestSupport.stop_all_agents()
    start_supervised!(GitHub)

    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_agent, :im_provider_mod},
            {:salix_agent, :llm},
            {:comma_core, :salix_client},
            {:comma_web, :api_token},
            {:salix_web, :coding_github},
            {:comma_core, :mini_app_rate_limit},
            {:comma_core, :mini_apps_cloudflare_http_options},
            {:comma_web, :mini_app_dispatch_http_options},
            {:salix_im, :task_create_mod},
            {:salix_im, :task_stations_mod}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    start_supervised!(SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)
    SystemsRuntime.put_env(:salix_web, :coding_github, GitHub)

    SystemsRuntime.put_env(:comma_core, :mini_app_rate_limit,
      peer: [burst: 100_000, rate: 10_000.0],
      app: [burst: 100_000, rate: 10_000.0]
    )

    SystemsRuntime.put_env(:comma_core, :mini_apps_cloudflare_http_options,
      plug: fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"success":true,"result":{}}))
      end
    )

    SystemsRuntime.put_env(:comma_web, :mini_app_dispatch_http_options,
      plug: fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"ok" => true}))
      end
    )

    SystemsRuntime.put_env(:salix_im, :task_create_mod, Places)
    SystemsRuntime.put_env(:salix_im, :task_stations_mod, Stations)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    :ok
  end

  test "collaboration Mini App isolation, host+member runtime/bundle access, zero Drive, and instant 404 on removal/leave",
       %{tmp_dir: tmp_dir} do
    host = person("host-ma", workspace: true)
    member = person("member-ma")
    leaver = person("leaver-ma")
    stranger = person("stranger-ma")
    linked!(host, member)
    linked!(host, leaver)
    grant_credits!(host.workspace)
    home_group_id = host.workspace["default_group_id"]

    %{"task" => %{"id" => task_id, "group_id" => group_id}} =
      req(host, :post, "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations",
        json: %{
          "people" => [member.user["id"], leaver.user["id"]],
          "content" => "Build a shared trip planner Mini App",
          "client_request_id" => "collab-ma-1"
        }
      )
      |> expect_status(201)

    # Both members accept their invites.
    member_collab_id = accept_invite!(member, task_id)
    leaver_collab_id = accept_invite!(leaver, task_id)

    # Opening message from host carries task_command: true.
    {:ok, messages} = SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)
    host_msg = Enum.find(messages, &(&1["user_id"] == host.user["id"]))
    assert get_in(host_msg, ["metadata", "task_command"]) == true

    {:ok, task} = SalixIM.Conversations.get_group_conversation_record(group_id, task_id)
    worker_id = task["task_worker_agent_id"]

    host_ctx = %{
      "group_id" => group_id,
      "task_conversation_id" => task_id,
      "trusted_origin" => %{
        "provider" => "internal",
        "conversation_kind" => "agent_task",
        "conversation_id" => task_id,
        "message_id" => host_msg["message_id"]
      }
    }

    # Host-commanded collaboration_worker creates a collaboration Mini App.
    {:ok, created} =
      SalixIM.Provider.call_api(worker_id, "internal", "internal.apps.create", %{
        "connect_id" => "internal",
        "params" => %{
          "name" => "Trip Planner",
          "description" => "Shared itinerary"
        },
        "tool_context" => host_ctx
      })

    app_id = created["app_id"]
    assert created["url"] =~ "/#/collaborations/#{group_id}/#{task_id}/apps/#{app_id}"

    # GitHub credentials were resolved from the host's home group, not the isolated group.
    assert home_group_id in GitHub.token_groups()
    refute group_id in GitHub.token_groups()

    # App row is bound to the isolated collaboration group + conversation, visibility collaboration, empty grants.
    app = Repo.get!(App, app_id)
    assert app.visibility == "collaboration"
    assert app.group_id == group_id
    assert app.collaboration_conversation_id == task_id
    assert app.grants == []

    # Excluded from host workspace list, router_apps, router_app, and workspace show.
    %{"data" => ws_apps} =
      req(host, :get, "/v1/comma/workspaces/#{host.workspace["id"]}/apps") |> expect_status(200)

    refute Enum.any?(ws_apps, &(&1["id"] == app_id))

    ws_struct = Repo.get!(Comma.Data.Workspace, host.workspace["id"])
    {router_apps, _ctx} = MiniApps.router_apps(ws_struct, 50)
    refute Enum.any?(router_apps, &(&1.id == app_id))
    assert {:error, :not_found} = MiniApps.router_app(ws_struct, app_id)

    req(host, :get, "/v1/comma/workspaces/#{host.workspace["id"]}/apps/#{app_id}")
    |> expect_status(404)

    # Cannot share via public link, change visibility, or grant Drive.
    req(host, :put, "/v1/comma/workspaces/#{host.workspace["id"]}/apps/#{app_id}/link")
    |> expect_status(404)

    req(host, :patch, "/v1/comma/workspaces/#{host.workspace["id"]}/apps/#{app_id}",
      json: %{"visibility" => "link"}
    )
    |> expect_status(404)

    req(host, :put, "/v1/comma/workspaces/#{host.workspace["id"]}/apps/#{app_id}/grants",
      json: %{"grants" => ["drive.app_folder"]}
    )
    |> expect_status(404)

    assert {:error, :forbidden} = MiniApps.visibility_allowed(app, "link")

    # Deploy a ready version (with backend + drive.app_folder declared in manifest to prove Drive is still blocked).
    bundle_path = Path.join(tmp_dir, "bundle.tar")
    source_path = Path.join(tmp_dir, "source.tar.gz")
    worker_path = Path.join(tmp_dir, "worker.js")
    write_tar!(bundle_path, [{"index.html", "<h1>Trip</h1>"}])
    write_tar_gz!(source_path, [{"index.html", "<h1>Trip</h1>"}])
    File.write!(worker_path, "export default { async fetch() { return new Response('ok'); } };")

    manifest_json =
      Jason.encode!(%{
        "name" => "Trip Planner",
        "capabilities" => ["drive.app_folder"],
        "backend" => %{"entry" => "worker.js"}
      })

    {:ok, deployed} =
      CommaWeb.MiniAppPort.deploy(
        %{
          app_id: app_id,
          group_id: group_id,
          key: "deploy-collab-1",
          commit: @branch_head,
          branch: "comma/app",
          conversation_id: task_id,
          repo: %{"owner" => app.repo_owner, "name" => app.repo_name}
        },
        %{
          manifest: manifest_json,
          bundle: %{path: bundle_path},
          source: %{path: source_path},
          worker: %{path: worker_path}
        }
      )

    assert deployed["version"] == 1
    assert deployed["state"] == "ready"
    assert Repo.get!(App, app_id).visibility == "collaboration"

    via_header = {"x-comma-app-via", "collaboration/#{group_id}/#{task_id}"}

    bundle_url =
      "/v1/comma/collaborations/#{group_id}/#{task_id}/apps/#{app_id}/versions/1/bundle"

    # Host, active member, and active leaver can open, call backend, and fetch bundle.
    for actor <- [host, member, leaver] do
      opened =
        req(actor, :post, "/v1/comma/apps/#{app_id}/open", headers: [via_header])
        |> expect_status(200)

      assert opened["app"]["id"] == app_id
      assert opened["version"] == 1

      backend =
        req(actor, :post, "/v1/comma/apps/#{app_id}/backend/hello",
          headers: [via_header, {"x-comma-app-method", "GET"}]
        )
        |> expect_status(200)

      assert backend["ok"] == true

      bundle_resp =
        req(actor, :get, bundle_url)

      assert bundle_resp.status == 200

      # Zero host Drive access for both host and members!
      req(actor, :get, "/v1/comma/apps/#{app_id}/drive", headers: [via_header])
      |> expect_status(403)
    end

    # Stranger (non-member) gets 404 on open and bundle.
    req(stranger, :post, "/v1/comma/apps/#{app_id}/open", headers: [via_header])
    |> expect_status(404)

    req(stranger, :get, bundle_url) |> expect_status(404)

    # Anonymous guest-mode user is rejected at MiniApps.runtime and MiniApps.collaboration_bundle.
    guest_user = %{
      "id" => "usr_guest_1",
      "kind" => "guest",
      "email" => "g-123@guest.comma.invalid"
    }

    assert {:error, :signup_required} =
             MiniApps.runtime(guest_user, %{}, app_id, elem(via_header, 1))

    assert {:error, :signup_required} =
             MiniApps.collaboration_bundle(guest_user, %{}, group_id, task_id, app_id, "1")

    # Also verify GuestRoutes blocks collaboration runtime & bundle paths for guest users.
    refute CommaWeb.GuestRoutes.allowed?("GET", bundle_url)

    refute CommaWeb.GuestRoutes.link_app_call?(
             "POST",
             "/v1/comma/apps/#{app_id}/open",
             elem(via_header, 1)
           )

    # Host removes `member` -> INSTANT 404 on open, backend, and bundle.
    req(
      host,
      :delete,
      "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations/#{task_id}/members/#{member.user["id"]}"
    )
    |> expect_status(200)

    req(member, :post, "/v1/comma/apps/#{app_id}/open", headers: [via_header])
    |> expect_status(404)

    req(member, :post, "/v1/comma/apps/#{app_id}/backend/hello",
      headers: [via_header, {"x-comma-app-method", "GET"}]
    )
    |> expect_status(404)

    req(member, :get, bundle_url) |> expect_status(404)

    # `leaver` leaves -> INSTANT 404 on open, backend, and bundle.
    req(leaver, :post, "/v1/comma/collaborations/#{leaver_collab_id}/leave") |> expect_status(200)

    req(leaver, :post, "/v1/comma/apps/#{app_id}/open", headers: [via_header])
    |> expect_status(404)

    req(leaver, :get, bundle_url) |> expect_status(404)

    # Host still retains access after members are removed/left.
    req(host, :post, "/v1/comma/apps/#{app_id}/open", headers: [via_header])
    |> expect_status(200)

    req(host, :get, bundle_url) |> expect_status(200)
    assert is_binary(member_collab_id)
  end

  test "member/guest repo-less sandboxes with bidirectional /task/ files succeed while repo/Mini App stay host-only" do
    host = person("host-p5", workspace: true)
    member = person("member-p5")
    linked!(host, member)
    grant_credits!(host.workspace)
    home_group_id = host.workspace["default_group_id"]

    %{"task" => %{"id" => task_id, "group_id" => group_id}} =
      req(host, :post, "/v1/comma/workspaces/#{host.workspace["id"]}/collaborations",
        json: %{
          "people" => [member.user["id"]],
          "content" => "Implement the feature branch",
          "client_request_id" => "collab-p5-1"
        }
      )
      |> expect_status(201)

    _collab_id = accept_invite!(member, task_id)

    # Isolated collaboration group resolves GitHub OAuth credentials and sandbox admission from the host's home group.
    assert SalixWeb.CodingSandboxes.github_group_id(group_id) == home_group_id
    assert CommaWeb.Coding.SandboxAdmission.admitted?(host.workspace["salix_tenant_id"], group_id)

    # Member uploads an input file into the Shared Task's /task/ folder.
    %{"path" => uploaded_path} =
      req(member, :post, "/v1/comma/collaborations/#{group_id}/#{task_id}/files?name=news.csv",
        headers: [{"content-type", "application/octet-stream"}],
        body: "date,title\n2026-11-24,Anthropic news\n"
      )
      |> expect_status(201)

    # Member posts a message mentioning @Comma (not a host command -> no task_command: true).
    req(member, :post, "/v1/comma/collaborations/#{group_id}/#{task_id}/messages",
      json: %{"content" => "@Comma make a PDF from news.csv"}
    )
    |> expect_status(202)

    {:ok, messages} = SalixIM.Conversations.list_group_conversation_messages(group_id, task_id)
    host_msg = Enum.find(messages, &(&1["user_id"] == host.user["id"]))
    member_msg = Enum.find(messages, &(&1["user_id"] == member.user["id"]))
    assert get_in(host_msg, ["metadata", "task_command"]) == true
    refute get_in(member_msg, ["metadata", "task_command"]) == true

    {:ok, task} = SalixIM.Conversations.get_group_conversation_record(group_id, task_id)
    worker_id = task["task_worker_agent_id"]

    {:ok, %{"participants" => task_participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group_id, task_id)

    worker_participant =
      Enum.find(task_participants, &(&1["actor_type"] == "agent" and &1["agent_id"] == worker_id))

    worker_participant_id = worker_participant["participant_id"]

    host_origin = %{
      "provider" => "internal",
      "agent_group_id" => group_id,
      "conversation_kind" => "agent_task",
      "conversation_id" => task_id,
      "message_id" => host_msg["message_id"],
      "participant_id" => worker_participant_id
    }

    member_origin = %{
      "provider" => "internal",
      "agent_group_id" => group_id,
      "conversation_kind" => "agent_task",
      "conversation_id" => task_id,
      "message_id" => member_msg["message_id"],
      "participant_id" => worker_participant_id
    }

    {:ok, host_source_id} =
      SalixIM.ConversationSourceIdentity.encode(
        task_id,
        host_msg["message_id"],
        worker_participant_id
      )

    {:ok, member_source_id} =
      SalixIM.ConversationSourceIdentity.encode(
        task_id,
        member_msg["message_id"],
        worker_participant_id
      )

    member_ctx = %{
      "group_id" => group_id,
      "task_conversation_id" => task_id,
      "source_message_id" => member_source_id,
      "trusted_origin" => member_origin
    }

    mixed_ctx = %{
      "group_id" => group_id,
      "task_conversation_id" => task_id,
      "source_message_id" => host_source_id,
      "trusted_origin" => host_origin,
      "trusted_origins" => [host_origin, member_origin]
    }

    host_ctx = %{
      "group_id" => group_id,
      "task_conversation_id" => task_id,
      "source_message_id" => host_source_id,
      "trusted_origin" => host_origin
    }

    # Member round AND mixed host+member batch are REFUSED cleanly for repo coding, mini_app builds, and apps.create.
    for ctx <- [member_ctx, mixed_ctx] do
      assert {:error, msg} =
               SalixIM.Provider.call_api(worker_id, "internal", "internal.apps.create", %{
                 "connect_id" => "internal",
                 "params" => %{"name" => "Unauthorized App"},
                 "tool_context" => ctx
               })

      assert msg =~ "Only the host of this Collaborative Task"

      assert {:error, msg} =
               SalixIM.Provider.call_api(worker_id, "internal", "internal.task.create", %{
                 "connect_id" => "internal",
                 "params" => %{
                   "content" => "Edit repo and open PR",
                   "runs_on" => %{"kind" => "sandbox"},
                   "repo" => %{"owner" => "acme", "name" => "web"}
                 },
                 "tool_context" => ctx
               })

      assert msg =~ "Only the host of this Collaborative Task"

      assert {:error, msg} =
               SalixIM.Provider.call_api(worker_id, "internal", "internal.task.create", %{
                 "connect_id" => "internal",
                 "params" => %{
                   "content" => "Build mini app",
                   "runs_on" => %{"kind" => "sandbox"},
                   "mini_app" => %{"app_id" => "app_123"}
                 },
                 "tool_context" => ctx
               })

      assert msg =~ "Only the host of this Collaborative Task"
    end

    # Even on a host command, non-sandbox runs_on (station, cloud_vm, default) and non-/task/ files are REFUSED.
    for bad_place <- [
          %{"kind" => "default"},
          %{"kind" => "cloud_vm"},
          %{"kind" => "station", "device_id" => "dev-1"}
        ] do
      assert {:error, msg} =
               SalixIM.Provider.call_api(worker_id, "internal", "internal.task.create", %{
                 "connect_id" => "internal",
                 "params" => %{
                   "content" => "Run on non-sandbox",
                   "runs_on" => bad_place
                 },
                 "tool_context" => host_ctx
               })

      assert msg =~ "sandbox"
    end

    assert {:error, msg} =
             SalixIM.Provider.call_api(worker_id, "internal", "internal.task.create", %{
               "connect_id" => "internal",
               "params" => %{
                 "content" => "Read outside /task/",
                 "runs_on" => %{"kind" => "sandbox"},
                 "files" => ["/drive/private.txt"]
               },
               "tool_context" => member_ctx
             })

    assert msg =~ "/task/"

    # Member command with repo-less sandbox AND /task/ input file SUCCEEDS with zero GitHub calls!
    assert {:ok, member_subtask} =
             SalixIM.Provider.call_api(worker_id, "internal", "internal.task.create", %{
               "connect_id" => "internal",
               "params" => %{
                 "title" => "Generate Anthropic news PDF",
                 "content" => "Turn news.csv into anthropic-news.pdf",
                 "runs_on" => %{"kind" => "sandbox"},
                 "files" => [uploaded_path]
               },
               "tool_context" => member_ctx
             })

    subtask_id = member_subtask["conversation_id"]
    assert is_binary(subtask_id)
    assert subtask_id != task_id
    assert GitHub.token_groups() == []

    # Verify the sandbox sub-task's initial message carries the bound /task/ file block so the sandbox downloads it.
    {:ok, subtask_messages} =
      SalixIM.Conversations.list_group_conversation_messages(group_id, subtask_id)

    [initial_msg | _] = subtask_messages
    assert is_list(initial_msg["content"])

    assert Enum.any?(initial_msg["content"], fn block ->
             block["type"] == "file" and block["path"] == uploaded_path and
               is_map(block["blob_ref"])
           end)

    # Simulate sandbox sub-task returning a generated PDF materialized into worker's /.conversation-attachments/.
    pdf_bytes = "%PDF-1.4\n1 0 obj <<>> endobj\ntrailer <<>>\n%%EOF\n"
    {:ok, subtask_rec} = SalixIM.Conversations.get_group_conversation_record(group_id, subtask_id)
    subtask_agent_id = subtask_rec["task_worker_agent_id"]

    # Sub-task's TaskAgent is isolated under immutable sandbox_purpose, has no host user_context,
    # exposes only minimal public web tools to StationToolCalls, and still resolves host billing_owner.
    {:ok, subtask_agent} = SalixAgent.Control.get_record(subtask_agent_id)
    assert subtask_agent["purpose"] == SalixAgent.CollaborationPolicy.sandbox_purpose()

    tenant_id = host.workspace["salix_tenant_id"]
    assert {:error, :not_found} = Salix.Control.Groups.get(group_id, tenant_id)

    assert {:ok, runtime_group} = Salix.Control.Groups.get_for_runtime(group_id, tenant_id)

    assert get_in(runtime_group, ["billing_owner", "billing_account_id"]) ==
             host.workspace["billing_account_id"]

    assert {:ok, user_ctx} =
             CommaWeb.AgentManagement.user_context(%{tenant_id: tenant_id, group_id: group_id})

    assert user_ctx == SalixAgent.AgentManagement.Ports.no_user_context()

    station_tools =
      SalixAgent.StationToolCalls.tools(%{
        tenant_id: tenant_id,
        group_id: group_id,
        agent_id: subtask_agent_id,
        conversation_id: subtask_id,
        device_id: SalixStore.CodingSandboxes.device_id(subtask_id),
        session: "sess_test"
      })
      |> Enum.map(& &1["name"])

    assert station_tools != []

    assert Enum.all?(
             station_tools,
             &SalixAgent.CollaborationPolicy.allowed_tool?(
               %{collaboration_policy: :sandbox_restricted},
               &1
             )
           )

    refute "fs.read_file" in station_tools
    refute "im_api.internal.send_message" in station_tools
    refute "memory.search" in station_tools

    {:ok, _} =
      SalixAgent.Workspace.write(subtask_agent_id, "/uploads/tasks/anthropic-news.pdf", pdf_bytes,
        create: true
      )

    {:ok, pdf_ref} =
      SalixIM.Ports.AgentWorkspace.file_ref(subtask_agent_id, "/uploads/tasks/anthropic-news.pdf")

    {:ok, materialized_blocks} =
      SalixIM.ConversationAttachments.materialize_delivery(worker_id, %{
        "source_actor_type" => "agent",
        "source_agent_id" => subtask_agent_id,
        "message_id" => "msg_sandbox_pdf_1",
        "message_content" => [
          %{
            "type" => "file",
            "path" => "/uploads/tasks/anthropic-news.pdf",
            "file_name" => "anthropic-news.pdf",
            "blob_ref" => pdf_ref
          }
        ]
      })

    [%{"path" => materialized_path}] = materialized_blocks
    assert String.starts_with?(materialized_path, "/.conversation-attachments/")

    # Worker sends the PDF back to the Shared Task -> auto-promoted into /task/anthropic-news.pdf!
    assert {:ok, _sent} =
             SalixIM.Provider.call_api(worker_id, "internal", "internal.send_message", %{
               "connect_id" => "internal",
               "params" => %{
                 "conversation_id" => task_id,
                 "content" => [
                   %{"type" => "text", "text" => "PDF is ready."},
                   %{
                     "type" => "file",
                     "path" => materialized_path,
                     "file_name" => "anthropic-news.pdf"
                   }
                 ]
               },
               "tool_context" => member_ctx
             })

    # Both host and active member see anthropic-news.pdf in Files and can download the exact PDF bytes.
    %{"files" => member_files} =
      req(member, :get, "/v1/comma/collaborations/#{group_id}/#{task_id}/files")
      |> expect_status(200)

    pdf_entry = Enum.find(member_files, &(&1["name"] == "anthropic-news.pdf"))
    assert pdf_entry
    assert pdf_entry["path"] == "/task/anthropic-news.pdf"

    downloaded =
      req(
        member,
        :get,
        "/v1/comma/collaborations/#{group_id}/#{task_id}/files?path=#{URI.encode_www_form(pdf_entry["path"])}",
        decode_body: false
      )

    assert downloaded.status == 200
    assert downloaded.body == pdf_bytes

    # Host command with repo coding sandbox still SUCCEEDS.
    assert {:ok, created_task} =
             SalixIM.Provider.call_api(worker_id, "internal", "internal.task.create", %{
               "connect_id" => "internal",
               "params" => %{
                 "title" => "Build feature",
                 "content" => "Implement the feature in the sandbox",
                 "runs_on" => %{"kind" => "sandbox"},
                 "repo" => %{"owner" => "acme", "name" => "web"}
               },
               "tool_context" => host_ctx
             })

    assert is_binary(created_task["conversation_id"])
    assert created_task["conversation_id"] != task_id
  end

  defp accept_invite!(member, task_id) do
    %{"data" => list} = req(member, :get, "/v1/comma/collaborations") |> expect_status(200)
    invite = Enum.find(list, &(&1["task"]["id"] == task_id))
    assert invite
    req(member, :post, "/v1/comma/collaborations/#{invite["id"]}/accept") |> expect_status(200)
    invite["id"]
  end

  defp write_tar!(path, entries) do
    files = Enum.map(entries, fn {name, data} -> {String.to_charlist(name), data} end)
    :ok = :erl_tar.create(String.to_charlist(path), files)
  end

  defp write_tar_gz!(path, entries) do
    files = Enum.map(entries, fn {name, data} -> {String.to_charlist(name), data} end)
    :ok = :erl_tar.create(String.to_charlist(path), files, [:compressed])
  end

  defp grant_credits!(workspace) do
    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: workspace["billing_account_id"],
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace["id"]
      })

    assert {:ok, _grant} =
             BillingCore.Credits.issue_grant(%{
               repo: BillingCore.Repo,
               billing_account_id: workspace["billing_account_id"],
               credits: 100,
               valid_from: DateTime.add(SystemsClock.utc_now(), -60, :second),
               expires_at: DateTime.add(SystemsClock.utc_now(), 1, :day),
               source_type: "manual_contract",
               source_id: "collaboration-mini-app-test",
               source_event_id: workspace["id"],
               idempotency_key: workspace["id"]
             })
  end

  defp linked!(host, member) do
    grants = "/v1/comma/workspaces/#{host.workspace["id"]}/task-request-grants"
    %{"invite_url" => url} = req(host, :post, grants, json: %{}) |> expect_status(201)
    [_, token] = String.split(url, "invite=")
    req(member, :post, "/v1/comma/task-request-invites/#{token}/accept") |> expect_status(200)
  end

  defp person(name, opts \\ []) do
    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "#{name}-collab-ma@example.com", "name" => name}
      )
      |> expect_status(201)

    workspace =
      if opts[:workspace] do
        workspace = create_ready_workspace!(user["id"], %{"name" => "Host"})
        :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
        CommaWeb.TestWorkers.with_default_worker!(workspace)
      end

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)

    %{user: user, workspace: workspace, token: session["token"]}
  end

  defp admin_req(method, path, opts),
    do: http([{"authorization", "Bearer " <> @admin_token}], method, path, opts)

  defp req(person, method, path, opts \\ []) do
    extra_headers = Keyword.get(opts, :headers, [])
    opts = Keyword.delete(opts, :headers)
    http([{"authorization", "Bearer " <> person.token} | extra_headers], method, path, opts)
  end

  defp http(headers, method, path, opts) do
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
    resp.body
  end
end
