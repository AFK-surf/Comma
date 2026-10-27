defmodule CommaWeb.Coding.PullRequestEndpointsTest do
  use SystemsClock.Case, async: false

  alias Comma.{Accounts, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias SalixIM.ConversationServer
  alias SalixStore.Ids

  # GitHub as the endpoints see it: one branch, its pull requests, and every write recorded.
  defmodule GitHub do
    @moduledoc false
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> %{pr: nil, writes: [], refuse: nil} end, name: __MODULE__)

    def put_pr(pr), do: Agent.update(__MODULE__, &%{&1 | pr: pr})
    def refuse(reason), do: Agent.update(__MODULE__, &%{&1 | refuse: reason})
    def writes, do: Agent.get(__MODULE__, &Enum.reverse(&1.writes))
    defp write(entry), do: Agent.update(__MODULE__, &%{&1 | writes: [entry | &1.writes]})

    def token(_tenant, _group), do: {:ok, %{token: "ghu_x", expires_at: nil}}

    def pull_request("ghu_x", "acme", "api", "comma/retry"),
      do: {:ok, Agent.get(__MODULE__, & &1.pr)}

    def create_pull_request("ghu_x", "acme", "api", attrs) do
      case Agent.get(__MODULE__, & &1.refuse) do
        nil ->
          write({:create, attrs})

          put_pr(
            pr(%{title: attrs["title"], state: if(attrs["draft"], do: "draft", else: "open")})
          )

          {:ok, %{url: "https://github.com/acme/api/pull/12", number: 12, title: attrs["title"]}}

        refusal ->
          {:error, refusal}
      end
    end

    def update_pull_request("ghu_x", "acme", "api", 12, changes) do
      write({:update, changes})
      Agent.update(__MODULE__, fn s -> %{s | pr: Map.merge(s.pr, atomize(changes))} end)
      :ok
    end

    def ready_for_review("ghu_x", "acme", "api", 12) do
      write(:ready)
      Agent.update(__MODULE__, fn s -> %{s | pr: %{s.pr | state: "open"}} end)
      :ok
    end

    @sha "0123456789abcdef0123456789abcdef01234567"
    def sha, do: @sha

    def compare("ghu_x", "acme", "api", "main", "comma/retry") do
      {:ok,
       %{
         ahead_by: 1,
         files: [
           %{path: "retry.ex", status: "modified", additions: 3, deletions: 1, patch: "@@"},
           %{path: "retry_test.exs", status: "added", additions: 9, deletions: 0, patch: "@@"}
         ],
         commits: [%{sha: @sha, title: "Back off", author: "Ann", at: "2026-10-23T10:00:00Z"}]
       }}
    end

    def commit("ghu_x", "acme", "api", @sha),
      do:
        {:ok,
         %{
           files: [
             %{path: "retry.ex", status: "modified", additions: 3, deletions: 1, patch: "@@"}
           ]
         }}

    def merge_method("ghu_x", "acme", "api"), do: {:ok, "squash"}

    @head "89abcdef0123456789abcdef0123456789abcdef"
    def head, do: @head

    # As GitHub does, a merge whose head moved past the one named is refused.
    def merge_pull_request("ghu_x", "acme", "api", 12, method, sha) do
      if sha == Agent.get(__MODULE__, & &1.pr.head_sha) do
        write({:merge, method})
        Agent.update(__MODULE__, fn s -> %{s | pr: %{s.pr | state: "merged"}} end)
        :ok
      else
        {:error, {:github, 409, "Head branch was modified. Review and try the merge again."}}
      end
    end

    def pr(attrs) do
      Map.merge(
        %{
          url: "https://github.com/acme/api/pull/12",
          number: 12,
          title: "Retry with backoff",
          body: "Make it back off",
          head_sha: @head,
          state: "open",
          mergeable: "mergeable",
          checks: %{passed: 2, failed: 0, total: 3},
          new_commits: false
        },
        attrs
      )
    end

    defp atomize(changes), do: Map.new(changes, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(GitHub)
    SystemsRuntime.put_env(:salix_web, :coding_github, GitHub)
    SalixAgent.TestSupport.configure_control_fixtures!()
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Coding pull requests"})

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_web, :coding_github)
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3)
      CommaWeb.TestRepoSandbox.stop_owner(owner)
    end)

    {owner_user, owner_session} = user!()
    {viewer, viewer_session} = user!()
    workspace = workspace!(owner_user, tenant, group)
    member!(workspace, viewer, "viewer")

    {:ok, task} =
      ConversationServer.create_group_conversation(group, %{
        "kind" => "agent_task",
        "title" => "Retry with backoff",
        "runs_on" => %{"kind" => "sandbox"},
        "repo" => %{
          "owner" => "acme",
          "name" => "api",
          "base_ref" => "main",
          "branch" => "comma/retry"
        }
      })

    {:ok, _participant} =
      ConversationServer.ensure_group_conversation_user_participant(
        group,
        task["conversation_id"],
        %{
          "user_id" => owner_user["id"],
          "state" => "active",
          "notification_filter" => %{"messages" => "none", "statuses" => "none"}
        }
      )

    {:ok, _message} =
      ConversationServer.append_group_conversation_message(group, task["conversation_id"], %{
        "actor_type" => "user",
        "user_id" => owner_user["id"],
        "content" => "Make the retry helper back off exponentially.",
        "delivery_filter" => %{"participant_ids" => []}
      })

    server =
      start_supervised!(
        {Bandit, plug: CommaWeb.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    %{
      pr:
        "http://127.0.0.1:#{port}/v1/comma/workspaces/#{workspace.id}/coding/sessions/" <>
          task["conversation_id"] <> "/pull-request",
      owner: owner_session,
      viewer: viewer_session,
      tenant: tenant,
      group: group,
      task: task["conversation_id"]
    }
  end

  test "the branch's change totals and pull request a read finds come with the Task's run",
       ctx do
    {:ok, _workload} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: ctx.task,
        workspace: "comma:" <> ctx.group,
        repo: %{
          "owner" => "acme",
          "name" => "api",
          "base_ref" => "main",
          "branch" => "comma/retry"
        }
      })

    salix = %{"default_group_id" => ctx.group, "salix_tenant_id" => ctx.tenant}
    changes = String.replace_suffix(ctx.pr, "/pull-request", "/changes")

    # Nothing was read yet: the run has no facts.
    assert {:ok, %{"facts" => %{}}} = CommaWeb.SalixClient.task_run(salix, ctx.task)

    # One commit's changes are not the branch's: they keep nothing.
    GitHub.put_pr(GitHub.pr(%{}))
    assert %{status: 200} = request(:get, changes <> "?commit=" <> GitHub.sha(), ctx.viewer)
    assert {:ok, %{"facts" => %{}}} = CommaWeb.SalixClient.task_run(salix, ctx.task)
    assert {:ok, %{}} == CommaWeb.SalixClient.task_pull_requests(salix, [ctx.task])

    assert %{status: 200} = request(:get, changes, ctx.viewer)

    # The list's cards read the pull request kept with the Task.
    assert {:ok, found} = CommaWeb.SalixClient.task_pull_requests(salix, [ctx.task])

    assert found == %{
             ctx.task => %{
               "number" => 12,
               "state" => "open",
               "url" => "https://github.com/acme/api/pull/12"
             }
           }

    assert {:ok, %{"facts" => facts}} = CommaWeb.SalixClient.task_run(salix, ctx.task)
    assert facts["changes"] == %{"files" => 2, "additions" => 12, "deletions" => 1}

    assert %{"number" => 12, "state" => "open", "checks" => %{"passed" => 2, "total" => 3}} =
             facts["pull_request"]

    refute Map.has_key?(facts["pull_request"], "body")

    # The pull request merged on GitHub: the next read keeps that.
    GitHub.put_pr(GitHub.pr(%{state: "merged"}))
    assert %{status: 200} = request(:get, changes, ctx.viewer)

    assert {:ok, %{"facts" => %{"pull_request" => %{"state" => "merged"}}}} =
             CommaWeb.SalixClient.task_run(salix, ctx.task)
  end

  test "with no sandbox running, the branch it pushed is opened on GitHub, titled for the Task and described with what it was asked",
       ctx do
    assert %{status: 200, body: made} = request(:post, ctx.pr, ctx.owner, %{})

    assert made == %{
             "url" => "https://github.com/acme/api/pull/12",
             "number" => 12,
             "title" => "Retry with backoff"
           }

    assert [{:create, attrs}] = GitHub.writes()
    assert attrs["head"] == "comma/retry"
    assert attrs["base"] == "main"
    assert attrs["draft"] == false

    assert attrs["body"] ==
             "Make the retry helper back off exponentially.\n\n---\nOpened from a Comma coding Task."

    # Asked again while it is open: that one is the branch's, and none is opened a second time.
    assert %{status: 200, body: %{"number" => 12}} =
             request(:post, ctx.pr, ctx.owner, %{"draft" => true})

    assert length(GitHub.writes()) == 1
    assert %{status: 403} = request(:post, ctx.pr, ctx.viewer, %{})
  end

  test "with no sandbox running, the pushed branch's changes list its commits, and one commit is read alone",
       ctx do
    changes = String.replace_suffix(ctx.pr, "/pull-request", "/changes")
    GitHub.put_pr(GitHub.pr(%{}))

    # The whole branch's changes come with its pull request; one commit's, or what is not committed, without it.
    assert %{status: 200, body: all} = request(:get, changes, ctx.viewer)
    assert Enum.map(all["files"], & &1["path"]) == ["retry.ex", "retry_test.exs"]
    assert %{"number" => 12, "head_sha" => _} = all["pull_request"]
    assert [%{"sha" => sha, "title" => "Back off", "author" => "Ann"}] = all["commits"]
    assert all["uncommitted"] == false

    assert %{status: 200, body: one} = request(:get, changes <> "?commit=" <> sha, ctx.viewer)
    assert Enum.map(one["files"], & &1["path"]) == ["retry.ex"]
    assert one["pull_request"] == nil

    # Only the branch's commits, named in full.
    assert %{status: 404} =
             request(:get, changes <> "?commit=" <> String.duplicate("f", 40), ctx.viewer)

    assert %{status: 400} = request(:get, changes <> "?commit=0123456", ctx.viewer)

    assert %{status: 200, body: %{"files" => []}} =
             request(:get, changes <> "?uncommitted=1", ctx.viewer)
  end

  test "a pull request the branch already carries is the Task's, and none is opened beside it",
       ctx do
    # The Task continues #51: its branch ends where #51's head does, so GitHub answers #51 for it.
    GitHub.put_pr(
      GitHub.pr(%{number: 51, url: "https://github.com/acme/api/pull/51", title: "Cards"})
    )

    assert %{status: 200, body: %{"number" => 51, "url" => "https://github.com/acme/api/pull/51"}} =
             request(:post, ctx.pr, ctx.owner, %{})

    # Merged with all the branch holds: a new one would propose it again, so none is opened.
    GitHub.put_pr(
      GitHub.pr(%{number: 51, url: "https://github.com/acme/api/pull/51", state: "merged"})
    )

    assert %{status: 409} = request(:post, ctx.pr, ctx.owner, %{})

    assert GitHub.writes() == []
  end

  test "what GitHub refuses comes back in its own words", ctx do
    GitHub.refuse({:github, 422, "Validation Failed: No commits between main and comma/retry"})

    assert %{
             status: 422,
             body: %{"message" => "Validation Failed: No commits between main and comma/retry"}
           } =
             request(:post, ctx.pr, ctx.owner, %{"title" => "Mine"})
  end

  test "the branch's pull request is read, edited, made ready and merged on GitHub", ctx do
    confirmed = %{"number" => 12, "head_sha" => GitHub.head()}
    assert %{status: 200, body: %{"pull_request" => nil}} = request(:get, ctx.pr, ctx.viewer)
    assert %{status: 409} = request(:post, ctx.pr <> "/merge", ctx.owner, confirmed)

    GitHub.put_pr(GitHub.pr(%{state: "draft"}))

    assert %{status: 200, body: %{"pull_request" => read}} = request(:get, ctx.pr, ctx.viewer)
    assert read["state"] == "draft"
    assert read["head_sha"] == GitHub.head()
    assert read["checks"] == %{"passed" => 2, "failed" => 0, "total" => 3}

    # A draft is made ready before it merges.
    assert %{status: 409} = request(:post, ctx.pr <> "/merge", ctx.owner, confirmed)
    assert %{status: 403} = request(:patch, ctx.pr, ctx.viewer, %{"ready" => true})

    assert %{status: 200, body: %{"pull_request" => edited}} =
             request(:patch, ctx.pr, ctx.owner, %{
               "title" => "Back off between retries",
               "body" => "",
               "ready" => true
             })

    assert edited["title"] == "Back off between retries"
    assert edited["body"] == ""
    assert edited["state"] == "open"

    assert %{status: 200, body: %{"method" => "squash", "pull_request" => merged}} =
             request(:post, ctx.pr <> "/merge", ctx.owner, confirmed)

    assert merged["state"] == "merged"

    assert GitHub.writes() == [
             {:update, %{"title" => "Back off between retries", "body" => ""}},
             :ready,
             {:merge, "squash"}
           ]

    assert %{status: 403} = request(:post, ctx.pr <> "/merge", ctx.viewer, confirmed)
  end

  test "a merge acts only on the pull request the member confirmed, at the head they saw", ctx do
    GitHub.put_pr(GitHub.pr(%{}))

    # A merge names what it merges.
    assert %{status: 400} = request(:post, ctx.pr <> "/merge", ctx.owner, %{})

    assert %{status: 400} =
             request(:post, ctx.pr <> "/merge", ctx.owner, %{"number" => 12, "head_sha" => "89ab"})

    # The pull request confirmed was closed and the branch opened another meanwhile.
    assert %{status: 409} =
             request(:post, ctx.pr <> "/merge", ctx.owner, %{
               "number" => 11,
               "head_sha" => GitHub.head()
             })

    # The Worker pushed after the member confirmed: those commits are not merged unseen.
    assert %{status: 422, body: %{"message" => "Head branch was modified." <> _}} =
             request(:post, ctx.pr <> "/merge", ctx.owner, %{
               "number" => 12,
               "head_sha" => String.duplicate("e", 40)
             })

    assert GitHub.writes() == []
  end

  test "a long title is cut at a character's end, so the pull request still opens", ctx do
    # 100 three-byte characters: 300 bytes, past the 256 a title keeps; 256 falls inside the 86th.
    title = String.duplicate("重", 100)

    assert %{status: 200, body: %{"title" => made}} =
             request(:post, ctx.pr, ctx.owner, %{"title" => title})

    assert made == String.duplicate("重", 85)
  end

  defp user! do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "coding-pr-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    {user, session}
  end

  defp workspace!(user, tenant, group) do
    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_coding_pr_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "coding-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "coding-test",
        name: "Coding team",
        status: "active"
      })

    member!(workspace, user, "owner")
    workspace
  end

  defp member!(workspace, user, role) do
    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: role,
      status: "active"
    })
  end

  defp request(method, url, session, body \\ nil) do
    Req.request!(
      [
        method: method,
        url: url,
        headers: [{"authorization", "Bearer " <> session["token"]}],
        retry: false
      ] ++
        if(body, do: [json: body], else: [])
    )
  end
end
