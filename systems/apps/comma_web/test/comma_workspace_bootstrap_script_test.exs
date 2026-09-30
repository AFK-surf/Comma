Code.require_file("../../../scripts/support/comma_workspace_bootstrap.exs", __DIR__)

defmodule CommaWeb.WorkspaceBootstrapScriptTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  @probe_pid_key :workspace_bootstrap_script_test_pid

  defmodule ProbeWorker do
    use Oban.Worker, queue: :comma_external

    @impl Oban.Worker
    def perform(_job) do
      send(
        Application.fetch_env!(:comma_web, :workspace_bootstrap_script_test_pid),
        :probe_performed
      )

      :ok
    end
  end

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    Comma.Repo.delete_all(from(job in Oban.Job, where: job.queue == "comma_external"))

    previous_probe_pid = Application.get_env(:comma_web, @probe_pid_key)
    Application.put_env(:comma_web, @probe_pid_key, self())

    on_exit(fn ->
      restore_env(:comma_web, @probe_pid_key, previous_probe_pid)
      CommaWeb.TestRepoSandbox.stop_owner(owner)
    end)

    :ok
  end

  test "pending script responses drain comma_external before retrying" do
    assert {:ok, _job} = Oban.insert(Comma.Oban, ProbeWorker.new(%{}))

    Process.put(
      :workspace_bootstrap_responses,
      [
        response(202, %{
          "status" => "provisioning",
          "workspace" => %{"id" => "wsp_test"}
        }),
        response(200, %{
          "status" => "ready",
          "workspace" => %{"id" => "wsp_test"}
        })
      ]
    )

    assert %{"id" => "wsp_test"} =
             CommaScripts.WorkspaceBootstrap.ensure_ready!(
               fn -> next_response!(:workspace_bootstrap_responses) end,
               max_attempts: 2,
               poll_ms: 0
             )

    assert_receive :probe_performed

    assert {:ok, _job} = Oban.insert(Comma.Oban, ProbeWorker.new(%{}))

    Process.put(
      :assistant_chat_responses,
      [
        response(200, %{
          "kind" => "user_chat",
          "status" => "pending",
          "workspace_id" => "wsp_test"
        }),
        response(200, %{
          "id" => "cnv_test",
          "kind" => "user_chat",
          "status" => "active",
          "workspace_id" => "wsp_test"
        })
      ]
    )

    assert %{"id" => "cnv_test", "status" => "active"} =
             CommaScripts.WorkspaceBootstrap.ensure_assistant_chat_ready!(
               fn -> next_response!(:assistant_chat_responses) end,
               max_attempts: 2,
               poll_ms: 0
             )

    assert_receive :probe_performed
  end

  defp next_response!(key) do
    case Process.get(key, []) do
      [response | rest] ->
        Process.put(key, rest)
        response

      [] ->
        raise "missing scripted response for #{inspect(key)}"
    end
  end

  defp response(status, payload) do
    %Plug.Conn{status: status, resp_body: Jason.encode!(payload)}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
