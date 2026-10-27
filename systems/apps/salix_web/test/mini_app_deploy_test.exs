defmodule SalixWeb.MiniAppDeployTest do
  @moduledoc """
  A Mini App build Task's Session deploys its app (`task.app_deploy`,
  `SalixWeb.StationTasks.app_deploy/2`): only from the Task's current sandbox,
  for the app the Task builds. Its files are read from the station into temp
  files for the app's owner, and the Version is written into the Task once
  per key. L4ES, the station, the Task and the app owner
  (`SalixWeb.MiniAppDeploys`) are fakes; the sandbox Workload is real.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixWeb", "Elixir.SalixEnv"]

  alias SalixEnv.Registry
  alias SalixStore.CodingSandboxes, as: Store
  alias SalixStore.StationTaskSessions
  alias SalixWeb.{CodingSandboxes, StationTasks}

  @app_id "6f1c2a0e-6c43-4a8e-9a55-2b8f0f1d3c11"
  @commit String.duplicate("a1", 20)

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

  defmodule Task do
    @moduledoc "The Task: its record (`mini_app`, `repo`), Worker and Messages; an append is once per client_request_id."
    use Agent

    def start_link(state), do: SystemsRuntime.Agent.start_link(fn -> state end, name: __MODULE__)
    def messages, do: SystemsRuntime.Agent.get(__MODULE__, & &1.messages)
    def set_record(record), do: SystemsRuntime.Agent.update(__MODULE__, &%{&1 | record: record})

    def task(_group, _conversation), do: {:ok, SystemsRuntime.Agent.get(__MODULE__, & &1.record)}
    def owner(_group, _conversation), do: {:ok, "usr_owner"}
    def status(_group, _conversation), do: {:ok, "active"}

    def participants(_group, _conversation),
      do: {:ok, SystemsRuntime.Agent.get(__MODULE__, & &1.participants)}

    def append(_group, _conversation, _agent, attrs) do
      SystemsRuntime.Agent.get_and_update(__MODULE__, fn state ->
        case Enum.find(state.messages, &(&1["client_request_id"] == attrs["client_request_id"])) do
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
  end

  defmodule Station do
    @moduledoc "The sandbox's station: it joins the Task, and gives the files of its deploy by index."
    def request(_run_id, method, params, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :coding_test_pid),
        {:asked, method, params}
      )

      case method do
        "task.invite" ->
          {:ok, %{"session" => "ember:c-1"}}

        "task.put" ->
          {:ok, %{"through" => params["through"]}}

        "task.posted_file" ->
          bytes = SystemsRuntime.fetch_env!(:salix_web, :app_deploy_files)[params["index"]]
          offset = params["offset"]
          part = binary_part(bytes, offset, min(256 * 1024, byte_size(bytes) - offset))
          {:ok, %{"offset" => offset, "data" => Base.encode64(part)}}
      end
    end
  end

  defmodule Apps do
    @moduledoc "The app owner: one Version per (app, key); what it was given, read while it is asked."
    @behaviour SalixWeb.MiniAppDeploys
    use Agent

    def start_link(_), do: SystemsRuntime.Agent.start_link(fn -> %{} end, name: __MODULE__)

    @impl true
    def deploy(ctx, files) do
      given =
        Map.new(files, fn
          {:manifest, bytes} -> {:manifest, bytes}
          {role, %{path: path}} -> {role, {path, File.read!(path)}}
        end)

      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_web, :coding_test_pid),
        {:deploy, ctx, given}
      )

      version =
        SystemsRuntime.Agent.get_and_update(__MODULE__, fn versions ->
          case versions[ctx.key] do
            nil ->
              n = map_size(versions) + 1
              {n, Map.put(versions, ctx.key, n)}

            n ->
              {n, versions}
          end
        end)

      {:ok,
       %{
         "app_id" => ctx.app_id,
         "version" => version,
         "state" => "ready",
         "name" => "Habit tracker",
         "summary" => "Habit tracker — preview version #{version}"
       }}
    end

    @impl true
    def logs(%{app_id: _app_id}, version), do: {:ok, ["version #{inspect(version)}: boom"]}
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Apps"})
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Apps"}, tenant["tenant_id"])

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    repo = %{
      "owner" => "ann",
      "name" => "comma-app-x7k2q9",
      "base_ref" => "main",
      "branch" => "comma/code"
    }

    start_supervised!(
      {Task,
       %{
         record: %{"repo" => repo, "mini_app" => %{"app_id" => @app_id}},
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

    start_supervised!(Apps)
    test_pid = SystemsRuntime.Proc.self()

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
          coding_test_pid: test_pid,
          station_tasks: [conversations: Task, connector: Station],
          mini_app_deploys: Apps
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
            :station_tasks,
            :mini_app_deploys,
            :app_deploy_files
          ],
          do: SystemsRuntime.delete_env(:salix_web, key)

      if previous,
        do: SystemsRuntime.put_env(:salix_store, :compute_workload_credential_secret, previous),
        else: SystemsRuntime.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    r = %{
      tenant_id: tenant["tenant_id"],
      group_id: group["group_id"],
      conversation_id: "cnv_code",
      device_id: Store.device_id("cnv_code"),
      agent_id: worker["agent_id"],
      start: %{
        "requester" => worker["agent_id"] <> "@agents.salix",
        "runtime" => "claude",
        "repo" => repo,
        "mini_app" => %{"app_id" => @app_id}
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

  # The files of a deploy, as the station names them; their bytes by index.
  defp files!(files) do
    SystemsRuntime.put_env(
      :salix_web,
      :app_deploy_files,
      files |> Enum.with_index() |> Map.new(fn {{_name, bytes}, i} -> {i, bytes} end)
    )

    files
    |> Enum.with_index()
    |> Enum.map(fn {{name, bytes}, i} ->
      %{"index" => i, "name" => name, "size" => byte_size(bytes)}
    end)
  end

  defp deploy_params(key, files) do
    %{
      "task" => "cnv_code",
      "session" => "ember:c-1",
      "key" => key,
      "app_id" => @app_id,
      "commit" => @commit,
      "notes" => "first preview",
      "files" => files
    }
  end

  defp app_files do
    files!([
      {"comma-app.json", ~s({"name":"Habit tracker"})},
      {"bundle.tar", :binary.copy("b", 300 * 1024)},
      {"source.tar.gz", "source"},
      {"worker.js", "export default {}"}
    ])
  end

  test "the current sandbox deploys its Task's app: files in temp files, one Version and one Message per key",
       %{r: r, view: view} do
    files = app_files()

    assert {:ok,
            %{
              "app_id" => @app_id,
              "version" => 1,
              "state" => "ready",
              "summary" => "Habit tracker — preview version 1"
            }} = StationTasks.app_deploy(view, deploy_params("k-1", files))

    assert_received {:deploy, ctx, given}

    assert %{
             app_id: @app_id,
             key: "k-1",
             commit: @commit,
             notes: "first preview",
             branch: "comma/code",
             repo: %{"owner" => "ann", "name" => "comma-app-x7k2q9"},
             conversation_id: "cnv_code"
           } = ctx

    assert ctx.agent_id == r.agent_id
    assert given.manifest == ~s({"name":"Habit tracker"})
    {bundle_path, bundle} = given.bundle
    assert bundle == :binary.copy("b", 300 * 1024)
    assert {_path, "source"} = given.source
    assert {_path, "export default {}"} = given.worker
    # The temp files are gone once the owner answered.
    refute File.exists?(bundle_path)

    # The station asked again with the same key: the same Version, no second Message.
    assert {:ok, %{"version" => 1}} = StationTasks.app_deploy(view, deploy_params("k-1", files))

    assert [message] = Task.messages()

    assert message["content"] == [
             %{"type" => "text", "text" => "Habit tracker — preview version 1"},
             %{
               "type" => "mini_app",
               "version" => 1,
               "app_id" => @app_id,
               "app_version" => 1,
               "name" => "Habit tracker",
               "summary" => "Habit tracker — preview version 1"
             }
           ]

    assert {message["agent_id"], message["participant_id"]} == {r.agent_id, "ptp_worker"}

    assert {:ok, _content} =
             SalixIM.ConversationMessage.validate_content("message", message["content"])

    # Another key is another Version.
    assert {:ok, %{"version" => 2}} = StationTasks.app_deploy(view, deploy_params("k-2", files))
    assert length(Task.messages()) == 2

    assert {:ok, %{"lines" => ["version 2: boom"]}} =
             StationTasks.app_logs(view, %{
               "task" => "cnv_code",
               "session" => "ember:c-1",
               "app_id" => @app_id,
               "version" => 2
             })
  end

  test "a replaced sandbox generation, another device or Session, cannot deploy", %{
    r: r,
    view: view
  } do
    files = app_files()

    # Another device of the Group, with the Task's Session id.
    assert {:error, :not_taking_part} =
             StationTasks.app_deploy(
               %{view | device_id: "laptop"},
               deploy_params("k-1", files)
             )

    assert {:error, :not_taking_part} =
             StationTasks.app_deploy(view, %{deploy_params("k-1", files) | "session" => "ember:x"})

    # The sandbox stopped and the Task's next one was made: the old generation's
    # connection has no authority left.
    {:ok, w} = Store.get_by_conversation(r.tenant_id, r.conversation_id)

    {:ok, _} =
      Store.update(w.id, fn current ->
        {:ok, Map.merge(current.spec, %{"state" => "stopped"})}
      end)

    {:ok, _next} = Store.advance(w.id)

    assert {:error, :station_connection_changed} =
             StationTasks.app_deploy(view, deploy_params("k-1", files))

    refute_received {:asked, "task.posted_file", _}
    refute_received {:deploy, _, _}
    assert Task.messages() == []
  end

  test "a Task that builds no app, or another app, or files out of bounds deploy nothing",
       %{view: view} do
    files = app_files()

    assert {:ok, %{"error" => "app_mismatch"}} =
             StationTasks.app_deploy(view, %{
               deploy_params("k-1", files)
               | "app_id" => "9d0b1e2f-0000-4000-8000-000000000000"
             })

    for bad <- [
          # Too large before a byte is read.
          [{"comma-app.json", "{}"}, {"bundle.tar", "b"}, {"source.tar.gz", "s"}]
          |> files!()
          |> Enum.map(
            &if(&1["name"] == "bundle.tar", do: %{&1 | "size" => 29 * 1024 * 1024}, else: &1)
          ),
          # No source archive.
          files!([{"comma-app.json", "{}"}, {"bundle.tar", "b"}]),
          # A file a deploy has not.
          files!([
            {"comma-app.json", "{}"},
            {"bundle.tar", "b"},
            {"source.tar.gz", "s"},
            {"secrets.env", "x"}
          ])
        ] do
      assert {:ok, %{"error" => "invalid", "message" => _}} =
               StationTasks.app_deploy(view, deploy_params("k-1", bad))
    end

    Task.set_record(%{"repo" => %{"owner" => "ann", "name" => "comma-app-x7k2q9"}})

    assert {:ok, %{"error" => "not_an_app_task"}} =
             StationTasks.app_deploy(view, deploy_params("k-1", files))

    assert {:ok, %{"error" => "not_an_app_task"}} =
             StationTasks.app_logs(view, %{
               "task" => "cnv_code",
               "session" => "ember:c-1",
               "app_id" => @app_id
             })

    refute_received {:asked, "task.posted_file", _}
    refute_received {:deploy, _, _}
    assert Task.messages() == []
  end
end
