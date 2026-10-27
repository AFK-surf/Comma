defmodule SalixWeb.CodingSandboxesTest do
  @moduledoc """
  The lifecycle of a coding Task's sandbox (`SalixWeb.CodingSandboxes`): made on
  L4ES with the Task's connect credential as a secret and a GitHub grant
  whose token stays out of the sandbox, its station invited once it connects, shut down when idle or when
  the Task ends, and replaced when the Task has work for it again. L4ES,
  GitHub, the station and the Task are fakes.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixEnv.Registry
  alias SalixStore.CodingSandboxes, as: Store
  alias SalixStore.{Compute.WorkloadCredential, StationTaskSessions}
  alias SalixWeb.CodingSandboxes

  defmodule GitHub do
    @moduledoc false
    # The Group's token: one that does not expire, unless a test gives another
    # (`{token, expires_at}`).
    def token(_tenant, _group) do
      case SystemsRuntime.get_env(:salix_web, :coding_test_github_token) do
        {token, at} -> {:ok, %{token: token, expires_at: at}}
        nil -> {:ok, %{token: "ghu_group_token", expires_at: nil}}
      end
    end

    def user("ghu_group_token"),
      do: {:ok, %{login: "octo", id: 7, email: "7+octo@users.noreply.github.com"}}

    def repo(_token, "acme", "api"),
      do: {:ok, %{full_name: "acme/api", default_branch: "main", private: true, push: true}}

    def repo(_token, _owner, _name), do: {:error, :not_found}

    def pull_request("ghu_group_token", "acme", "api", "comma/code"),
      do:
        {:ok,
         %{
           url: "https://github.com/acme/api/pull/7",
           number: 7,
           title: "Make the API faster",
           body: "What the Task was asked, at length.",
           head_sha: String.duplicate("a", 40),
           state: "open",
           mergeable: "mergeable",
           checks: %{passed: 98, failed: 0, total: 100},
           new_commits: false
         }}
  end

  defmodule Signer do
    @moduledoc false
    def sign(claims) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :coding_test_pid),
        {:signed, claims}
      )

      {:ok, "assertion-for-" <> claims.workspace_id}
    end
  end

  defmodule Task do
    @moduledoc false
    use Agent

    def start_link(participants),
      do:
        SystemsRuntime.Agent.start_link(
          fn -> %{participants: participants, messages: [], status: "active"} end,
          name: __MODULE__
        )

    def messages, do: SystemsRuntime.Agent.get(__MODULE__, & &1.messages)
    def set_status(status), do: SystemsRuntime.Agent.update(__MODULE__, &%{&1 | status: status})

    def owner(_group, _conversation), do: {:ok, "usr_owner"}

    def status(_group, _conversation),
      do: {:ok, SystemsRuntime.Agent.get(__MODULE__, & &1.status)}

    def append(_group, _conversation, _agent, attrs) do
      SystemsRuntime.Agent.get_and_update(__MODULE__, fn state ->
        message = Map.put(attrs, "seq", length(state.messages) + 1)
        {{:ok, message}, %{state | messages: state.messages ++ [message]}}
      end)
    end

    def messages_after(_group, _conversation, after_seq, limit),
      do: {:ok, messages() |> Enum.filter(&(&1["seq"] > after_seq)) |> Enum.take(limit)}

    def participants(_group, _conversation),
      do: {:ok, SystemsRuntime.Agent.get(__MODULE__, & &1.participants)}

    def turn_ended(_group, _conversation, _seq), do: {:ok, "ready_for_review"}
  end

  defmodule Author do
    @moduledoc "The product's word on who a Task's owner is."
    def identity("usr_ann"), do: {:ok, %{name: "Ann Lee", email: "ann@example.com"}}
    def identity("usr_owner"), do: {:ok, %{name: "Owner", email: "owner@example.com"}}
    def identity(_user), do: {:error, :not_found}
  end

  defmodule Answers do
    @moduledoc "L4ES's next answers to a method (`{status, json}`), given once each before its usual one."
    use Agent

    def start_link(_), do: SystemsRuntime.Agent.start_link(fn -> %{} end, name: __MODULE__)

    def push(method, status, json),
      do:
        SystemsRuntime.Agent.update(
          __MODULE__,
          &Map.update(&1, method, [{status, json}], fn q -> q ++ [{status, json}] end)
        )

    def take(method) do
      SystemsRuntime.Agent.get_and_update(__MODULE__, fn answers ->
        case Map.get(answers, method, []) do
          [next | rest] -> {next, Map.put(answers, method, rest)}
          [] -> {nil, answers}
        end
      end)
    end

    def sandbox(path), do: SystemsRuntime.Agent.get(__MODULE__, &Map.get(&1, {:sandbox, path}))

    def save_sandbox(path, attrs) do
      SystemsRuntime.Agent.get_and_update(__MODULE__, fn state ->
        saved = Map.merge(Map.get(state, {:sandbox, path}, %{}), attrs)
        {saved, Map.put(state, {:sandbox, path}, saved)}
      end)
    end

    def delete_sandbox(path),
      do: SystemsRuntime.Agent.update(__MODULE__, &Map.delete(&1, {:sandbox, path}))
  end

  defmodule Station do
    @moduledoc "The sandbox's station: what it is asked, and how it answers `task.status` (`status/1`)."
    use Agent

    def start_link(_), do: SystemsRuntime.Agent.start_link(fn -> nil end, name: __MODULE__)
    def status(answer), do: SystemsRuntime.Agent.update(__MODULE__, fn _ -> answer end)

    def request(_run_id, method, params, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :coding_test_pid),
        {:asked, method, params}
      )

      case method do
        "task.invite" ->
          SystemsRuntime.get_env(
            :salix_web,
            :coding_invite_result,
            {:ok, %{"session" => "ember:c-1"}}
          )

        "task.put" ->
          {:ok, %{"through" => params["through"]}}

        "task.save" ->
          {:ok, %{"dirty" => false, "unpushed" => false}}

        "task.status" ->
          {:ok, SystemsRuntime.Agent.get(__MODULE__, & &1)}

        "task.history" ->
          {:ok,
           %{
             "start" => 40,
             "total" => 41,
             "entries" => [%{"kind" => "assistant", "text" => "Made the API faster."}],
             "usage" => %{
               "modelCalls" => 36,
               "inputTokens" => 52_000,
               "cachedTokens" => 1_700_000,
               "outputTokens" => 9_100,
               "model" => nil
             }
           }}

        "task.diff" ->
          {:ok,
           %{
             "base" => "main",
             "branch" => "comma/code",
             "truncated" => false,
             "commits" => [],
             "uncommitted" => false,
             "files" => [
               %{
                 "path" => "lib/api.ex",
                 "status" => "modified",
                 "additions" => 2_470,
                 "deletions" => 876
               },
               %{
                 "path" => "test/api_test.exs",
                 "status" => "added",
                 "additions" => 206,
                 "deletions" => 120
               }
             ]
           }}
      end
    end
  end

  setup do
    # Sandboxes earlier tests left are never due again: a check takes a page of the
    # due ones across every Group, and theirs would take this test's place.
    import Ecto.Query, only: [from: 2]

    SalixStore.Repo.update_all(
      from(w in SalixStore.Compute.Workload,
        where: w.kind == ^Store.kind(),
        update: [
          set: [
            spec:
              fragment(
                "jsonb_set(?, '{next_check_at}', to_jsonb('9999-12-31T00:00:00Z'::text))",
                w.spec
              )
          ]
        ]
      ),
      []
    )

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Coding"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Coding"}, tenant["tenant_id"])

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    start_supervised!(
      {Task,
       [
         %{
           "participant_id" => "ptp_worker",
           "actor_type" => "agent",
           "agent_id" => worker["agent_id"],
           "role_label" => "worker",
           "state" => "active"
         }
       ]}
    )

    start_supervised!(Station)
    test_pid = SystemsRuntime.Proc.self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      # A stop is a POST too: it is told apart as "STOP".
      method = if String.ends_with?(conn.request_path, "/stop"), do: "STOP", else: conn.method

      SystemsRuntime.Proc.send(
        test_pid,
        {:l4es, method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
         if(body == "", do: nil, else: Jason.decode!(body))}
      )

      # A GET's answer is its path's: the create asks L4ES several things at once,
      # and an answer for one must not reach another.
      case Answers.take({method, conn.request_path}) ||
             if(method != "GET", do: Answers.take(method)) do
        {status, json} -> Req.Test.json(Plug.Conn.put_status(conn, status), json)
        nil -> default_answer(conn, if(body == "", do: %{}, else: Jason.decode!(body)))
      end
    end)

    Req.Test.set_req_test_to_shared()
    start_supervised!(Answers)

    for {key, value} <- [
          l4es: [url: "https://l4es.test", req_options: [plug: {Req.Test, __MODULE__}]],
          l4es_assertion_signer: Signer,
          coding_github: GitHub,
          coding_test_pid: test_pid,
          station_tasks: [conversations: Task, connector: Station]
        ],
        do: SystemsRuntime.put_env(:salix_web, key, value)

    previous = SystemsRuntime.get_env(:salix_store, :compute_workload_credential_secret)

    SystemsRuntime.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("s", 32)
    )

    on_exit(fn ->
      for key <- [
            :l4es,
            :l4es_assertion_signer,
            :coding_github,
            :coding_test_pid,
            :coding_test_github_token,
            :station_tasks,
            :coding_git_author,
            :coding_members
          ],
          do: SystemsRuntime.delete_env(:salix_web, key)

      if previous,
        do: SystemsRuntime.put_env(:salix_store, :compute_workload_credential_secret, previous),
        else: SystemsRuntime.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    reservation = %{
      tenant_id: tenant["tenant_id"],
      group_id: group["group_id"],
      conversation_id: "cnv_code",
      device_id: Store.device_id("cnv_code"),
      agent_id: worker["agent_id"],
      start: %{
        "requester" => worker["agent_id"] <> "@agents.salix",
        "runtime" => "claude",
        "repo" => %{
          "owner" => "acme",
          "name" => "api",
          "base_ref" => "main",
          "branch" => "comma/code"
        }
      },
      repo: %{"owner" => "acme", "name" => "api", "base_ref" => "main", "branch" => "comma/code"}
    }

    start_supervised!(SalixWeb.L4ESRecent)
    SalixWeb.L4ESRecent.forget(reservation.group_id)
    {:ok, reservation: reservation}
  end

  defp default_answer(conn, body) do
    case if(String.ends_with?(conn.request_path, "/stop"), do: "STOP", else: conn.method) do
      "POST" ->
        if body["name"] && String.ends_with?(conn.request_path, "/sandboxes") do
          Answers.save_sandbox(conn.request_path <> "/" <> body["name"], body)
        end

        Req.Test.json(Plug.Conn.put_status(conn, 201), %{"state" => "scheduled"})

      "GET" ->
        case Answers.sandbox(conn.request_path) do
          nil -> Req.Test.json(Plug.Conn.put_status(conn, 404), %{})
          saved -> Req.Test.json(conn, Map.put(saved, "state", "running"))
        end

      "PATCH" ->
        Req.Test.json(conn, Answers.save_sandbox(conn.request_path, body))

      "DELETE" ->
        Answers.delete_sandbox(conn.request_path)
        Req.Test.json(conn, %{})

      method when method in ["PUT", "STOP"] ->
        Req.Test.json(conn, %{})
    end
  end

  # The Task's sandbox in L4ES; a stopped one keeps its name as its disk's.
  defp sandbox_path(r) do
    spec = workload(r).spec
    "/api/workspaces/comma:#{r.group_id}/sandboxes/#{spec["sandbox"] || spec["disk"]}"
  end

  defp workload(r) do
    {:ok, w} = Store.get_by_conversation(r.tenant_id, r.conversation_id)
    w
  end

  defp due!(r) do
    w = workload(r)
    {:ok, _} = Store.update(w.id, fn w -> {:ok, Map.put(w.spec, "next_check_at", "0")} end)
    CodingSandboxes.check_due()
    workload(r)
  end

  defp connect!(r) do
    transport = Store.transport_id(r.conversation_id)

    {:ok, ^transport, record} =
      Registry.connect(
        "test-node",
        %{
          "tenant_id" => r.tenant_id,
          "group_id" => r.group_id,
          "device_id" => r.device_id,
          "connector_id" => Store.connector_id(r.conversation_id),
          "workload_id" => workload(r).id,
          "workload_generation" => workload(r).generation,
          "name" => "Coding sandbox"
        },
        transport_id: transport
      )

    CodingSandboxes.connected(%{
      tenant_id: r.tenant_id,
      group_id: r.group_id,
      device_id: r.device_id,
      connector_run_id: record["connector_run_id"],
      workload_id: workload(r).id,
      workload_generation: workload(r).generation
    })
  end

  defp router_task!(r) do
    id = SalixStore.Ids.new_conversation_id()
    r = %{r | conversation_id: id, device_id: Store.device_id(id)}

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => r.group_id, "name" => "Router", "role" => "router"},
        r.tenant_id
      )

    {:ok, _} = Salix.Control.Groups.update(r.group_id, %{"router_agent_id" => router["agent_id"]})

    {:ok, seed} =
      SalixIM.ConversationSeedInput.prepare(r.group_id, r.conversation_id, %{
        "messages" => [],
        "conversation" => %{
          "kind" => "agent_task",
          "runs_on" => %{"kind" => "sandbox", "device_id" => r.device_id},
          "repo" => r.repo,
          "participants" => [
            %{"actor_type" => "agent", "agent_id" => router["agent_id"], "role_label" => "router"}
          ]
        }
      })

    {:ok, _} =
      SalixIM.ConversationServer.seed_group_conversation_transcript(
        r.group_id,
        r.conversation_id,
        seed
      )

    SystemsRuntime.put_env(:salix_im, :task_stations_mod, SalixWeb.StationTasks)
    {router["agent_id"], r}
  end

  defp update_github(router, r, github) do
    SalixIM.Provider.call_api(router, "internal", "internal.task.update", %{
      "connect_id" => "internal",
      "params" => %{"conversation_id" => r.conversation_id, "github" => github}
    })
  end

  test "a Router-created coding Task with no branch grants write access to its generated branch",
       %{reservation: r} do
    {router, r} = router_task!(r)
    SystemsRuntime.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)

    assert {:ok, %{"conversation_id" => id}} =
             SalixIM.Provider.call_api(router, "internal", "internal.task.create", %{
               "connect_id" => "internal",
               "tool_call_id" => "create-code-with-generated-branch",
               "params" => %{
                 "content" => "Make the API faster.",
                 "agent_id" => r.agent_id,
                 "runs_on" => %{"kind" => "sandbox"},
                 "repo" => %{"owner" => "acme", "name" => "api"}
               }
             })

    {:ok, task} = SalixIM.Conversations.get_group_conversation(r.group_id, id)
    branch = task["repo"]["branch"]
    assert "comma/" <> suffix = branch
    assert suffix != ""
    created = %{r | conversation_id: id}
    w = due!(created)
    path = "/api/workspaces/comma:#{r.group_id}/sandboxes/#{w.spec["sandbox"]}"

    assert Answers.sandbox(path)["github"] == %{
             "repos" => %{"acme/api" => "write"},
             "push_refs" => ["refs/heads/" <> branch]
           }

    assert w.spec["start"]["repo"]["branch"] == branch
  end

  test "the Router replaces a coding Task's ACL through L4ES and a restart keeps it",
       %{reservation: r} do
    {router, r} = router_task!(r)
    :ok = CodingSandboxes.reserve(r)
    w = due!(r)
    path = "/api/workspaces/comma:#{r.group_id}/sandboxes/#{w.spec["sandbox"]}"
    assert_received {:l4es, "POST", _, _, _}

    github = %{
      "repos" => %{"acme/api" => "write", "acme/docs" => "read"},
      "push_refs" => ["refs/heads/comma/code"],
      "anonymous" => false
    }

    {:ok, manual} = SalixIM.Provider.provider_manual("internal", router)
    operation = Enum.find(manual["apis"], &(&1["name"] == "internal.task.update"))

    assert :ok =
             SalixAgent.Tools.validate_schema(
               %{"conversation_id" => r.conversation_id, "github" => github},
               operation["input_schema"]
             )

    assert {:ok, %{"updated" => true, "github" => ^github}} = update_github(router, r, github)
    assert_received {:l4es, "PATCH", ^path, _, %{"github" => ^github}}
    assert workload(r).generation == w.generation
    refute_received {:l4es, "POST", _, _, _}
    refute_received {:l4es, "PUT", _, _, _}

    connect!(r)
    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 3 * 3_600_000})
    assert due!(r).spec["state"] == "stopped"
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert due!(r).generation == 2
    assert Answers.sandbox(path)["github"] == github
  end

  test "the Router can remove a stopped sandbox's grant without a restart restoring it",
       %{reservation: r} do
    {router, r} = router_task!(r)
    stopped!(r)
    path = "/api/workspaces/comma:#{r.group_id}/sandboxes/#{workload(r).spec["disk"]}"

    assert {:ok, %{"github" => false, "updated" => true}} = update_github(router, r, false)
    assert_received {:l4es, "PATCH", ^path, _, %{"github" => false}}
    assert due!(r).spec["created"] == true
    assert Answers.sandbox(path)["github"] == false
  end

  test "ACL refusals and an unavailable sandbox are returned without claiming success",
       %{reservation: r} do
    {router, r} = router_task!(r)
    :ok = CodingSandboxes.reserve(r)
    assert {:error, waiting} = update_github(router, r, %{})
    assert waiting =~ "not been created"
    refute_received {:l4es, "PATCH", _, _, _}

    w = due!(r)
    path = "/api/workspaces/comma:#{r.group_id}/sandboxes/#{w.spec["sandbox"]}"
    original = Answers.sandbox(path)["github"]
    Answers.push("PATCH", 400, %{"error" => "Invalid GitHub ACL."})
    assert {:error, error} = update_github(router, r, %{"repos" => %{"acme/api" => "admin"}})
    assert error =~ "Invalid GitHub ACL."
    assert Answers.sandbox(path)["github"] == original

    Answers.push("PATCH", 503, %{"error" => "Try again later"})
    assert {:error, error} = update_github(router, r, false)
    assert error =~ "503"
    assert Answers.sandbox(path)["github"] == original

    Answers.push("PATCH", 404, %{})
    assert {:error, ":not_found"} = update_github(router, r, false)
  end

  test "ACL updates require the Task's Router participant and reject unrelated parameters",
       %{reservation: r} do
    {router, r} = router_task!(r)
    :ok = CodingSandboxes.reserve(r)
    due!(r)

    assert {:error, role_error} = update_github(r.agent_id, r, false)
    assert role_error =~ "agent role"

    {:ok, other_router} =
      SalixAgent.Control.create(
        %{"group_id" => r.group_id, "name" => "Other Router", "role" => "router"},
        r.tenant_id
      )

    assert {:error, participant_error} = update_github(other_router["agent_id"], r, false)
    assert participant_error =~ "not a Conversation participant"

    {:ok, other_group} = Salix.Control.Groups.create(%{"name" => "Other"}, r.tenant_id)

    {:ok, foreign_router} =
      SalixAgent.Control.create(
        %{"group_id" => other_group["group_id"], "name" => "Foreign Router", "role" => "router"},
        r.tenant_id
      )

    assert {:error, "conversation not found"} =
             update_github(foreign_router["agent_id"], r, false)

    assert {:error, "github must be an ACL object or false"} = update_github(router, r, true)

    assert {:error, _} =
             SalixIM.Provider.call_api(router, "internal", "internal.task.update", %{
               "connect_id" => "internal",
               "params" => %{
                 "conversation_id" => r.conversation_id,
                 "github" => false,
                 "command" => "Change something else"
               }
             })

    refute_received {:l4es, "PATCH", _, _, _}
  end

  test "a reserved sandbox is made on L4ES with its connect credential and a GitHub grant",
       %{reservation: r} do
    assert :ok = CodingSandboxes.reserve(r)
    w = due!(r)
    group = r.group_id
    path = "/api/workspaces/comma:#{group}/sandboxes"
    name = CodingSandboxes.sandbox_name("cnv_code", 1)

    assert_received {:signed, %{workspace_id: ^group}}

    assert_received {:l4es, "POST", ^path, ["Bearer assertion-for-" <> ^group], body}
    assert body["name"] == name
    assert body["keep"] == true
    assert body["semi_persistent"] == true
    assert body["image"] == "comma-coding"
    # The token goes to L4ES's proxy, not into the sandbox: the Task's
    # repository, pushes to its branch only.
    assert Map.keys(body["secrets"]) == ["SALIX_WORKLOAD_CREDENTIAL"]
    assert body["github_token"] == "ghu_group_token"

    assert body["github"] == %{
             "repos" => %{"acme/api" => "write"},
             "push_refs" => ["refs/heads/comma/code"]
           }

    assert body["env"]["COMMA_GIT_USER_NAME"] == "octo"
    # What a later start of the same sandbox asks again: nothing of the generation.
    assert body["metadata"] == %{"task" => "cnv_code", "workload" => w.id}

    # The credential connects as this Workload, of this generation.
    assert {:ok, %{id: id}} =
             WorkloadCredential.verify_connect(body["secrets"]["SALIX_WORKLOAD_CREDENTIAL"])

    assert id == w.id
    assert w.spec["sandbox"] == name
    assert w.spec["disk"] == name
    assert w.spec["state"] == "starting"
  end

  test "it commits as the Comma user who owns the Task, else as the GitHub account",
       %{reservation: r} do
    SystemsRuntime.put_env(:salix_web, :coding_git_author, Author)
    group = r.group_id
    path = "/api/workspaces/comma:#{group}/sandboxes"

    # The owner the Task was made for.
    :ok = CodingSandboxes.reserve(Map.put(r, :requester, "usr_ann"))
    due!(r)
    assert_received {:l4es, "POST", ^path, _, body}
    assert body["env"]["COMMA_GIT_USER_NAME"] == "Ann Lee"
    assert body["env"]["COMMA_GIT_USER_EMAIL"] == "ann@example.com"

    # A Task made with no requester: its conversation's owner.
    other = %{r | conversation_id: "cnv_other", device_id: Store.device_id("cnv_other")}
    :ok = CodingSandboxes.reserve(other)
    due!(other)
    assert_received {:l4es, "POST", ^path, _, body}
    assert body["env"]["COMMA_GIT_USER_EMAIL"] == "owner@example.com"
  end

  test "with a release's image manifest, the workspace gets that image, its older ones removed",
       %{reservation: r} do
    manifest =
      "https://cue-release.test/coding-sandbox/inputs/#{SystemsRuntime.Proc.unique_integer([:positive])}.json"

    manifest_path = URI.parse(manifest).path

    config = SystemsRuntime.get_env(:salix_web, :l4es)
    SystemsRuntime.put_env(:salix_web, :l4es, Keyword.put(config, :image_manifest, manifest))
    sha = String.duplicate("ab", 32)
    name = "comma-" <> String.slice(sha, 0, 12)
    images = "/api/workspaces/comma:#{r.group_id}/images"

    # Not published yet: the sandbox waits, and says why.
    :ok = CodingSandboxes.reserve(r)
    Answers.push({"GET", manifest_path}, 404, %{})
    w = due!(r)
    assert w.spec["state"] == "starting"
    assert w.spec["reason"] =~ "not published yet"
    refute_received {:l4es, "POST", "/api/workspaces/" <> _, _, _}

    # Published without a dm-verity descriptor: L4ES could not boot it.
    Answers.push({"GET", manifest_path}, 200, %{"rootfs_sha256" => sha})
    assert due!(r).spec["reason"] =~ "dm-verity"
    refute_received {:l4es, "POST", "/api/workspaces/" <> _, _, _}

    verity = %{
      "root_hash" => String.duplicate("cd", 32),
      "salt" => String.duplicate("ef", 32),
      "data_blocks" => 6
    }

    Answers.push({"GET", manifest_path}, 200, %{"rootfs_sha256" => sha, "verity" => verity})

    Answers.push({"GET", images}, 200, %{
      "images" => [%{"name" => "comma-0123456789ab", "sha256" => "00"}]
    })

    due!(r)
    assert_received {:l4es, "DELETE", path, _, _}
    assert path == images <> "/comma-0123456789ab"

    assert_received {:l4es, "POST", ^images, _,
                     %{"name" => ^name, "url" => url, "sha256" => ^sha, "verity" => ^verity}}

    assert url == "https://cue-release.test/coding-sandbox/" <> sha
    assert_received {:l4es, "POST", _, _, %{"image" => ^name}}

    # Made so lately, nothing is asked again.
    assert_received {:l4es, "GET", ^images, _, _}
    assert {:ok, ^name} = SalixWeb.L4ES.ensure_image(r.group_id)
    refute_received {:l4es, "GET", ^images, _, _}

    # Once forgotten, a workspace that has it only uses it.
    SalixWeb.L4ESRecent.forget(r.group_id)
    Answers.push({"GET", images}, 200, %{"images" => [%{"name" => name, "sha256" => sha}]})
    assert {:ok, ^name} = SalixWeb.L4ES.ensure_image(r.group_id)
    assert_received {:l4es, "GET", ^images, _, _}
    refute_received {:l4es, "POST", ^images, _, _}
  end

  defmodule Members do
    @moduledoc "The Workspace's members, as the product names them."
    def members(_tenant, _group),
      do:
        {:ok,
         [
           %{subject: "usr_kept", email: "kept@example.com"},
           %{subject: "usr_new", email: "new@example.com"}
         ]}
  end

  test "the Workspace's members become the L4ES workspace's before a sandbox is made",
       %{reservation: r} do
    SystemsRuntime.put_env(:salix_web, :coding_members, Members)
    :ok = CodingSandboxes.reserve(r)
    members = "/api/workspaces/comma:#{r.group_id}/members"

    Answers.push({"GET", members}, 200, %{
      "members" => [
        %{"provider" => "comma", "subject" => "usr_gone"},
        %{"provider" => "comma", "subject" => "usr_kept"}
      ]
    })

    w = due!(r)

    assert_received {:l4es, "POST", ^members, _,
                     %{"subject" => "usr_new", "email" => "new@example.com"}}

    assert_received {:l4es, "DELETE", path, _, _}
    assert path == members <> "/usr_gone"
    refute_received {:l4es, "POST", ^members, _, %{"subject" => "usr_kept"}}
    assert_received {:l4es, "POST", "/api/workspaces/comma:" <> _, _, %{"name" => _}}
    assert w.spec["created"] == true

    # The same members, synced lately: nothing is asked again; others are synced.
    assert_received {:l4es, "GET", ^members, _, _}
    {:ok, same} = Members.members(nil, nil)
    assert :ok = SalixWeb.L4ES.set_members(r.group_id, same)
    refute_received {:l4es, "GET", ^members, _, _}

    Answers.push({"GET", members}, 200, %{
      "members" => [%{"provider" => "comma", "subject" => "usr_kept"}]
    })

    assert :ok = SalixWeb.L4ES.set_members(r.group_id, [%{subject: "usr_kept"}])
    assert_received {:l4es, "GET", ^members, _, _}
  end

  test "members L4ES could not take hold no sandbox back", %{reservation: r} do
    SystemsRuntime.put_env(:salix_web, :coding_members, Members)
    :ok = CodingSandboxes.reserve(r)

    Answers.push({"GET", "/api/workspaces/comma:#{r.group_id}/members"}, 503, %{
      "error" => "unavailable"
    })

    w = due!(r)
    assert_received {:l4es, "POST", "/api/workspaces/comma:" <> _, _, %{"name" => _}}
    assert w.spec["created"] == true
  end

  test "a coding Task's terminal link names the sandbox its creates make", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    name = CodingSandboxes.sandbox_name("cnv_code", 1)
    url = "https://l4es.test/t/comma:#{r.group_id}/#{name}"

    assert CodingSandboxes.terminal_urls(r.group_id, ["cnv_code", "cnv_none"]) == %{
             "cnv_code" => url
           }

    # Made, the sandbox is the one the link names.
    assert due!(r).spec["sandbox"] == name
    assert CodingSandboxes.terminal_urls(r.group_id, ["cnv_code"]) == %{"cnv_code" => url}
  end

  test "its station is invited to the Task once it connects, and only once", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)

    assert_received {:asked, "task.invite",
                     %{"task" => "cnv_code", "start" => %{"repo" => %{"name" => "api"}}}}

    assert workload(r).spec["state"] == "ready"
    assert workload(r).spec["invited"] == true
    assert {:ok, [%{session: "ember:c-1"}]} = StationTaskSessions.of_task(r.group_id, "cnv_code")

    connect!(r)
    refute_received {:asked, "task.invite", _}
  end

  test "a delayed old connector initialization cannot mark its replacement ready", %{
    reservation: r
  } do
    :ok = CodingSandboxes.reserve(r)
    w = workload(r)

    old = %{
      tenant_id: r.tenant_id,
      group_id: r.group_id,
      device_id: r.device_id,
      workload_id: w.id,
      workload_generation: w.generation,
      connector_run_id: "old-run"
    }

    {:ok, _} =
      Store.update(w.id, fn current ->
        {:ok, Map.merge(current.spec, %{"state" => "stopped", "invited" => true})}
      end)

    {:ok, next} = Store.advance(w.id)
    :ok = CodingSandboxes.connected(old)
    assert workload(r).generation == next.generation
    assert workload(r).spec["state"] == "starting"
    refute workload(r).spec["connector_run_id"] == "old-run"
  end

  test "an unknown invitation keeps its carrier and sends no Task input until the Session is recovered",
       %{reservation: r} do
    SystemsRuntime.put_env(:salix_web, :coding_invite_result, {:error, :timeout})
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :coding_invite_result) end)
    :ok = CodingSandboxes.reserve(r)
    before = due!(r)
    connect!(r)
    assert_received {:asked, "task.invite", _}
    assert workload(r).spec["state"] == "ready"
    assert workload(r).spec["invite_outcome"] == "unknown"
    refute_received {:asked, "task.put", _}
    refute_received {:l4es, "STOP", _, _, _}
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == before.generation
    SystemsRuntime.put_env(:salix_web, :coding_invite_result, {:error, "recovery refused"})
    due!(r)
    assert workload(r).spec["invite_outcome"] == "unknown"
    assert workload(r).spec["state"] == "ready"
    refute_received {:l4es, "STOP", _, _, _}
    SystemsRuntime.delete_env(:salix_web, :coding_invite_result)
    connect!(r)
    assert workload(r).spec["invited"] == true
    assert workload(r).generation == before.generation

    assert {:ok, [%{session: "ember:c-1"}]} =
             StationTaskSessions.of_task(r.group_id, r.conversation_id)
  end

  test "a refused invitation cannot replace its carrier until its stop is confirmed", %{
    reservation: r
  } do
    SystemsRuntime.put_env(:salix_web, :coding_invite_result, {:error, "model unavailable"})
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :coding_invite_result) end)
    :ok = CodingSandboxes.reserve(r)
    before = due!(r)
    Answers.push("STOP", 503, %{"error" => "unknown delete"})
    connect!(r)
    assert workload(r).spec["state"] == "failed"
    refute workload(r).spec["leftover"] == []
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == before.generation
    due!(r)
    assert workload(r).spec["leftover"] == []
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == before.generation + 1
  end

  test "a Task in review stops its sandbox once its Session is idle for 3 minutes, its work pushed first",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)

    # Still finishing its turn: the sandbox stays.
    Station.status(%{"state" => "running", "pending" => 0, "for_ms" => 0})
    Task.set_status("ready_for_review")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "ready_for_review")
    CodingSandboxes.check_due()
    assert workload(r).spec["state"] == "ready"
    refute_received {:l4es, "STOP", _, _, _}

    # Idle for a moment: it stays for a follow-up, checked again when 3 minutes are up.
    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 1_000, "unpushed" => true})
    checked = due!(r)
    assert checked.spec["state"] == "ready"
    {:ok, at, 0} = DateTime.from_iso8601(checked.spec["next_check_at"])
    assert_in_delta DateTime.diff(at, SystemsClock.utc_now(), :millisecond), 179_000, 5_000
    refute_received {:l4es, "STOP", _, _, _}

    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 180_000, "unpushed" => true})
    assert due!(r).spec["state"] == "stopped"
    assert_received {:asked, "task.save", %{"task" => "cnv_code"}}
    assert_received {:l4es, "STOP", _, _, _}

    # A reply starts it again from its disk.
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == 2
  end

  test "a turn its Session ends leaves its token use, change totals and pull request for the Task's panel",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    refute workload(r).spec["facts"]

    view = %{tenant_id: r.tenant_id, group_id: r.group_id, device_id: r.device_id}

    assert {:ok, %{"seq" => _}} =
             SalixWeb.StationTasks.post(view, %{
               "task" => "cnv_code",
               "session" => "ember:c-1",
               "text" => "Made the API faster.",
               "key" => "k1",
               "declared" => "all_done"
             })

    facts = settle_until(fn -> workload(r).spec["facts"] end)
    # The token use comes with any history page: a page of one entry is asked for.
    assert_received {:asked, "task.history", %{"limit" => 1, "task" => "cnv_code"}}
    assert facts["usage"]["value"]["modelCalls"] == 36
    assert facts["changes"]["value"] == %{"files" => 2, "additions" => 2_676, "deletions" => 996}

    assert %{"number" => 7, "state" => "open", "checks" => %{"passed" => 98}} =
             facts["pull_request"]["value"]

    # Its description is the pull request's own to show: it is not kept.
    refute Map.has_key?(facts["pull_request"]["value"], "body")
  end

  test "what a read keeps stays until a read that started later keeps its own", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    later = SystemsClock.utc_now()
    earlier = DateTime.add(later, -1, :second)
    totals = fn files -> %{"files" => files, "additions" => 10 * files, "deletions" => files} end

    :ok =
      CodingSandboxes.remember(r.tenant_id, "cnv_code", %{"changes" => {:ok, totals.(3)}}, later)

    # A read that started first answers last: what the later one kept stays. A part
    # it did not read is not kept; a pull request it read as none is.
    :ok =
      CodingSandboxes.remember(
        r.tenant_id,
        "cnv_code",
        %{"changes" => {:ok, totals.(1)}, "usage" => :error, "pull_request" => {:ok, nil}},
        earlier
      )

    facts = workload(r).spec["facts"]
    assert facts["changes"]["value"] == totals.(3)
    refute Map.has_key?(facts, "usage")
    assert facts["pull_request"] == %{"at" => DateTime.to_iso8601(earlier), "value" => nil}
  end

  test "a history page that says no token use leaves the kept one", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    at = SystemsClock.utc_now()
    usage = %{"modelCalls" => 2, "inputTokens" => 10, "cachedTokens" => 0, "outputTokens" => 1}

    :ok =
      CodingSandboxes.remember(
        r.tenant_id,
        "cnv_code",
        %{"usage" => CodingSandboxes.usage_part(%{"usage" => usage})},
        at
      )

    :ok =
      CodingSandboxes.remember(
        r.tenant_id,
        "cnv_code",
        %{"usage" => CodingSandboxes.usage_part(%{"entries" => []})},
        DateTime.add(at, 1, :second)
      )

    assert workload(r).spec["facts"]["usage"]["value"] == usage

    # A page that says the Session made no model calls is kept as that.
    :ok =
      CodingSandboxes.remember(
        r.tenant_id,
        "cnv_code",
        %{"usage" => CodingSandboxes.usage_part(%{"usage" => nil})},
        DateTime.add(at, 2, :second)
      )

    assert workload(r).spec["facts"]["usage"]["value"] == nil
  end

  test "a sandbox of a Task that ended without its sandbox knowing stops once idle",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    Task.set_status("completed")
    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 180_000})
    assert due!(r).spec["state"] == "stopped"
    assert_received {:l4es, "STOP", _, _, _}
  end

  test "an idle sandbox is shut down after 2 hours if its work is pushed, and saved first if not",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    hours = &(&1 * 3_600_000)

    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => hours.(1)})
    assert due!(r).spec["state"] == "ready"
    refute_received {:l4es, "STOP", _, _, _}

    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => hours.(3), "dirty" => true})
    assert due!(r).spec["state"] == "ready"
    assert_received {:asked, "task.save", %{"task" => "cnv_code"}}

    Station.status(%{
      "state" => "idle",
      "pending" => 0,
      "for_ms" => hours.(3),
      "dirty" => false,
      "unpushed" => false
    })

    assert due!(r).spec["state"] == "stopped"
    assert_received {:l4es, "STOP", _, _, _}
  end

  test "after 24 hours idle it is shut down whatever it holds, and the Task says what was lost",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)

    Station.status(%{
      "state" => "idle",
      "pending" => 0,
      "for_ms" => 25 * 3_600_000,
      "unpushed" => true
    })

    assert due!(r).spec["state"] == "stopped"
    assert [%{"content" => text}] = Task.messages()
    assert text =~ "commits that were not pushed"
  end

  defp stopped!(r) do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 3 * 3_600_000})
    assert due!(r).spec["state"] == "stopped"
    assert_received {:l4es, "POST", _, _, _}
    assert_received {:l4es, "STOP", _, _, _}
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
  end

  test "a Task with work for its stopped sandbox starts the same sandbox from its disk, as the next generation",
       %{reservation: r} do
    stopped!(r)
    w = due!(r)
    assert w.generation == 2
    name = CodingSandboxes.sandbox_name("cnv_code", 1)
    assert_received {:l4es, "POST", _, _, %{"name" => ^name, "secrets" => secrets}}
    assert w.spec["sandbox"] == name
    assert w.spec["created"] == true

    # Its station connects with this generation's credential only.
    assert {:ok, %{generation: 2}} =
             WorkloadCredential.verify_connect(secrets["SALIX_WORKLOAD_CREDENTIAL"])

    assert w.spec["invited"] == true
  end

  test "a sandbox still stopping is waited for, its disk kept, and started once it stopped",
       %{reservation: r} do
    stopped!(r)
    sandbox = sandbox_path(r)
    Answers.push("POST", 409, %{"error" => "The sandbox is still stopping."})
    Answers.push({"GET", sandbox}, 200, %{"state" => "stopping"})
    Answers.push({"GET", sandbox}, 200, %{"state" => "stopping"})
    w = due!(r)
    assert w.spec["state"] == "starting"
    assert w.spec["created"] == false
    refute_received {:l4es, "DELETE", _, _, _}

    w = due!(r)
    assert_received {:l4es, "POST", _, _, _}
    assert_received {:l4es, "POST", _, _, _}
    assert w.spec["created"] == true
  end

  test "a sandbox L4ES refuses to start as asked is deleted with its disk and made again",
       %{reservation: r} do
    stopped!(r)
    name = CodingSandboxes.sandbox_name("cnv_code", 1)
    Answers.push("POST", 409, %{"error" => "disk_gib is fixed for this sandbox."})
    Answers.push({"GET", sandbox_path(r)}, 200, %{"state" => "stopped"})
    w = due!(r)
    assert_received {:l4es, "DELETE", path, _, _}
    assert path =~ name
    assert w.spec["state"] == "starting"
    assert w.spec["created"] == false

    # Made again by the same name, on a new disk.
    w = due!(r)
    assert_received {:l4es, "POST", _, _, %{"name" => ^name}}
    assert_received {:l4es, "POST", _, _, %{"name" => ^name}}
    assert w.spec["sandbox"] == name
    assert w.spec["created"] == true
  end

  test "a ready sandbox that L4ES stopped is lost", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    Answers.push({"GET", sandbox_path(r)}, 200, %{"state" => "stopped"})
    assert due!(r).spec["state"] == "lost"
  end

  test "a sandbox L4ES did not stop when its Task ended is stopped at the next checks",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    name = due!(r).spec["sandbox"]
    Answers.push("STOP", 503, %{"error" => "unavailable"})
    Task.set_status("completed")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "completed")
    CodingSandboxes.check_due()

    w = workload(r)
    assert w.spec["state"] == "ended"
    assert w.spec["leftover"] == [name]
    assert w.spec["next_check_at"]
    assert_received {:l4es, "STOP", _, _, _}

    w = due!(r)
    assert_received {:l4es, "STOP", path, _, _}
    assert path =~ name
    assert w.spec["leftover"] == []
    assert w.spec["next_check_at"] == nil
  end

  test "a create that was not answered is asked again by its name", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    name = CodingSandboxes.sandbox_name("cnv_code", 1)
    Answers.push("POST", 503, %{"error" => "unavailable"})

    # Its name is kept before the create is asked, so it is not lost.
    w = due!(r)
    assert w.spec["sandbox"] == name
    assert w.spec["created"] == false

    # Asked again: L4ES answers the sandbox it made, if it made it.
    w = due!(r)
    assert_received {:l4es, "POST", _, _, %{"name" => ^name}}
    assert_received {:l4es, "POST", _, _, %{"name" => ^name}}
    assert w.spec["created"] == true
    assert w.spec["state"] == "starting"
  end

  test "a Task status it has already left does not end its sandbox", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    # A recovered publication of an earlier `failed`, after a message reopened the Task.
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "failed")
    CodingSandboxes.check_due()
    assert workload(r).spec["state"] == "starting"
    refute workload(r).spec["end"]
  end

  test "an ended Task gives up its sandbox", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    Task.set_status("completed")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "completed")
    CodingSandboxes.check_due()
    assert workload(r).spec["state"] == "ended"
    assert_received {:l4es, "STOP", _, _, _}

    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "active")
    assert workload(r).spec["state"] == "ended"
  end

  test "a sandbox that does not connect within 5 minutes fails, and the Task says so",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    SystemsClock.advance(301_000)
    assert due!(r).spec["state"] == "failed"
    assert_received {:l4es, "STOP", _, _, _}

    assert [
             %{
               "content" =>
                 "The coding sandbox could not run: the sandbox did not start within 5 minutes" <>
                   _
             }
           ] =
             Task.messages()
  end

  test "a token that expires is replaced in L4ES shortly before it does", %{reservation: r} do
    expires = SystemsClock.system_time(:millisecond) + 180_000
    SystemsRuntime.put_env(:salix_web, :coding_test_github_token, {"ghu_group_token", expires})
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)

    path =
      "/api/workspaces/comma:#{r.group_id}/sandboxes/#{workload(r).spec["sandbox"]}/github_token"

    # Not due yet: the next check is when it is, before the usual 5 minutes.
    w = due!(r)
    refute_received {:l4es, "PUT", _, _, _}
    {:ok, at, _} = DateTime.from_iso8601(w.spec["next_check_at"])
    assert DateTime.to_unix(at, :millisecond) == expires - 45_000

    # Then the credential store has the next token, and L4ES gets it.
    later = expires + :timer.hours(8)
    SystemsRuntime.put_env(:salix_web, :coding_test_github_token, {"ghu_next", later})
    SystemsClock.advance(135_000)
    CodingSandboxes.check_due()
    assert_received {:l4es, "PUT", ^path, _, %{"token" => "ghu_next"}}
    assert workload(r).spec["github_expires_at"] == later
  end

  test "without L4ES no sandbox is reserved", %{reservation: r} do
    SystemsRuntime.delete_env(:salix_web, :l4es)
    assert {:error, :sandbox_unavailable} = CodingSandboxes.reserve(r)
  end
end
