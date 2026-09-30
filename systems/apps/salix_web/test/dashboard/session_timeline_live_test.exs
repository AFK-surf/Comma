defmodule SalixWeb.Dashboard.SessionTimelineLiveTest do
  @moduledoc """
  The session page's "What actually ran" card: reconciling per-session strip,
  round grouping with finish verdicts, outcome chips, repeat folding, and the
  not-configured degrade.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SalixWeb.DashboardEndpoint

  defmodule StubQueries do
    # One converged round, one round the actor never finished (timestamps are
    # fixed and long past, so the session reads as silent), and one dispatch
    # call outside any round. wait_for repeats three times with identical
    # fingerprints and must fold into one row.
    def session_trace(_tenant, _session_id) do
      {:ok,
       [
         llm("2026-07-10 10:00:00.000", "r1",
           model: "claude-haiku-4.5",
           status: "ok",
           duration_ms: 3100,
           first_token_ms: 420,
           attempts: 2,
           tokens: 150
         ),
         tool("2026-07-10 10:00:05.000", "r1", "web_fetch", "builtin",
           status: "completed",
           duration_ms: 1200
         ),
         tool("2026-07-10 10:00:10.000", "r1", "wait_for", "builtin", repeat_fp()),
         tool("2026-07-10 10:00:20.000", "r1", "wait_for", "builtin", repeat_fp()),
         tool("2026-07-10 10:00:30.000", "r1", "wait_for", "builtin", repeat_fp()),
         run("2026-07-10 10:00:40.000", "r1", status: "completed", duration_ms: 8200),
         tool("2026-07-10 10:05:00.000", "r2", "js_run", "js_host",
           status: "error",
           error_type: "exception",
           duration_ms: 800
         ),
         tool("2026-07-10 10:05:10.000", "r2", "send_message", "mcp",
           status: "guidance",
           guidance_reason: "invalid_params",
           duration_ms: 0
         ),
         llm("2026-07-10 10:06:00.000", nil, model: "gpt-4o-mini", status: "ok", duration_ms: 900)
       ]}
    end

    defp repeat_fp,
      do: [
        status: "completed",
        duration_ms: 15_000,
        args_fingerprint: "aaaa",
        result_fingerprint: "bbbb"
      ]

    defp llm(at, round, extra) do
      Map.merge(
        %{
          "event_kind" => "llm",
          "started_at" => at,
          "metered_at" => at,
          "round_id" => round,
          "name" => "openrouter",
          "model" => nil,
          "detail" => nil,
          "status" => "ok",
          "error_type" => "none",
          "guidance_reason" => nil,
          "duration_ms" => nil,
          "first_token_ms" => nil,
          "attempts" => 1,
          "tokens" => 0,
          "args_fingerprint" => nil,
          "result_fingerprint" => nil,
          "async" => false
        },
        Map.new(extra, fn {k, v} -> {to_string(k), v} end)
      )
    end

    defp tool(at, round, name, source, extra) do
      Map.merge(
        %{
          "event_kind" => "tool",
          "started_at" => at,
          "metered_at" => at,
          "round_id" => round,
          "name" => name,
          "model" => nil,
          "detail" => source,
          "status" => "completed",
          "error_type" => nil,
          "guidance_reason" => nil,
          "duration_ms" => 0,
          "first_token_ms" => nil,
          "attempts" => nil,
          "tokens" => nil,
          "args_fingerprint" => nil,
          "result_fingerprint" => nil,
          "async" => false
        },
        Map.new(extra, fn {k, v} -> {to_string(k), v} end)
      )
    end

    defp run(at, round, extra) do
      Map.merge(
        %{
          "event_kind" => "run",
          "started_at" => at,
          "metered_at" => at,
          "round_id" => round,
          "name" => "agent_run",
          "model" => nil,
          "detail" => nil,
          "status" => "completed",
          "error_type" => nil,
          "guidance_reason" => nil,
          "duration_ms" => 0,
          "first_token_ms" => nil,
          "attempts" => nil,
          "tokens" => nil,
          "args_fingerprint" => nil,
          "result_fingerprint" => nil,
          "async" => false
        },
        Map.new(extra, fn {k, v} -> {to_string(k), v} end)
      )
    end
  end

  defmodule NotConfiguredQueries do
    def session_trace(_tenant, _session_id), do: {:error, :not_configured}
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Timeline"})
    Process.put(:test_tenant_id, tenant["tenant_id"])
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "TimelineGrp"}, tenant_id())
    {:ok, tmpl} = SalixAgent.Templates.create(%{"name" => "TimelineTmpl", "model" => "mock"})

    {:ok, agent} =
      SalixAgent.Control.create(
        %{
          "name" => "Timeline Agent",
          "group_id" => group["group_id"],
          "template_id" => tmpl["template_id"],
          "role" => "worker"
        },
        tenant_id()
      )

    aid = agent["salix_agent_id"] || agent["agent_id"] || agent["id"]
    session_id = SalixStore.Ids.new_session_id()

    {:ok, _} =
      SalixAgent.deliver(
        aid,
        %{
          kind: "session_create",
          session_id: session_id,
          name: "Main",
          created_at: System.system_time(:second)
        },
        source_message_id: "test:timeline-session:#{aid}"
      )

    %{aid: aid, session_id: session_id}
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  defp authed_conn,
    do:
      build_conn()
      |> Plug.Test.init_test_session(%{"admin_authed" => true, "current_tenant" => tenant_id()})

  defp with_queries(mod) do
    prev = Application.get_env(:salix_web, :agent_telemetry_queries_mod)
    Application.put_env(:salix_web, :agent_telemetry_queries_mod, mod)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:salix_web, :agent_telemetry_queries_mod, prev),
        else: Application.delete_env(:salix_web, :agent_telemetry_queries_mod)
    end)
  end

  test "renders the timeline with strip, round verdicts, chips, and repeat folding", %{
    aid: aid,
    session_id: session_id
  } do
    with_queries(StubQueries)

    {:ok, _view, html} = live(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}")

    assert html =~ "What actually ran"
    assert html =~ ~s(id="timeline")

    # Per-session strip from the same rows the table shows.
    assert html =~ "Model time"
    assert html =~ "4.0s"
    assert html =~ "Tool time"
    assert html =~ "47.0s"
    assert html =~ ">150<"

    # Round headers: converged round gets its finish verdict; the silent one
    # (internal agent, long past the grace window) turns amber.
    assert html =~ "finished OK in 8.2s"

    # Call times are marked for the browser's local-time hook, with the UTC
    # text as the no-JavaScript fallback.
    assert html =~ ~s(data-local-time-ms="1783677600000")
    assert html =~ ~s(data-local-time-format="time-seconds")
    assert html =~ ">10:00:00</time>"
    assert html =~ "no finish record — last activity"

    # Outcome chips in plain language.
    assert html =~ "failed: exception"
    assert html =~ "sent back: wrong parameters"

    # First-word annotation and retry chip on the llm row.
    assert html =~ "first reply 420ms"
    assert html =~ "×2"

    # Three identical wait_for calls fold into one row.
    assert html =~ "repeat ×3"
    refute html =~ "repeat ×2"

    # Dispatch calls land in the outside-rounds group.
    assert html =~ "Outside rounds"
    assert html =~ "gpt-4o-mini"
  end

  test "hides the card when ClickHouse is not configured", %{
    aid: aid,
    session_id: session_id
  } do
    with_queries(NotConfiguredQueries)

    {:ok, _view, html} = live(authed_conn(), "/dash/agents/#{aid}/sessions/#{session_id}")

    refute html =~ "What actually ran"
  end
end
