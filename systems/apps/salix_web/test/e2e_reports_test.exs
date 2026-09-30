defmodule SalixWeb.E2EReportsTest do
  use ExUnit.Case, async: false

  alias SalixWeb.E2EReports

  defmodule FakeStorage do
    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> %{} end)
    end

    def put_json(key, value), do: put_object(key, Jason.encode!(value))

    def put_object(key, body) do
      Agent.update(__MODULE__, &Map.put(&1, key, IO.iodata_to_binary(body)))
    end

    def keys, do: Agent.get(__MODULE__, &Map.keys/1)

    def get_object(key) do
      Agent.get(__MODULE__, fn objects ->
        case Map.fetch(objects, key) do
          {:ok, body} -> {:ok, %{body: body, size: byte_size(body)}}
          :error -> {:error, :not_found}
        end
      end)
    end

    def list_objects(prefix) do
      objects =
        Agent.get(__MODULE__, fn objects ->
          objects
          |> Enum.filter(fn {key, _body} -> String.starts_with?(key, prefix) end)
          |> Enum.map(fn {key, body} -> %{key: key, size: byte_size(body)} end)
          |> Enum.sort_by(& &1.key)
        end)

      {:ok, objects}
    end

    def delete_object(key) do
      Agent.update(__MODULE__, &Map.delete(&1, key))
      :ok
    end
  end

  setup do
    case start_supervised(FakeStorage) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    FakeStorage.reset()
    prev_storage = Application.get_env(:salix_web, :e2e_reports_storage)
    prev_secret = Application.get_env(:salix_web, :e2e_reports_session_secret)
    Application.put_env(:salix_web, :e2e_reports_storage, FakeStorage)
    Application.put_env(:salix_web, :e2e_reports_session_secret, "test-session-secret")

    on_exit(fn ->
      restore_env(:salix_web, :e2e_reports_storage, prev_storage)
      restore_env(:salix_web, :e2e_reports_session_secret, prev_secret)
    end)

    :ok
  end

  test "lists recent runs from date indexes and filters by target/status" do
    run = seed_run(status: "failure")

    {:ok, runs} =
      E2EReports.list_runs(%{"days" => "30", "target" => "web", "status" => "failure"})

    assert [%{"runId" => "9001", "attempt" => "2"}] = runs

    assert get_in(hd(runs), ["targets", "web", "reportIndexKey"]) ==
             get_in(run, ["targets", "web", "reportIndexKey"])

    assert {:ok, []} = E2EReports.list_runs(%{"days" => "30", "target" => "electron"})
  end

  test "creates scoped report sessions and serves report files" do
    seed_run()

    {:ok, session} =
      E2EReports.create_report_session(%{
        "runId" => "9001",
        "attempt" => "2",
        "target" => "web"
      })

    assert session.url =~ "/v1/e2e-report-sessions/"

    assert {:ok, %{body: "<html>report</html>", content_type: "text/html; charset=utf-8"}} =
             E2EReports.serve_report_file(session.token, "index.html")

    assert {:ok, %{body: "trace", content_type: "application/zip"}} =
             E2EReports.serve_report_file(session.token, "data/trace.zip")

    assert {:error, :invalid_path} =
             E2EReports.serve_report_file(session.token, "../run.json")
  end

  test "cleanup previews and deletes only e2e report objects after confirmation" do
    seed_run()
    FakeStorage.put_object("other-prefix/keep.txt", "keep")

    assert {:ok, preview} =
             E2EReports.cleanup_preview(%{
               "runs" => [%{"runId" => "9001", "attempt" => "2"}]
             })

    assert preview.objectCount == 5
    assert Enum.all?(preview.objects, &String.starts_with?(&1.key, "e2e-reports/"))

    assert {:error, :confirmation_required} =
             E2EReports.cleanup(%{
               "runs" => [%{"runId" => "9001", "attempt" => "2"}]
             })

    assert {:ok, cleanup} =
             E2EReports.cleanup(%{
               "confirm" => true,
               "runs" => [%{"runId" => "9001", "attempt" => "2"}]
             })

    assert cleanup.deletedObjects == 5
    assert FakeStorage.keys() == ["other-prefix/keep.txt"]
  end

  test "cleanup preview defaults to retention policy when no filters are supplied" do
    seed_run(status: "success", finished_offset_days: -8, run_id: "old-success")
    seed_run(status: "failure", finished_offset_days: -10, run_id: "fresh-failure")

    assert {:ok, preview} = E2EReports.cleanup_preview(%{"retention" => true})

    assert [%{runId: "old-success"}] = preview.runs
  end

  defp seed_run(opts \\ []) do
    finished_date =
      Date.utc_today()
      |> Date.add(Keyword.get(opts, :finished_offset_days, 0))
      |> Date.to_iso8601()

    today = Date.utc_today() |> Date.to_iso8601()
    status = Keyword.get(opts, :status, "failure")
    run_id = Keyword.get(opts, :run_id, "9001")
    attempt = "2"
    report_root = "e2e-reports/runs/#{run_id}/#{attempt}/web/report"
    run_key = "e2e-reports/runs/#{run_id}/#{attempt}/run.json"
    index_key = "e2e-reports/index/#{today}/#{run_id}-#{attempt}.json"
    manifest_key = "e2e-reports/runs/#{run_id}/#{attempt}/web/manifest.json"

    run = %{
      "schemaVersion" => 1,
      "repository" => "AFK-surf/Comma",
      "branch" => "main",
      "commitSha" => "abcdef123",
      "workflowName" => "Client Checks",
      "workflowRunId" => run_id,
      "workflowRunAttempt" => attempt,
      "workflowUrl" =>
        "https://github.com/AFK-surf/Comma/actions/runs/#{run_id}/attempts/#{attempt}",
      "runId" => run_id,
      "attempt" => attempt,
      "status" => status,
      "startedAt" => "#{finished_date}T12:00:00.000Z",
      "finishedAt" => "#{finished_date}T12:02:00.000Z",
      "durationMs" => 120_000,
      "targets" => %{
        "web" => %{
          "target" => "web",
          "status" => status,
          "reportRootKey" => report_root,
          "reportIndexKey" => report_root <> "/index.html",
          "manifestKey" => manifest_key,
          "artifacts" => [
            %{
              "group" => "report",
              "kind" => "html-report",
              "path" => "index.html",
              "key" => report_root <> "/index.html",
              "size" => 19
            },
            %{
              "group" => "report",
              "kind" => "trace",
              "path" => "data/trace.zip",
              "key" => report_root <> "/data/trace.zip",
              "size" => 5
            }
          ]
        }
      },
      "indexKey" => index_key
    }

    FakeStorage.put_json(index_key, run)
    FakeStorage.put_json(run_key, run)
    FakeStorage.put_json(manifest_key, %{"target" => "web"})
    FakeStorage.put_object(report_root <> "/index.html", "<html>report</html>")
    FakeStorage.put_object(report_root <> "/data/trace.zip", "trace")

    run
  end

  test "R2 storage requires the bucket from configuration" do
    original = Application.get_env(:salix_web, :e2e_reports_r2)

    on_exit(fn -> restore_env(:salix_web, :e2e_reports_r2, original) end)

    Application.put_env(:salix_web, :e2e_reports_r2,
      endpoint: "http://127.0.0.1:1",
      access_key_id: "key",
      secret_access_key: "secret"
    )

    assert {:error, :not_configured} = SalixWeb.E2EReports.R2.get_object("runs/x.json")
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
