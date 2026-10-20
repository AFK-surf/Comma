defmodule BridgeForTeams.Observability.SalixScheduleSinkTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Observability, Orgs, Projects}
  alias BridgeForTeams.Observability.SalixScheduleSink

  test "records Salix schedule failures as project-scoped Operations events without prompt content" do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-schedule-sink"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})

    {:ok, agent} =
      BridgeForTeams.TestSupport.LegacyWorker.create(project.id, %{
        "name" => "scheduler",
        "role" => "worker"
      })

    :ok =
      SalixScheduleSink.record(%{
        provider: "salix_cluster",
        domain: "schedule",
        source: "salix.schedule",
        event_type: "schedule.fire.failed",
        severity: "error",
        status: "failed",
        reason_class: "http",
        summary: "Schedule fire failed at deliver",
        schedule_id: "sched-fail",
        agent_id: agent.salix_agent_id,
        scheduled_for_ms: 1_750_000_300_000,
        scheduled_for: "20250615T150500.000Z",
        stage: "deliver",
        correlation_id: "schedule:sched-fail:1750000300000",
        session_id_configured: true,
        node: "node-a",
        prompt: "private customer instruction"
      })

    [event] = Observability.list_events(org.id, domain: "schedule")
    assert event.project_id == project.id
    assert event.source == "salix.schedule"
    assert event.event_type == "schedule.fire.failed"
    assert event.severity == "error"
    assert event.status == "failed"
    assert event.reason_class == "http"
    assert event.resource_type == "project_schedule"
    assert event.resource_id == "sched-fail"
    assert event.correlation_id == "schedule:sched-fail:1750000300000"
    assert event.evidence["schedule_id"] == "sched-fail"
    assert event.evidence["bft_agent_id"] == agent.id
    assert event.evidence["salix_agent_id"] == agent.salix_agent_id
    assert event.evidence["stage"] == "deliver"
    assert event.evidence["session_id_configured"] == "true"
    refute inspect(event) =~ "private customer instruction"
  end
end
