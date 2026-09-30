defmodule AlertRouter.StartupIsolationTest do
  use ExUnit.Case, async: false

  @tag timeout: 60_000
  test "standalone Router serves HTTP without starting the Salix storage runtime" do
    # A fresh VM exercises OTP dependency startup, which calling
    # AlertRouter.Application.start/2 in the umbrella test VM would bypass.
    script = """
    Application.put_env(:alert_router, :start_repo, false)
    Application.put_env(:alert_router, :start_oban, false)
    Application.put_env(:alert_router, Oban, [])
    Application.put_env(:alert_router, :start_http, true)
    Application.put_env(:alert_router, :port, 0)
    Application.delete_env(:salix_store, :snowflake_worker_id)

    {:ok, _} = Application.ensure_all_started(:alert_router)
    {:ok, {_, port}} = ThousandIsland.listener_info(AlertRouter.HTTPServer)
    {:ok, %{status: 200}} = Req.get("http://127.0.0.1:" <> to_string(port) <> "/live")

    true = Code.ensure_loaded?(SalixStore.S3)
    true = Code.ensure_loaded?(SalixStore.Config)
    false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :salix_store end)
    nil = Process.whereis(SalixStore.Ids)
    nil = Process.whereis(SalixStore.Repo)
    IO.puts("standalone-router-ok")
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, status} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script],
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2"}]
      )

    assert status == 0, output
    assert output =~ "standalone-router-ok"
  end
end
