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

  import ExUnit.CaptureLog

  alias SalixEnv.Registry
  alias SalixStore.CodingSandboxes, as: Store
  alias SalixStore.{Compute.WorkloadCredential, StationTaskSessions}
  alias SalixWeb.{CodingSandboxes, StationTasks}
  alias SalixWeb.Migrations.LostSandboxNotices

  @start [:salix_web, :sandbox, :start]
  @end_event [:salix_web, :sandbox, :end]
  @records [:salix_web, :sandbox, :fleet, :records]
  @oldest_starting [:salix_web, :sandbox, :fleet, :oldest_starting]

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

  defmodule NoGitHub do
    @moduledoc "The Group's GitHub, with no account connected."
    def token(_tenant, _group), do: {:error, :github_not_connected}
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

  defmodule Billing do
    @moduledoc "A fee control that refuses every VM start, and keeps what it was asked."
    def authorize_vm(attrs) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :coding_test_pid),
        {:authorized, attrs}
      )

      {:error,
       {:billing_unavailable,
        %BillingCore.FeeControl.Decision{reason: "insufficient_credits", allowed?: false}}}
    end
  end

  defmodule BillingOutage do
    @moduledoc "A fee control that does not answer."
    def authorize_vm(_attrs), do: {:error, :timeout}
  end

  defmodule Metering do
    @moduledoc "A meter that keeps each interval it is given."
    def meter_vm_interval(attrs) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :coding_test_pid),
        {:metered, attrs}
      )

      {:ok, :metered}
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

    def refuse_appends(reason),
      do: SystemsRuntime.Agent.update(__MODULE__, &Map.put(&1, :refuse, reason))

    def owner(_group, _conversation), do: {:ok, "usr_owner"}

    def status(_group, _conversation) do
      case SystemsRuntime.Agent.get(__MODULE__, &Map.get(&1, :unreadable)) do
        nil ->
          status = SystemsRuntime.Agent.get(__MODULE__, & &1.status)

          case SystemsRuntime.Agent.get_and_update(__MODULE__, &Map.pop(&1, :after_status)) do
            nil -> :ok
            fun -> fun.()
          end

          {:ok, status}

        reason ->
          {:error, reason}
      end
    end

    def after_next_status(fun),
      do: SystemsRuntime.Agent.update(__MODULE__, &Map.put(&1, :after_status, fun))

    # As the store: one Message per `client_request_id`.
    def append(_group, _conversation, _agent, attrs) do
      SystemsRuntime.Agent.get_and_update(__MODULE__, fn state ->
        case Enum.find(state.messages, &(&1["client_request_id"] == attrs["client_request_id"])) do
          nil when is_map_key(state, :refuse) ->
            {{:error, state.refuse}, state}

          nil ->
            message = Map.put(attrs, "seq", length(state.messages) + 1)
            {{:ok, message}, %{state | messages: state.messages ++ [message]}}

          message ->
            {{:ok, message}, state}
        end
      end)
    end

    def messages_after(_group, _conversation, after_seq, limit),
      do: {:ok, messages() |> Enum.filter(&(&1["seq"] > after_seq)) |> Enum.take(limit)}

    def recent(_group, _conversation, limit) do
      case SystemsRuntime.Agent.get(__MODULE__, &Map.get(&1, :unreadable)) do
        nil -> {:ok, messages() |> Enum.reverse() |> Enum.take(limit)}
        reason -> {:error, reason}
      end
    end

    def unreadable(reason),
      do: SystemsRuntime.Agent.update(__MODULE__, &Map.put(&1, :unreadable, reason))

    def readable, do: SystemsRuntime.Agent.update(__MODULE__, &Map.delete(&1, :unreadable))

    def last(_group, _conversation) do
      case List.last(messages()) do
        nil -> {:error, :not_found}
        message -> {:ok, message}
      end
    end

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
    SalixWeb.TestSupport.CodingSandboxes.park_left!()

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
            :coding_members,
            :vm_authorization_mod
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
        # As L4ES answers: 201 for a sandbox made now, 200 for one that
        # exists (a stopped one started again from its disk).
        status =
          if body["name"] && String.ends_with?(conn.request_path, "/sandboxes") do
            path = conn.request_path <> "/" <> body["name"]
            existed? = Answers.sandbox(path) != nil
            Answers.save_sandbox(path, body)
            if existed?, do: 200, else: 201
          else
            201
          end

        Req.Test.json(Plug.Conn.put_status(conn, status), %{"state" => "scheduled"})

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

  # The sandbox metrics' events, sent to the test as they are emitted.
  defp watch_telemetry! do
    pid = SystemsRuntime.Proc.self()
    handler = "coding-sandboxes-test-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [@start, @end_event, @records, @oldest_starting],
        fn event, measurements, metadata, pid ->
          SystemsRuntime.Proc.send(pid, {:telemetry, event, measurements, metadata})
        end,
        pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp drain_telemetry do
    receive do
      {:telemetry, _, _, _} -> drain_telemetry()
    after
      0 -> :ok
    end
  end

  defp due!(r) do
    w = workload(r)
    {:ok, _} = Store.update(w.id, fn w -> {:ok, Map.put(w.spec, "next_check_at", "0")} end)
    CodingSandboxes.check_due()
    workload(r)
  end

  # The sandbox's station connects; with `task_models`, it says which models it runs per runtime.
  defp connect!(r, task_models \\ nil) do
    transport = Store.transport_id(r.conversation_id)

    meta = %{
      "tenant_id" => r.tenant_id,
      "group_id" => r.group_id,
      "device_id" => r.device_id,
      "connector_id" => Store.connector_id(r.conversation_id),
      "workload_id" => workload(r).id,
      "workload_generation" => workload(r).generation,
      "name" => "Coding sandbox"
    }

    meta =
      if task_models,
        do: Map.put(meta, "capabilities", %{"tasks" => 2, "task_models" => task_models}),
        else: meta

    {:ok, ^transport, record} = Registry.connect("test-node", meta, transport_id: transport)

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

  test "a Task without a repository gets a sandbox with no GitHub grant, token or git identity, and stops idle",
       %{reservation: r} do
    r = %{r | repo: nil, start: Map.delete(r.start, "repo")}
    # A GitHub account any ask would fail on: none is made.
    SystemsRuntime.put_env(:salix_web, :coding_test_github_token, {"ghu_unknown", nil})
    assert :ok = CodingSandboxes.reserve(r)
    w = due!(r)
    assert w.spec["state"] == "starting"
    path = "/api/workspaces/comma:#{r.group_id}/sandboxes"
    assert_received {:l4es, "POST", ^path, _, body}
    assert Map.keys(body["secrets"]) == ["SALIX_WORKLOAD_CREDENTIAL"]
    refute Map.has_key?(body, "github")
    refute Map.has_key?(body, "github_token")
    assert Map.keys(body["env"]) == ["SALIX_SERVER"]
    assert w.spec["repo"] == nil
    assert w.spec["github_expires_at"] == nil

    connect!(r)
    assert_received {:asked, "task.invite", %{"start" => start}}
    refute Map.has_key?(start, "repo")
    assert workload(r).spec["state"] == "ready"

    # Idle for 2 hours: stopped, with no repository work to report.
    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 3 * 3_600_000})
    due!(r)
    assert workload(r).spec["state"] == "stopped"
    assert Task.messages() == []
    refute_received {:l4es, "PUT", _, _, _}
  end

  test "a Router-created Task with runs_on sandbox and no repo gets a sandbox without GitHub",
       %{reservation: r} do
    {router, r} = router_task!(r)
    SystemsRuntime.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)
    SystemsRuntime.put_env(:salix_web, :coding_test_github_token, {"ghu_unknown", nil})

    assert {:ok, %{"conversation_id" => id}} =
             SalixIM.Provider.call_api(router, "internal", "internal.task.create", %{
               "connect_id" => "internal",
               "tool_call_id" => "create-plain-sandbox",
               "params" => %{
                 "content" => "Convert the videos to MP4.",
                 "agent_id" => r.agent_id,
                 "runs_on" => %{"kind" => "sandbox"}
               }
             })

    {:ok, task} = SalixIM.Conversations.get_group_conversation(r.group_id, id)
    assert task["runs_on"] == %{"kind" => "sandbox", "device_id" => Store.device_id(id)}
    refute task["repo"]
    created = %{r | conversation_id: id}
    w = due!(created)
    path = "/api/workspaces/comma:#{r.group_id}/sandboxes/#{w.spec["sandbox"]}"
    refute Map.has_key?(Answers.sandbox(path), "github")
    refute Map.has_key?(w.spec["start"], "repo")
  end

  test "a plain sandbox Task is switched to another runtime model on its sandbox: a new Session takes the old one's place",
       %{reservation: r} do
    {router, coding} = router_task!(r)
    SystemsRuntime.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)
    SystemsRuntime.put_env(:salix_web, :coding_test_github_token, {"ghu_unknown", nil})
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :coding_invite_result) end)

    assert {:ok, %{"conversation_id" => id}} =
             SalixIM.Provider.call_api(router, "internal", "internal.task.create", %{
               "connect_id" => "internal",
               "tool_call_id" => "create-plain-sandbox-switch",
               "params" => %{
                 "content" => "Convert the videos to MP4.",
                 "agent_id" => r.agent_id,
                 "runs_on" => %{"kind" => "sandbox"}
               }
             })

    r = %{r | conversation_id: id, device_id: Store.device_id(id)}
    due!(r)
    # Its station runs Claude Code alone, it says (`task_models`).
    connect!(r, %{"claude" => ["claude-opus-5-5"]})
    assert_received {:asked, "task.invite", %{"task" => ^id, "start" => first}}
    refute Map.has_key?(first, "replace")
    assert {:ok, [%{session: "ember:c-1"}]} = StationTaskSessions.of_task(r.group_id, id)

    switch = fn model ->
      SalixIM.TaskRun.switch(
        r.group_id,
        id,
        %{"runs_on" => %{"kind" => "sandbox"}, "model" => model},
        "usr_ann"
      )
    end

    # A model, or a runtime, its station has not said it runs is refused before the station is asked.
    assert {:error, {:placement, {:model, {:not_on_station, %{"claude" => _}}}}} =
             switch.(%{"kind" => "runtime", "provider" => "claude", "model" => "claude-nope"})

    assert {:error, {:placement, {:model, {:not_on_station, %{"claude" => _}}}}} =
             switch.(%{"kind" => "runtime", "provider" => "codex"})

    refute_received {:asked, "task.invite", _}

    SystemsRuntime.put_env(:salix_web, :coding_invite_result, {:ok, %{"session" => "ember:c-2"}})
    place = %{"kind" => "sandbox", "device_id" => r.device_id}
    assert {:ok, %{"runs_on" => ^place}} = switch.(%{"kind" => "runtime", "provider" => "claude"})

    # The same sandbox's station replaces its Session with one of the new model; no station leaves.
    assert_received {:asked, "task.invite",
                     %{
                       "task" => ^id,
                       "replace" => true,
                       "start" => %{"runtime" => "claude"} = start
                     }}

    refute Map.has_key?(start, "repo")
    refute_received {:asked, "task.leave", _}

    assert {:ok, [%{session: "ember:c-2", start: %{"runtime" => "claude"}}]} =
             StationTaskSessions.of_task(r.group_id, id)

    {:ok, task} = SalixIM.Conversations.get_group_conversation(r.group_id, id)
    assert task["runs_on"] == place
    {:ok, messages} = SalixIM.Conversations.list_group_conversation_messages(r.group_id, id)

    assert Enum.any?(
             messages,
             &(get_in(&1, ["metadata", "message_type"]) == SalixIM.TaskRun.message_type())
           )

    # Its sandbox's station gone, the Task takes no Session now: a Message to it starts the sandbox.
    {:ok, _device} = Registry.mark_disconnected(workload(r).spec["connector_run_id"])

    assert {:error, {:station, :sandbox_not_running}} =
             switch.(%{"kind" => "runtime", "provider" => "claude", "model" => "claude-opus-5-5"})

    refute_received {:asked, "task.invite", _}

    # A coding Task is not switched: its Session holds the checkout.
    assert {:error, {:bad_request, "a coding Task runs on its own sandbox" <> _}} =
             SalixIM.TaskRun.switch(
               coding.group_id,
               coding.conversation_id,
               %{
                 "runs_on" => %{"kind" => "sandbox"},
                 "model" => %{"kind" => "runtime", "provider" => "claude"}
               },
               "usr_ann"
             )
  end

  test "a Worker in its Task creates sandbox Tasks for machine work, delegated to the Router, whose results go to the Task's own parent; such a Task creates none",
       %{reservation: r} do
    {router, r} = router_task!(r)
    SystemsRuntime.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)
    SystemsRuntime.put_env(:salix_web, :coding_test_github_token, {"ghu_unknown", nil})

    # The Cloud VM is retired here: a Worker's machine work goes to a sandbox Task.
    sandboxes_mod = SystemsRuntime.get_env(:salix_agent, :sandboxes_mod)
    SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, SalixWeb.L4ES)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_retired, true)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_agent, :cloud_vm_retired)

      if sandboxes_mod,
        do: SystemsRuntime.put_env(:salix_agent, :sandboxes_mod, sandboxes_mod),
        else: SystemsRuntime.delete_env(:salix_agent, :sandboxes_mod)
    end)

    # The conversation the user asked in, and the Router's Task made from it,
    # inside Salix, with this Worker (as `SalixIM.Provider.Internal` makes it
    # from a trusted origin).
    {:ok, %{"conversation_id" => home}} =
      SalixIM.ConversationServer.create_group_conversation(r.group_id, %{
        "kind" => "agent_task",
        "title" => "Where the user asked"
      })

    command = "Summarize the videos in /inbox."

    parent_attrs = %{
      "content" => command,
      "client_request_id" => "create-parent",
      "schedule" => %{"schedule_id" => nil, "command" => command},
      "source_refs" => %{"parent_conversation_id" => home, "origin_agent_id" => router},
      "initial_message_attrs" => %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => router,
        "content" => command,
        "metadata" => %{"message_type" => "task_command"},
        "client_request_id" => "delegate-create-parent"
      }
    }

    {:ok, parent} =
      SalixIM.ConversationServer.reserve_task_conversation_id(
        r.group_id,
        router,
        r.agent_id,
        parent_attrs
      )

    {:ok, %{"conversation_id" => ^parent}} =
      SalixIM.TaskConversationInput.create_with_id(
        r.group_id,
        parent,
        router,
        r.agent_id,
        parent_attrs
      )

    create = fn agent, params, task ->
      SalixIM.Provider.call_api(agent, "internal", "internal.task.create", %{
        "connect_id" => "internal",
        "tool_call_id" =>
          "worker-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
        "params" => params,
        "tool_context" => %{"task_conversation_id" => task}
      })
    end

    machine_work = %{
      "content" => "Convert the videos to MP4.",
      "runs_on" => %{"kind" => "sandbox"}
    }

    # The Worker's Task: a sandbox of its own, its parent the conversation the
    # Worker's Task came from (where the Router delivers its result), the
    # Worker's Task its origin, the Router its delegator.
    assert {:ok, %{"conversation_id" => child}} = create.(r.agent_id, machine_work, parent)
    {:ok, task} = SalixIM.Conversations.get_group_conversation(r.group_id, child)
    assert task["runs_on"] == %{"kind" => "sandbox", "device_id" => Store.device_id(child)}
    assert task["source_refs"]["parent_conversation_id"] == home
    assert task["source_refs"]["origin_task_conversation_id"] == parent
    assert task["source_refs"]["origin_agent_id"] == r.agent_id

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(r.group_id, child)

    assert Enum.any?(
             participants,
             &(&1["agent_id"] == router and &1["role_label"] == "delegator")
           )

    [child_worker] =
      for %{"role_label" => "worker", "agent_id" => id} <- participants, do: id

    # Two levels: the Worker's Task creates none.
    assert {:error, "task_depth: " <> _} = create.(child_worker, machine_work, child)

    # Only a plain sandbox Task, from within the Worker's own Task.
    assert {:error, refusal} =
             create.(r.agent_id, %{machine_work | "runs_on" => %{"kind" => "salix"}}, parent)

    assert refusal =~ "runs in a sandbox"

    assert {:error, refusal} = create.(r.agent_id, Map.put(machine_work, "loop", %{}), parent)
    assert refusal =~ "not loop"

    assert {:error, "a Worker creates a Task only from within its own Task"} =
             create.(r.agent_id, machine_work, SalixStore.Ids.new_conversation_id())

    assert {:error, "a Worker creates a Task only from within its own Task"} =
             create.(r.agent_id, machine_work, nil)

    # Where the Cloud VM is not retired, a Worker creates no Task: env.exec reaches the Cloud VM.
    SystemsRuntime.delete_env(:salix_agent, :cloud_vm_retired)

    assert {:error, "a Worker creates no Task here: the Group's Cloud VM is not retired" <> _} =
             create.(r.agent_id, machine_work, parent)
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

  test "every create carries the configured node labels, [] when unconfigured",
       %{reservation: r} do
    group = r.group_id
    path = "/api/workspaces/comma:#{group}/sandboxes"

    :ok = CodingSandboxes.reserve(r)
    due!(r)
    assert_received {:l4es, "POST", ^path, _, body}
    assert body["labels"] == []

    config = SystemsRuntime.get_env(:salix_web, :l4es)
    SystemsRuntime.put_env(:salix_web, :l4es, Keyword.put(config, :labels, ["metal"]))
    other = %{r | conversation_id: "cnv_other", device_id: Store.device_id("cnv_other")}
    :ok = CodingSandboxes.reserve(other)
    due!(other)
    assert_received {:l4es, "POST", ^path, _, body}
    assert body["labels"] == ["metal"]
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

  test "an image removed in L4ES since this node remembered it is added again, and the Task does not fail",
       %{reservation: r} do
    manifest =
      "https://cue-release.test/coding-sandbox/inputs/#{SystemsRuntime.Proc.unique_integer([:positive])}.json"

    config = SystemsRuntime.get_env(:salix_web, :l4es)
    SystemsRuntime.put_env(:salix_web, :l4es, Keyword.put(config, :image_manifest, manifest))
    sha = String.duplicate("12", 32)
    name = "comma-" <> String.slice(sha, 0, 12)
    images = "/api/workspaces/comma:#{r.group_id}/images"
    sandboxes = "/api/workspaces/comma:#{r.group_id}/sandboxes"

    verity = %{
      "root_hash" => String.duplicate("cd", 32),
      "salt" => String.duplicate("ef", 32),
      "data_blocks" => 6
    }

    Answers.push({"GET", URI.parse(manifest).path}, 200, %{
      "rootfs_sha256" => sha,
      "verity" => verity
    })

    # This node added the image lately; another release's node removed it since.
    SalixWeb.L4ESRecent.remember({:image, r.group_id, sha}, name)
    :ok = CodingSandboxes.reserve(r)
    Answers.push({"POST", sandboxes}, 400, %{"error" => "There is no image #{name}."})
    w = due!(r)
    assert_received {:l4es, "POST", ^sandboxes, _, %{"image" => ^name}}
    refute_received {:l4es, "GET", ^images, _, _}
    assert w.spec["state"] == "starting"
    assert w.spec["reason"] =~ "There is no image"
    assert Task.messages() == []

    # The next create asks L4ES again, adds the image and makes the sandbox.
    Answers.push({"GET", images}, 200, %{"images" => []})
    w = due!(r)
    assert_received {:l4es, "GET", ^images, _, _}
    assert_received {:l4es, "POST", ^images, _, %{"name" => ^name, "sha256" => ^sha}}
    assert_received {:l4es, "POST", ^sandboxes, _, %{"image" => ^name}}
    assert w.spec["created"] == true
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

  test "a delayed old connector initialization cannot mark its replacement ready, and is logged",
       %{reservation: r} do
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

    # The one trace of a station that connected without readying its Workload.
    log = capture_log(fn -> :ok = CodingSandboxes.connected(old) end)
    assert log =~ "station connected but its Workload was not marked ready"
    assert log =~
             "tenant=#{r.tenant_id} device=#{r.device_id} workload=#{w.id} generation=#{w.generation} run=old-run"

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
    reply!(r)
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == before.generation + 1
  end

  test "a Task in review stops its sandbox after 3 idle minutes and reports work left on its disk",
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
    assert_received {:l4es, "STOP", _, _, _}
    assert [%{"content" => text}] = Task.messages()
    assert text =~ "commits that were not pushed"
    assert text =~ "They stay on its disk"

    # A reply starts it again from its disk.
    reply!(r)
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

  test "an idle sandbox stops after 2 hours with uncommitted and unpushed work left on its disk",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    hours = &(&1 * 3_600_000)

    Station.status(%{
      "state" => "idle",
      "pending" => 0,
      "for_ms" => hours.(1),
      "dirty" => true,
      "unpushed" => true
    })

    assert due!(r).spec["state"] == "ready"
    refute_received {:l4es, "STOP", _, _, _}

    Station.status(%{
      "state" => "idle",
      "pending" => 0,
      "for_ms" => hours.(2),
      "dirty" => true,
      "unpushed" => true
    })

    assert due!(r).spec["state"] == "stopped"
    assert_received {:l4es, "STOP", _, _, _}
    assert [%{"content" => text}] = Task.messages()
    assert text =~ "uncommitted changes and commits that were not pushed"
    assert text =~ "They stay on its disk"
  end

  test "an idle sandbox with published work stops after 2 hours without a local-work notice",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)

    Station.status(%{
      "state" => "idle",
      "pending" => 0,
      "for_ms" => 2 * 3_600_000,
      "dirty" => false,
      "unpushed" => false
    })

    assert due!(r).spec["state"] == "stopped"
    assert_received {:l4es, "STOP", _, _, _}
    assert Task.messages() == []
  end

  # The sandbox is made, connects, and is stopped as idle: the Workload stopped.
  defp idle_stopped!(r) do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 3 * 3_600_000})
    stopped = due!(r)
    assert stopped.spec["state"] == "stopped"
    assert_received {:l4es, "POST", _, _, _}
    assert_received {:l4es, "STOP", _, _, _}
    stopped
  end

  defp stopped!(r) do
    idle_stopped!(r)
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
  end

  # A person replies in the Task: the Message after what Salix last said in it.
  defp reply!(r, text \\ "Try again") do
    {:ok, _} =
      Task.append(r.group_id, r.conversation_id, nil, %{
        "kind" => "message",
        "actor_type" => "user",
        "user_id" => "usr_owner",
        "content" => text,
        "client_request_id" => "reply-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      })

    :ok
  end

  test "a stopped sandbox whose Workspace cannot pay stays stopped, and its Task is told once",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 3 * 3_600_000})
    stopped = due!(r)
    assert stopped.spec["state"] == "stopped"
    assert Task.messages() == []

    {:ok, _} =
      Salix.Control.Groups.update(
        r.group_id,
        %{"billing_owner" => %{"billing_account_id" => "ba_sandbox", "surface" => "comma"}},
        r.tenant_id
      )

    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, Billing)

    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == stopped.generation
    assert workload(r).spec["state"] == "stopped"
    assert [%{"content" => text}] = Task.messages()
    assert text =~ "The sandbox cannot start: Not enough credits"
    # The sku authorized is the one this sandbox is metered on.
    assert_received {:authorized, %{sku: "sandbox-" <> _, provider: "l4es", action: :start}}

    # A fee control that does not answer leaves it stopped too, and says so once.
    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, BillingOutage)
    reply!(r)
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == stopped.generation
    assert [_, _, %{"content" => outage}] = Task.messages()
    assert outage =~ "billing is temporarily unavailable"

    # Credits added, and a reply: the next wake starts it again.
    SystemsRuntime.delete_env(:salix_web, :vm_authorization_mod)
    reply!(r)
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == stopped.generation + 1
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

  test "a woken sandbox's run is timed from its station's connection and metered when it stops, as the first was",
       %{reservation: r} do
    SystemsRuntime.put_env(:salix_web, :vm_metering_mod, Metering)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :vm_metering_mod) end)

    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    SystemsClock.advance(60_000)
    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 3 * 3_600_000})
    assert due!(r).spec["state"] == "stopped"
    assert_received {:metered, %{source_key: "vm:l4es:" <> first, duration_seconds: 60}}
    assert String.contains?(first, ":1:")
    assert workload(r).spec["ready_at"] == nil

    # The next generation, started from its disk: its station's connection
    # sets the run's ready time again, and its stop meters this run.
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    due!(r)
    SystemsClock.advance(5_000)
    connect!(r)
    woken = workload(r)
    assert woken.generation == 2
    assert is_integer(woken.spec["ready_at"])

    SystemsClock.advance(90_000)
    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 3 * 3_600_000})
    assert due!(r).spec["state"] == "stopped"

    assert_received {:metered, %{source_key: "vm:l4es:" <> second, duration_seconds: seconds}}
    assert String.contains?(second, ":2:")
    assert seconds == 90
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

  test "a woken sandbox still pending on its disk after 150 s is made again on a new disk, and the Task is told",
       %{reservation: r} do
    stopped!(r)
    name = CodingSandboxes.sandbox_name("cnv_code", 1)
    sandbox = sandbox_path(r)
    # The node that holds its disk is draining: L4ES accepts the start and
    # holds the sandbox for that node for 900 s, longer than the start budget.
    pinned = %{"state" => "pending", "data_status" => "retained"}
    for _ <- 1..6, do: Answers.push({"GET", sandbox}, 200, pinned)
    w = due!(r)
    assert_received {:l4es, "POST", _, _, %{"name" => ^name}}
    assert w.spec["created"] == true

    # Within L4ES's own 120 s failover grace, the sandbox is left to it.
    for _ <- 1..4 do
      SystemsClock.advance(30_000)
      assert due!(r).spec["created"] == true
    end

    refute_received {:l4es, "DELETE", _, _, _}
    assert Task.messages() == []

    SystemsClock.advance(30_000)
    w = due!(r)
    assert_received {:l4es, "DELETE", path, _, _}
    assert path =~ name
    assert w.spec["state"] == "starting"
    assert w.spec["created"] == false
    assert w.spec["reason"] =~ "no node took it within 150 s"
    assert is_binary(w.spec["remade_at"])
    assert [%{"content" => told}] = Task.messages()
    assert told =~ "made again on a new disk"
    assert told =~ "unpushed commits"

    # The draining node has not confirmed the destroy yet: the name is still
    # stopping, so the create is retried, without a second delete.
    Answers.push("POST", 409, %{"error" => "The sandbox is still stopping."})
    for _ <- 1..2, do: Answers.push({"GET", sandbox}, 200, %{"state" => "deleting"})
    SystemsClock.advance(30_000)
    w = due!(r)
    assert w.spec["created"] == false
    refute_received {:l4es, "DELETE", _, _, _}

    # Made again by its name, a new sandbox that any node takes. Its start
    # budget runs from the remake: 330 s after the wake it is still starting.
    SystemsClock.advance(30_000)
    w = due!(r)
    assert_received {:l4es, "POST", _, _, %{"name" => ^name}}
    assert w.spec["created"] == true
    Answers.push({"GET", sandbox}, 200, %{"state" => "scheduled", "data_status" => "unknown"})
    SystemsClock.advance(120_000)
    w = due!(r)
    assert w.spec["state"] == "starting"
    refute_received {:l4es, "DELETE", _, _, _}
    connect!(r)
    assert workload(r).spec["state"] == "ready"
    assert length(Task.messages()) == 1
  end

  test "a woken sandbox whose delete L4ES refuses keeps its disk, and its Task is not told",
       %{reservation: r} do
    stopped!(r)
    sandbox = sandbox_path(r)
    pinned = %{"state" => "pending", "data_status" => "retained"}
    for _ <- 1..6, do: Answers.push({"GET", sandbox}, 200, pinned)
    Answers.push("DELETE", 503, %{"error" => "unavailable"})
    due!(r)

    for _ <- 1..5 do
      SystemsClock.advance(30_000)
      due!(r)
    end

    assert_received {:l4es, "DELETE", _, _, _}
    w = workload(r)
    assert w.spec["created"] == false
    assert w.spec["remade_at"] == nil
    assert Task.messages() == []

    # The create is asked again; the old sandbox answers it, from its disk.
    SystemsClock.advance(30_000)
    assert due!(r).spec["created"] == true
    assert Task.messages() == []
  end

  test "a woken sandbox whose node is dead is left to L4ES, which moves it within the start budget",
       %{reservation: r} do
    stopped!(r)
    sandbox = sandbox_path(r)
    # L4ES holds the sandbox for its dead node for 120 s, then another node
    # takes it with a new disk: Salix deletes nothing meanwhile.
    pinned = %{"state" => "pending", "data_status" => "retained"}
    for _ <- 1..5, do: Answers.push({"GET", sandbox}, 200, pinned)
    Answers.push({"GET", sandbox}, 200, %{"state" => "scheduled", "data_status" => "missing"})
    due!(r)

    for _ <- 1..5 do
      SystemsClock.advance(30_000)
      assert due!(r).spec["created"] == true
    end

    refute_received {:l4es, "DELETE", _, _, _}
    connect!(r)
    assert workload(r).spec["state"] == "ready"
    assert Task.messages() == []
  end

  test "a new sandbox still pending after 150 s waits for capacity within the start budget",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    sandbox = sandbox_path(r)
    Answers.push({"GET", sandbox}, 200, %{"state" => "pending", "data_status" => "unknown"})
    SystemsClock.advance(151_000)
    w = due!(r)
    assert w.spec["state"] == "starting"
    assert w.spec["created"] == true
    refute_received {:l4es, "DELETE", _, _, _}
  end

  # The Task ends with its sandbox up, as a Router completes it.
  defp ended!(r) do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    Task.set_status("completed")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "completed")
    ended = due!(r)
    assert ended.spec["state"] == "ended"
    ended
  end

  defp reopen!(r) do
    Task.set_status("active")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "active")
    due!(r)
  end

  defp system_message!(r, text) do
    {:ok, _} =
      Task.append(r.group_id, r.conversation_id, nil, %{
        "kind" => "app_event",
        "actor_type" => "system",
        "content" => text,
        "metadata" => %{"event_type" => "provider.status"},
        "client_request_id" => "system-#{text}"
      })

    :ok
  end

  defp worker_message!(r, content) do
    {:ok, _} =
      Task.append(r.group_id, r.conversation_id, nil, %{
        "actor_type" => "agent",
        "agent_id" => r.agent_id,
        "content" => content,
        "client_request_id" => "worker-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      })

    :ok
  end

  test "a Task reopened after a Message that the end stopped wakes its sandbox once",
       %{reservation: r} do
    ended = ended!(r)
    reply!(r, "One more thing")
    system_message!(r, "active")

    woken = reopen!(r)
    assert woken.generation == ended.generation + 1
    assert woken.spec["state"] == "starting"
    assert woken.spec["reopened"] == nil

    # The status published again finds the next generation on its way.
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "active")
    assert due!(r).generation == woken.generation
  end

  test "the status published to a Task's provider starts no sandbox", %{reservation: r} do
    ended = ended!(r)
    reply!(r, "Never reached the station")
    system_message!(r, "completed")

    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == ended.generation
    assert workload(r).spec["state"] == "ended"
  end

  test "a Message in a Task that ended wakes no sandbox: the Router answers it",
       %{reservation: r} do
    stopped = idle_stopped!(r)

    # The Router ends the Task and posts its last word right after: the Task's
    # actor publishes the status (`task_status/3`) and gives the stations the
    # Message (`appended/2`) before any check runs. A person's follow-up on the
    # ended Task asks for no sandbox either, whichever way it ended.
    for status <- ~w(completed cancelled failed archived) do
      Task.set_status(status)
      :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", status)
      worker_message!(r, "Done: the API is faster.")
      :ok = CodingSandboxes.appended(r.group_id, "cnv_code")
      assert workload(r).generation == stopped.generation
      reply!(r, "Thanks")
      :ok = CodingSandboxes.appended(r.group_id, "cnv_code")
      assert workload(r).generation == stopped.generation
    end

    CodingSandboxes.check_due()
    assert workload(r).spec["state"] == "ended"
    refute_received {:l4es, "POST", _, _, _}
    refute_received {:l4es, "STOP", _, _, _}
    refute Enum.any?(Task.messages(), &match?(%{"metadata" => %{"kind" => "sandbox_notice"}}, &1))
  end

  test "a Task that ends after a wake read its status ends the next generation before its sandbox is made",
       %{reservation: r} do
    stopped = idle_stopped!(r)

    # A person replies, and the Router ends the Task while the wake decides
    # the fee: the end marks the stopped generation, which the wake replaces.
    reply!(r, "One more thing")

    Task.after_next_status(fn ->
      Task.set_status("completed")
      :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "completed")
    end)

    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == stopped.generation + 1

    assert due!(r).spec["state"] == "ended"
    refute_received {:l4es, "POST", _, _, _}
    refute_received {:l4es, "STOP", _, _, _}
  end

  test "a woken sandbox whose Task cannot be read is kept: the next check reads it again",
       %{reservation: r} do
    stopped = idle_stopped!(r)
    reply!(r, "One more thing")

    # The Task's store does not answer: the wake is not held back by that,
    # and the generation it makes is not ended by it either.
    Task.unreadable(:timeout)
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == stopped.generation + 1

    held = due!(r)
    assert held.spec["state"] == "starting"
    assert held.spec["end"] == true
    assert held.spec["sandbox"] == nil
    assert held.spec["next_check_at"] != nil
    refute_received {:l4es, "POST", _, _, _}
    refute Enum.any?(Task.messages(), &match?(%{"metadata" => %{"kind" => "sandbox_notice"}}, &1))

    Task.readable()
    made = due!(r)
    assert made.spec["end"] == nil
    assert made.spec["state"] == "starting"
    assert made.spec["sandbox"] != nil
    assert_received {:l4es, "POST", _, _, _}
  end

  test "a woken sandbox whose Task cannot be read for 5 minutes fails, and the Task says so",
       %{reservation: r} do
    watch_telemetry!()
    stopped = idle_stopped!(r)
    drain_telemetry()
    reply!(r, "One more thing")
    Task.unreadable(:timeout)
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert due!(r).spec["state"] == "starting"

    SystemsClock.advance(301_000)
    failed = due!(r)
    assert failed.generation == stopped.generation + 1
    assert failed.spec["state"] == "failed"
    assert failed.spec["end"] == nil
    refute_received {:l4es, "POST", _, _, _}

    assert %{
             "metadata" => %{"kind" => "sandbox_notice"},
             "content" =>
               "The sandbox could not run: the Task's status was not read within 5 minutes. Reply to try again."
           } = List.last(Task.messages())

    # A wake given up on is a failed start; no sandbox was made, so none ended.
    assert_received {:telemetry, @start, %{duration: _}, %{kind: :wake, outcome: :failed}}
    refute_received {:telemetry, @end_event, _, _}
  end

  test "a stopped sandbox whose ended Task cannot be read is ended, not failed",
       %{reservation: r} do
    idle_stopped!(r)
    SystemsClock.advance(301_000)

    # The Task ends, and its status is then not read: the stopped generation
    # was not starting, so there is no start to give up on and no notice.
    Task.set_status("completed")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "completed")
    Task.unreadable(:timeout)
    CodingSandboxes.check_due()

    assert workload(r).spec["state"] == "ended"
    refute_received {:l4es, "POST", _, _, _}
    assert Task.messages() == []
  end

  test "a Task reopened with nothing unanswered starts nothing", %{reservation: r} do
    ended = ended!(r)
    assert reopen!(r).generation == ended.generation

    reply!(r)
    worker_message!(r, "Done")
    system_message!(r, "active")
    settled = reopen!(r)
    assert settled.generation == ended.generation
    assert settled.spec["state"] == "ended"
    assert settled.spec["reopened"] == nil
  end

  test "Salix's notice is no work for a reopened Task, and milestones are no answer",
       %{reservation: r} do
    ended = ended!(r)

    {:ok, _} =
      StationTasks.notice(r.group_id, "cnv_code", r.agent_id, "test", "The sandbox stopped.")

    assert reopen!(r).generation == ended.generation

    reply!(r)
    worker_message!(r, [%{"type" => "milestone", "title" => "Reading"}])
    assert reopen!(r).generation == ended.generation + 1
  end

  test "a Task that ends again before the check starts nothing", %{reservation: r} do
    ended = ended!(r)
    reply!(r)
    Task.set_status("active")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "active")
    Task.set_status("completed")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "completed")

    settled = due!(r)
    assert settled.generation == ended.generation
    assert settled.spec["state"] == "ended"
    assert settled.spec["reopened"] == nil
    refute_received {:authorized, _}
  end

  test "a Task that ends after the check read it active runs nothing", %{reservation: r} do
    ended = ended!(r)
    reply!(r)

    # The end finds the Workload still `ended`, so it marks nothing, and the
    # wake then makes the next generation.
    Task.after_next_status(fn ->
      Task.set_status("completed")
      :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "completed")
    end)

    woken = reopen!(r)
    assert woken.generation == ended.generation + 1
    assert woken.spec["state"] == "starting"
    assert woken.spec["sandbox"] == nil

    settled = due!(r)
    assert settled.generation == woken.generation
    assert settled.spec["state"] == "ended"
    assert settled.spec["sandbox"] == nil
  end

  test "a reopened Task that stays active goes on after the check of its end",
       %{reservation: r} do
    ended = ended!(r)
    reply!(r)
    woken = reopen!(r)
    assert woken.generation == ended.generation + 1
    assert due!(r).spec["end"] == nil
    assert due!(r).spec["state"] == "starting"
    assert workload(r).spec["sandbox"] != nil
  end

  test "a reopened Task that cannot be read starts nothing until it can", %{reservation: r} do
    ended = ended!(r)
    reply!(r)
    Task.unreadable(:timeout)

    held = reopen!(r)
    assert held.generation == ended.generation
    assert held.spec["reopened"] == true
    assert held.spec["next_check_at"] != nil

    Task.readable()
    assert due!(r).generation == ended.generation + 1
  end

  test "a reopened Task waits for the old run's stop before the next generation",
       %{reservation: r} do
    ended = ended!(r)
    reply!(r)
    {:ok, _} = Store.update(ended.id, &{:ok, Map.put(&1.spec, "leftover", ["t-old"])})
    Answers.push("STOP", 503, %{"error" => "unknown stop"})

    held = reopen!(r)
    assert held.generation == ended.generation
    assert held.spec["reopened"] == true
    assert held.spec["leftover"] == ["t-old"]
  end

  test "a refused start for a reopened Task stays as it is and tells the Task", %{reservation: r} do
    ended = ended!(r)
    reply!(r)

    {:ok, _} =
      Salix.Control.Groups.update(
        r.group_id,
        %{"billing_owner" => %{"billing_account_id" => "ba_sandbox", "surface" => "comma"}},
        r.tenant_id
      )

    SystemsRuntime.put_env(:salix_web, :vm_authorization_mod, Billing)

    refused = reopen!(r)
    assert refused.generation == ended.generation
    assert refused.spec["state"] == "ended"
    assert refused.spec["reopened"] == nil
    assert %{"metadata" => %{"kind" => "sandbox_notice"}} = List.last(Task.messages())
  end

  test "a ready sandbox that L4ES stopped is lost", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    Answers.push({"GET", sandbox_path(r)}, 200, %{"state" => "stopped"})
    assert due!(r).spec["state"] == "lost"
  end

  test "a ready sandbox whose station stays disconnected for 5 minutes fails, and the Task says so",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    run = workload(r).spec["connector_run_id"]
    {:ok, _} = Registry.heartbeat(run)
    {:ok, _device} = Registry.mark_disconnected(run)

    assert ready_after?(r, 299_000)
    refute ready_after?(r, 2_000)
    assert_received {:l4es, "STOP", _, _, _}

    assert [%{"content" => "The sandbox could not run: its station stopped answering" <> _}] =
             Task.messages()
  end

  test "a ready sandbox whose station keeps reconnecting but never answers a heartbeat fails",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    {:ok, _} = Registry.heartbeat(workload(r).spec["connector_run_id"])

    # Each connection is admitted and dropped 45 s later without a heartbeat.
    for _ <- 1..3 do
      {:ok, _} = Registry.mark_disconnected(workload(r).spec["connector_run_id"])
      SystemsClock.advance(45_000)
      connect!(r)
      assert ready_after?(r, 45_000)
    end

    assert ready_after?(r, 29_000)
    refute ready_after?(r, 2_000)
    assert_received {:l4es, "STOP", _, _, _}
  end

  test "a ready sandbox whose station answers heartbeats stays ready", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)

    for _ <- 1..10 do
      {:ok, _} = Registry.heartbeat(workload(r).spec["connector_run_id"])
      assert ready_after?(r, 60_000)
    end

    refute_received {:l4es, "STOP", _, _, _}
  end

  test "a ready sandbox whose station was never heard since rollout is counted from the first check",
       %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)

    # Connected before Salix recorded heartbeats: no `heartbeat_at` yet.
    assert ready_after?(r, 600_000)
    assert ready_after?(r, 299_000)
    refute ready_after?(r, 2_000)
    assert_received {:l4es, "STOP", _, _, _}
  end

  test "a ready sandbox whose station's device cannot be read keeps running", %{reservation: r} do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    {:ok, _} = Registry.heartbeat(workload(r).spec["connector_run_id"])

    key = SalixStore.Keys.ctl_group_device(r.tenant_id, r.group_id, r.device_id)
    :ok = SalixStore.S3.Fake.blackhole({:fail, 503, :get, key})
    on_exit(fn -> SalixStore.S3.Fake.clear_blackhole() end)

    log = capture_log(fn -> assert ready_after?(r, 301_000) end)
    assert log =~ "station liveness is unknown"
    assert workload(r).spec["unheard_at"] == nil
    refute_received {:l4es, "STOP", _, _, _}

    # Once the device reads again, its silence is known and the sandbox fails.
    :ok = SalixStore.S3.Fake.clear_blackhole()
    refute ready_after?(r, 0)
    assert_received {:l4es, "STOP", _, _, _}
  end

  # Advances the clock, runs the sandbox's check with L4ES saying it runs, and
  # says whether it is still ready.
  defp ready_after?(r, ms) do
    SystemsClock.advance(ms)
    Answers.push({"GET", sandbox_path(r)}, 200, %{"state" => "running"})
    due!(r).spec["state"] == "ready"
  end

  defp flush_asked do
    receive do
      {:asked, _, _} -> flush_asked()
    after
      0 -> :ok
    end
  end

  defp lost!(r) do
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    connect!(r)
    Answers.push({"GET", sandbox_path(r)}, 200, %{"state" => "stopped"})
    due!(r)
  end

  test "a lost sandbox tells its active Task once, keeps its disk and starts nothing",
       %{reservation: r} do
    lost = lost!(r)
    assert lost.spec["state"] == "lost"
    assert lost.spec["disk"]

    assert due!(r).spec["lost_notice"] == nil

    assert [
             %{
               "content" => notice,
               "agent_id" => agent_id,
               "metadata" => %{"kind" => "sandbox_notice"}
             }
           ] = Task.messages()

    assert agent_id == r.agent_id
    assert notice =~ "has not completed"
    assert notice =~ "nothing is run again on its own"

    # A station that cannot be given a Message asks for its sandbox: the
    # notice wakes none, and another check says nothing more.
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == lost.generation
    assert workload(r).spec["state"] == "lost"
    assert due!(r).spec["state"] == "lost"
    assert [_notice] = Task.messages()
  end

  test "a lost sandbox's notice that was not written is written at a later check; a reply wakes the sandbox",
       %{reservation: r} do
    Task.refuse_appends(:timeout)
    lost = lost!(r)
    assert lost.spec["state"] == "lost"

    assert due!(r).spec["lost_notice"] == true
    assert workload(r).spec["next_check_at"] != nil
    assert Task.messages() == []

    SystemsRuntime.Agent.update(Task, &Map.delete(&1, :refuse))
    assert due!(r).spec["lost_notice"] == nil
    assert [%{"metadata" => %{"kind" => "sandbox_notice"}}] = Task.messages()

    reply!(r)
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    assert workload(r).generation == lost.generation + 1
    assert workload(r).spec["state"] == "starting"
  end

  # A sandbox lost before its Task was told: no notice due, no check due.
  defp lost_long_ago!(r) do
    lost = lost!(r)

    {:ok, _} =
      Store.update(lost.id, fn w ->
        {:ok, w.spec |> Map.delete("lost_notice") |> Map.put("next_check_at", nil)}
      end)

    workload(r)
  end

  test "the pass tells an active Task of a sandbox lost long ago once, and starts nothing",
       %{reservation: r} do
    lost = lost_long_ago!(r)
    flush_asked()

    assert {:ok, _counts} = LostSandboxNotices.run()
    marked = workload(r)

    assert Map.delete(marked.spec, "lost_notice") |> Map.delete("next_check_at") ==
             Map.delete(lost.spec, "next_check_at")

    CodingSandboxes.check_due()
    assert [%{"metadata" => %{"kind" => "sandbox_notice"}}] = Task.messages()
    assert Task.status("", "") == {:ok, "active"}

    assert {:ok, _counts} = LostSandboxNotices.run()
    CodingSandboxes.check_due()
    assert [_notice] = Task.messages()

    assert workload(r).generation == lost.generation
    assert workload(r).spec["state"] == "lost"
    refute_received {:asked, _, _}
  end

  test "the pass tells no Task in review, and marks nothing but lost sandboxes",
       %{reservation: r} do
    lost_long_ago!(r)
    Task.set_status("ready_for_review")
    assert {:ok, _counts} = LostSandboxNotices.run()
    CodingSandboxes.check_due()
    assert Task.messages() == []

    {:ok, _} = Store.update(workload(r).id, &{:ok, Map.put(&1.spec, "state", "stopped")})
    assert {:ok, _counts} = LostSandboxNotices.run()
    assert workload(r).spec["lost_notice"] == nil
  end

  defp stored(id) do
    {:ok, w} = Store.get(id)
    w
  end

  # A second Task's sandbox, lost before its Task was told.
  defp other_lost!(r) do
    other = %{r | conversation_id: "cnv_other", device_id: Store.device_id("cnv_other")}
    :ok = CodingSandboxes.reserve(other)

    {:ok, _} =
      Store.update(workload(other).id, fn w ->
        {:ok, Map.merge(w.spec, %{"state" => "lost", "next_check_at" => nil})}
      end)

    workload(other)
  end

  test "the pass for one Workload tells its Task once and leaves another lost Workload alone",
       %{reservation: r} do
    lost = lost_long_ago!(r)
    other = other_lost!(r)
    target = [workload: lost.id, generation: lost.generation]

    assert {:ok, %{marked: 1, pages: 1, cursor: id, done: true}} = LostSandboxNotices.run(target)
    assert id == lost.id
    CodingSandboxes.check_due()
    assert [_notice] = Task.messages()

    assert {:ok, %{marked: 1}} = LostSandboxNotices.run(target)
    CodingSandboxes.check_due()
    assert [_notice] = Task.messages()

    untouched = stored(other.id)
    assert untouched.spec == other.spec
    assert untouched.generation == other.generation
  end

  test "the pass for one Workload refuses another generation or state and changes nothing",
       %{reservation: r} do
    lost = lost_long_ago!(r)

    assert {:error, :stale_generation} =
             LostSandboxNotices.run(workload: lost.id, generation: lost.generation + 1)

    assert workload(r).spec == lost.spec

    {:ok, _} = Store.update(lost.id, &{:ok, Map.put(&1.spec, "state", "stopped")})

    assert {:error, :not_lost} =
             LostSandboxNotices.run(workload: lost.id, generation: lost.generation)

    assert workload(r).spec["lost_notice"] == nil
  end

  test "the pass stops at its page budget and goes on from its cursor", %{reservation: r} do
    lost = lost_long_ago!(r)
    other = other_lost!(r)

    assert {:ok, %{marked: 1, pages: 1, cursor: cursor, done: false}} =
             LostSandboxNotices.run(page: 1, max_pages: 1)

    assert is_binary(cursor)

    assert {:ok, %{done: true}} = LostSandboxNotices.run(after: cursor, page: 1, max_pages: 1000)
    assert stored(lost.id).spec["lost_notice"] == true
    assert stored(other.id).spec["lost_notice"] == true
  end

  test "a lost sandbox of a Task in review says nothing: nobody waits on it", %{reservation: r} do
    Task.set_status("ready_for_review")
    assert lost!(r).spec["state"] == "lost"
    assert due!(r).spec["lost_notice"] == nil
    assert Task.messages() == []
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

  test "a sandbox's start is timed from its reservation to its station's connection, by generation, and the end of its run is counted",
       %{reservation: r} do
    watch_telemetry!()
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    SystemsClock.advance(12_000)
    connect!(r)
    assert_received {:telemetry, @start, %{duration: made}, %{kind: :create, outcome: :ok}}
    assert made >= 12_000
    # The same run connecting again is not another start.
    connect!(r)
    refute_received {:telemetry, @start, _, _}

    Station.status(%{"state" => "idle", "pending" => 0, "for_ms" => 3 * 3_600_000})
    assert due!(r).spec["state"] == "stopped"
    assert_received {:telemetry, @end_event, %{}, %{state: "stopped"}}

    # Started again for a Message: the next generation's start is a wake.
    :ok = CodingSandboxes.wake(r.group_id, r.device_id)
    due!(r)
    SystemsClock.advance(4_000)
    connect!(r)
    assert_received {:telemetry, @start, %{duration: woken}, %{kind: :wake, outcome: :ok}}
    assert woken >= 4_000 and woken < 12_000

    Task.set_status("completed")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "completed")
    CodingSandboxes.check_due()
    assert workload(r).spec["state"] == "ended"
    assert_received {:telemetry, @end_event, %{}, %{state: "ended"}}
    refute_received {:telemetry, @start, _, _}
  end

  test "the fleet gauges count sandboxes by state, and when the oldest started starting",
       %{reservation: r} do
    import Ecto.Query, only: [from: 2]

    # Earlier tests' sandboxes left in starting would be the oldest here.
    SalixStore.Repo.update_all(
      from(w in SalixStore.Compute.Workload,
        where: w.kind == ^Store.kind(),
        update: [set: [spec: fragment("jsonb_set(?, '{state}', '\"stopped\"')", w.spec)]]
      ),
      []
    )

    watch_telemetry!()
    :ok = CodingSandboxes.reserve(r)
    # The record keeps microseconds; the gauge has whole milliseconds.
    reserved_at = SystemsClock.system_time(:microsecond) / 1_000_000
    SystemsClock.advance(30_000)
    assert :ok = CodingSandboxes.FleetMetrics.emit()
    assert_received {:telemetry, @records, %{count: starting}, %{state: "starting"}}
    assert starting >= 1
    assert_received {:telemetry, @records, %{count: _}, %{state: "lost"}}
    assert_received {:telemetry, @oldest_starting, %{timestamp_seconds: since}, %{}}
    assert_in_delta since, reserved_at, 0.001

    due!(r)
    connect!(r)
    drain_telemetry()
    assert :ok = CodingSandboxes.FleetMetrics.emit()
    assert_received {:telemetry, @records, %{count: ready}, %{state: "ready"}}
    assert ready >= 1
    # With nothing starting, the time of publishing: a node that stops
    # publishing leaves a value whose age grows.
    assert_received {:telemetry, @oldest_starting, %{timestamp_seconds: since}, %{}}
    assert since == SystemsClock.system_time(:millisecond) / 1_000
  end

  test "a sandbox that does not connect within 5 minutes fails, and the Task says so",
       %{reservation: r} do
    watch_telemetry!()
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    SystemsClock.advance(301_000)
    assert due!(r).spec["state"] == "failed"
    assert_received {:l4es, "STOP", _, _, _}
    assert_received {:telemetry, @start, %{duration: gave_up}, %{kind: :create, outcome: :failed}}
    assert gave_up >= 301_000
    assert_received {:telemetry, @end_event, %{}, %{state: "failed"}}

    assert [
             %{
               "content" =>
                 "The sandbox could not run: the sandbox did not start within 5 minutes" <>
                   _
             }
           ] =
             Task.messages()
  end

  test "the notice of a failed start does not start the sandbox again; a reply does",
       %{reservation: r} do
    SystemsRuntime.put_env(:salix_web, :coding_github, NoGitHub)
    :ok = CodingSandboxes.reserve(r)
    failed = due!(r)
    assert failed.spec["state"] == "failed"

    assert [
             %{
               "content" =>
                 "The sandbox could not run: the Workspace has no GitHub account connected. Reply to try again.",
               "metadata" => %{"kind" => "sandbox_notice"}
             }
           ] = Task.messages()

    # The notice is a Message of the Task, and the Task's actor tells the
    # stations of each one added, as of a reply. The sandbox's station never
    # took the Task, so the Message asks for a sandbox that will
    # (`CodingSandboxes.appended/2`): the notice must not be one that does.
    :ok = StationTasks.appended(r.group_id, "cnv_code")
    settle()
    assert workload(r).generation == failed.generation
    assert workload(r).spec["state"] == "failed"
    CodingSandboxes.check_due()
    assert [_notice] = Task.messages()

    # A reply starts it again: the start fails as before, and is said again.
    reply!(r)
    :ok = StationTasks.appended(r.group_id, "cnv_code")
    settle()
    assert workload(r).generation == failed.generation + 1
    assert due!(r).spec["state"] == "failed"
    assert [_notice, _reply, %{"metadata" => %{"kind" => "sandbox_notice"}}] = Task.messages()
  end

  test "a Task that ends while its sandbox still starts ends the run; that is no failed start",
       %{reservation: r} do
    watch_telemetry!()
    :ok = CodingSandboxes.reserve(r)
    due!(r)
    Task.set_status("completed")
    :ok = CodingSandboxes.task_status(r.group_id, "cnv_code", "completed")
    CodingSandboxes.check_due()
    assert workload(r).spec["state"] == "ended"
    assert_received {:telemetry, @end_event, %{}, %{state: "ended"}}
    refute_received {:telemetry, @start, _, _}
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
