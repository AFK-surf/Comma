defmodule CommaWeb.CommaSkillsTest do
  use Comma.DataCase, async: false

  @admin_token "test-token"
  @protocol_marker Comma.SkillMentions.protocol_marker()

  defmodule SalixClientFake do
    @behaviour Comma.Salix.Client

    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            messages: %{},
            reservations: %{},
            router_conversations: %{},
            skills_result: {:ok, %{"skills" => []}}
          }
        end,
        name: __MODULE__
      )
    end

    @impl true
    def provision_workspace_scope(_workspace), do: :ok

    @impl true
    def resolve_workspace_scope(workspace) do
      {:ok, Map.put(workspace, "router_conversation_id", router_conversation_id(workspace))}
    end

    @impl true
    def update_workspace_vm(_workspace, _vm), do: :ok

    @impl true
    def create_group_conversation(_workspace, attrs) do
      conversation_id = attrs["conversation_id"] || SalixStore.Ids.new_conversation_id()
      Agent.update(__MODULE__, &put_in(&1, [:messages, conversation_id], []))

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "kind" => "user_chat",
         "title" => "聊天",
         "status" => "active",
         "message_count" => 0
       }}
    end

    @impl true
    def ensure_group_router_conversation(workspace) do
      conversation_id = router_conversation_id(workspace)

      get_group_conversation(workspace, conversation_id)
    end

    @impl true
    def append_group_router_conversation_message(workspace, attrs) do
      with {:ok, %{"conversation_id" => conversation_id}} <-
             ensure_group_router_conversation(workspace) do
        append_group_conversation_message(workspace, conversation_id, attrs)
      end
    end

    @impl true
    def get_group_conversation(_workspace, conversation_id) do
      messages = Agent.get(__MODULE__, &(get_in(&1, [:messages, conversation_id]) || []))

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "kind" => "user_chat",
         "title" => "聊天",
         "status" => "active",
         "message_count" => length(messages)
       }}
    end

    @impl true
    def get_group_conversation_with_messages(_workspace, conversation_id, _opts) do
      messages = Agent.get(__MODULE__, &(get_in(&1, [:messages, conversation_id]) || []))

      {:ok,
       %{
         "conversation" => %{
           "conversation_id" => conversation_id,
           "kind" => "user_chat",
           "title" => "聊天",
           "status" => "active",
           "message_count" => length(messages)
         },
         "messages" => messages
       }}
    end

    @impl true
    def get_group_conversation_messages(_workspace, conversation_id) do
      {:ok, Agent.get(__MODULE__, &(get_in(&1, [:messages, conversation_id]) || []))}
    end

    @impl true
    def ensure_group_conversation_user_participant(_workspace, conversation_id, user_id) do
      {:ok, %{"conversation_id" => conversation_id, "user_id" => user_id}}
    end

    @impl true
    def reconcile_group_conversation_router_participant(_workspace, conversation_id) do
      {:ok, %{"conversation_id" => conversation_id}}
    end

    @impl true
    def list_group_conversation_participants(workspace, _conversation_id, _opts) do
      {:ok,
       %{
         "participants" => [
           %{
             "actor_type" => "agent",
             "agent_id" => workspace["router_agent_id"],
             "state" => "active"
           },
           %{
             "actor_type" => "user",
             "user_id" => workspace["owner_user_id"],
             "state" => "active"
           }
         ],
         "has_more" => false,
         "next_cursor" => nil
       }}
    end

    @impl true
    def reserve_group_conversation_message(_workspace, conversation_id, attrs) do
      request_id = attrs["client_request_id"]
      key = {conversation_id, request_id}

      message_id =
        Agent.get_and_update(__MODULE__, fn state ->
          message_id = state.reservations[key] || SalixStore.Ids.new_message_id()
          {message_id, put_in(state, [:reservations, key], message_id)}
        end)

      {:ok, %{"conversation_id" => conversation_id, "message_id" => message_id}}
    end

    @impl true
    def append_group_conversation_message(_workspace, conversation_id, attrs) do
      request_id = attrs["client_request_id"]

      message =
        Agent.get_and_update(__MODULE__, fn state ->
          messages = get_in(state, [:messages, conversation_id]) || []

          message =
            Enum.find(messages, &(&1["client_request_id"] == request_id)) ||
              attrs
              |> Map.put(
                "message_id",
                state.reservations[{conversation_id, request_id}] ||
                  SalixStore.Ids.new_message_id()
              )
              |> Map.put_new("actor_type", "user")
              |> Map.put_new("created_at", System.system_time(:second))

          updated_messages = if message in messages, do: messages, else: messages ++ [message]
          {message, put_in(state, [:messages, conversation_id], updated_messages)}
        end)

      {:ok, %{"conversation_id" => conversation_id, "message_id" => message["message_id"]}}
    end

    @impl true
    def conversation_activity_context(_workspace, _conversation_id), do: {:error, :not_found}

    @impl true
    def list_agent_skills(_workspace), do: Agent.get(__MODULE__, & &1.skills_result)

    @impl true
    def read_agent_skill_file(_workspace, "weekly-summary", "references/format.md", _max),
      do: {:ok, "# Format\n"}

    def read_agent_skill_file(_workspace, "weekly-summary", "assets/logo.png", _max),
      do: {:ok, <<0x89, 0x50, 0xFF>>}

    def read_agent_skill_file(_workspace, _skill_id, _path, _max), do: {:error, :not_found}

    @impl true
    def write_agent_file(_workspace, path, _body), do: {:ok, %{"path" => path}}

    @impl true
    def read_agent_file(_workspace, _path, _max_bytes), do: {:error, :not_found}

    def set_skills_result(result),
      do: Agent.update(__MODULE__, &Map.put(&1, :skills_result, result))

    def messages(conversation_id) do
      Agent.get(__MODULE__, &(get_in(&1, [:messages, conversation_id]) || []))
    end

    defp router_conversation_id(workspace) do
      Agent.get_and_update(__MODULE__, fn state ->
        group_id = workspace["default_group_id"]

        conversation_id =
          state.router_conversations[group_id] || SalixStore.Ids.new_conversation_id()

        state =
          state
          |> put_in([:router_conversations, group_id], conversation_id)
          |> put_in([:messages, conversation_id], state.messages[conversation_id] || [])

        {conversation_id, state}
      end)
    end
  end

  setup do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_salix_client = Application.get_env(:comma_core, :salix_client)
    prev_api_token = Application.get_env(:comma_web, :api_token)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:comma_web, :api_token, @admin_token)
    Application.put_env(:comma_core, :salix_client, SalixClientFake)

    ensure_fake_s3!()
    start_supervised!(SalixClientFake)

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, prev_backend)
      restore_env(:comma_web, :api_token, prev_api_token)
      restore_env(:comma_core, :salix_client, prev_salix_client)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    :ok
  end

  test "GET skills exposes only public fields and hides restricted sessions" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("skills-list@example.com")

    hidden_agent_id = workspace["router_agent_id"]
    hidden_tenant_id = workspace["salix_tenant_id"]
    long_description = String.duplicate("long", 100)

    SalixClientFake.set_skills_result(
      {:ok,
       %{
         "skills" => [
           %{
             "skill_id" => "weekly-summary",
             "name" => "Weekly Summary",
             "description" => long_description,
             "location" => "/.runtime/skills/weekly-summary/SKILL.md",
             "content" => "skill body #{hidden_agent_id}",
             "source" => "custom",
             "files" => ["SKILL.md", "references/format.md"],
             "layer" => "group",
             "editable" => true,
             "updated_at" => "2026-07-10T00:00:00Z",
             "tenant_id" => hidden_tenant_id
           }
         ]
       }}
    )

    body =
      user_req(session["token"], :get, "/v1/comma/workspaces/#{workspace["id"]}/skills")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [
             %{
               "skill_id" => "weekly-summary",
               "name" => "Weekly Summary",
               "description" => description,
               "location" => "/.runtime/skills/weekly-summary/SKILL.md",
               "source" => "custom"
             } = skill
           ] = body["data"]

    assert Map.keys(skill) |> Enum.sort() == [
             "description",
             "location",
             "name",
             "skill_id",
             "source"
           ]

    assert String.length(description) == 280
    refute Jason.encode!(body) =~ hidden_agent_id
    refute Jason.encode!(body) =~ hidden_tenant_id
    refute Jason.encode!(body) =~ "content"
    refute Jason.encode!(body) =~ "editable"

    detail =
      user_req(session["token"], :get, "/v1/comma/workspaces/#{workspace["id"]}/skills/weekly-summary")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert detail["content"] == "skill body #{hidden_agent_id}"

    assert detail["files"] == ["SKILL.md", "references/format.md"]

    file_path = "/v1/comma/workspaces/#{workspace["id"]}/skills/weekly-summary/file"

    assert user_req(session["token"], :get, file_path <> "?path=references/format.md")
           |> expect_status(200)
           |> Map.fetch!(:body) == %{"path" => "references/format.md", "content" => "# Format\n"}

    assert user_req(session["token"], :get, file_path <> "?path=assets/logo.png").status == 415
    assert user_req(session["token"], :get, file_path <> "?path=missing.md").status == 404

    assert Map.keys(detail) |> Enum.sort() == [
             "content",
             "description",
             "files",
             "location",
             "name",
             "skill_id",
             "source"
           ]

    assert user_req(session["token"], :get, "/v1/comma/workspaces/#{workspace["id"]}/skills/missing").status ==
             404

    restricted =
      admin_req(:post, "/v1/comma/admin/users/#{session["user_id"]}/sessions",
        json: %{
          "workspace_id" => workspace["id"],
          "group_id" => workspace["default_group_id"],
          "conversation_id" => conversation["id"],
          "restricted" => true
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert user_req(restricted["token"], :get, "/v1/comma/workspaces/#{workspace["id"]}/skills").status ==
             403

    assert user_req(
             restricted["token"],
             :get,
             "/v1/comma/workspaces/#{workspace["id"]}/skills/weekly-summary"
           ).status == 403
  end

  test "skills endpoint degrades empty before provisioning and reports unavailable failures" do
    %{workspace: workspace, session: session} = create_fixture("skills-empty@example.com")

    SalixClientFake.set_skills_result({:error, :not_found})

    empty =
      user_req(session["token"], :get, "/v1/comma/workspaces/#{workspace["id"]}/skills")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert empty == %{"data" => []}

    SalixClientFake.set_skills_result({:error, :boom})

    unavailable =
      user_req(session["token"], :get, "/v1/comma/workspaces/#{workspace["id"]}/skills")
      |> expect_status(503)
      |> Map.fetch!(:body)

    assert unavailable["error"] == "skills_unavailable"
  end

  test "message skill mentions are server-authorized and spoof-resistant" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("skills-send@example.com")

    valid = skill("weekly-summary", "Weekly Summary")

    SalixClientFake.set_skills_result({:ok, %{"skills" => [valid]}})

    send_path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages"

    user_req(session["token"], :post, send_path,
      json: %{
        "client_request_id" => "skills-send-1",
        "message" => %{"content" => "please /weekly-summary"},
        "skills" => [
          %{"location" => valid["location"], "name" => "Client Spoof"},
          %{"location" => valid["location"]},
          %{"location" => "/etc/passwd"},
          %{"location" => "/.runtime/skills/not-exists/SKILL.md"},
          "garbage",
          %{"x" => 1}
        ]
      }
    )
    |> expect_status(202)

    assert [%{"content" => content}] = SalixClientFake.messages(conversation["id"])
    assert content =~ "please /weekly-summary"
    assert content =~ @protocol_marker
    assert content =~ "- Weekly Summary — #{valid["location"]}"
    refute content =~ "Client Spoof"
    refute content =~ "/etc/passwd"
    refute content =~ "not-exists"

    visible =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [%{"content" => ^content}] = visible["data"]
  end

  test "no skills stays bit-for-bit and unavailable catalog silently degrades send" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("skills-degrade@example.com")

    send_path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages"

    user_req(session["token"], :post, send_path,
      json: %{
        "client_request_id" => "skills-none",
        "message" => %{"content" => "plain text"}
      }
    )
    |> expect_status(202)

    SalixClientFake.set_skills_result({:error, :catalog_down})

    user_req(session["token"], :post, send_path,
      json: %{
        "client_request_id" => "skills-down",
        "message" => %{"content" => "please /weekly-summary"},
        "skills" => [%{"location" => "/.runtime/skills/weekly-summary/SKILL.md"}]
      }
    )
    |> expect_status(202)

    assert [
             %{"content" => "plain text"},
             %{"content" => "please /weekly-summary"}
           ] = SalixClientFake.messages(conversation["id"])
  end

  test "user-authored protocol marker is escaped before display stripping can hide text" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("skills-marker@example.com")

    send_path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages"

    user_req(session["token"], :post, send_path,
      json: %{
        "client_request_id" => "skills-marker",
        "message" => %{
          "content" => "visible #{@protocol_marker}\nhidden from UI if unescaped"
        }
      }
    )
    |> expect_status(202)

    assert [%{"content" => content}] = SalixClientFake.messages(conversation["id"])
    assert content == "visible [[comma-protocol-user]]\nhidden from UI if unescaped"
    refute content =~ @protocol_marker
  end

  test "skill mentions dedupe, cap at ten, and idempotent retry does not duplicate protocol" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("skills-cap@example.com")

    skills = Enum.map(1..12, &skill("skill-#{&1}", "Skill #{&1}"))
    SalixClientFake.set_skills_result({:ok, %{"skills" => skills}})

    send_path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages"

    user_req(session["token"], :post, send_path,
      json: %{
        "client_request_id" => "skills-cap",
        "message" => %{"content" => "run many"},
        "skills" =>
          [%{"location" => List.first(skills)["location"]}] ++
            Enum.map(skills, &%{"location" => &1["location"]})
      }
    )
    |> expect_status(202)

    user_req(session["token"], :post, send_path,
      json: %{
        "client_request_id" => "skills-cap",
        "message" => %{"content" => "run many"},
        "skills" => Enum.map(skills, &%{"location" => &1["location"]})
      }
    )
    |> expect_status(202)

    assert [%{"content" => content}] = SalixClientFake.messages(conversation["id"])
    assert content =~ @protocol_marker
    assert length(Regex.scan(~r/^- Skill /m, content)) == 10
    assert content =~ "- Skill 1 — /.runtime/skills/skill-1/SKILL.md"
    assert content =~ "- Skill 10 — /.runtime/skills/skill-10/SKILL.md"
    refute content =~ "skill-11"
    refute content =~ "skill-12"
  end

  defp create_fixture(email) do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => email, "name" => "Skills"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    issue_billing_grant(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)
      |> Map.put("user_id", user["id"])

    conversation =
      user_req(
        session["token"],
        :post,
        "/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat",
        json: %{}
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    %{user: user, workspace: workspace, session: session, conversation: conversation}
  end

  defp skill(id, name) do
    %{
      "skill_id" => id,
      "name" => name,
      "description" => "#{name} instructions",
      "location" => "/.runtime/skills/#{id}/SKILL.md",
      "content" => "hidden content"
    }
  end

  defp ensure_fake_s3! do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp admin_req(method, path, opts), do: req(@admin_token, method, path, opts)
  defp user_req(token, method, path, opts \\ []), do: req(token, method, path, opts)

  defp req(token, method, path, opts) do
    headers = [{"authorization", "Bearer " <> token}]
    Req.request!([method: method, url: base() <> path, headers: headers, retry: false] ++ opts)
  end

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
  defp base, do: CommaWeb.Application.base_url()

  defp issue_billing_grant(%{"billing_account_id" => account_id, "id" => workspace_id}) do
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
        expires_at: DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second),
        source_type: "manual_contract",
        source_id: "comma-skills-test:#{workspace_id}",
        source_event_id: "comma-skills-test:#{workspace_id}",
        idempotency_key: "comma-skills-test:#{workspace_id}:2026-06"
      })

    :ok
  end
end
