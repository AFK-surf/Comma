defmodule BridgeForTeams.Observability.SalixScheduleSinkTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.{Agents, Observability, Orgs, Projects}
  alias BridgeForTeams.Observability.SalixScheduleSink

  test "records Salix schedule failures as project-scoped Operations events without prompt content" do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-schedule-sink"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    {:ok, agent} = Agents.create_agent(project.id, %{"name" => "scheduler", "role" => "worker"})

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

  test "uses request ids from schedule diagnostics as Operations correlation ids" do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-schedule-request-id"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})
    {:ok, agent} = Agents.create_agent(project.id, %{"name" => "scheduler", "role" => "worker"})

    :ok =
      SalixScheduleSink.record(%{
        event_type: "schedule.fire.failed",
        severity: "error",
        status: "failed",
        reason_class: "http",
        summary: "Schedule fire failed at deliver",
        schedule_id: "sched-request",
        agent_id: agent.salix_agent_id,
        scheduled_for_ms: 1_750_000_300_000,
        stage: "deliver",
        request_id: "req-schedule-fire",
        client_request_id: "client-schedule-fire",
        invocation_id: "inv-schedule-fire",
        prompt: "private customer instruction"
      })

    [event] = Observability.list_events(org.id, domain: "schedule")
    assert event.correlation_id == "req-schedule-fire"
    assert event.evidence["request_id"] == "req-schedule-fire"
    assert event.evidence["client_request_id"] == "client-schedule-fire"
    assert event.evidence["invocation_id"] == "inv-schedule-fire"
    refute inspect(event) =~ "private customer instruction"
  end

  test "records Task Schedule diagnostics through the conversation group" do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-task-schedule"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Acme", "slug" => "acme"})

    :ok =
      SalixScheduleSink.record(%{
        event_type: "schedule.fire.failed",
        severity: "error",
        status: "failed",
        reason_class: "bad_request",
        summary: "Schedule fire failed at receiver",
        schedule_id: "sched-task",
        agent_group_id: project.salix_group_id,
        conversation_id: "cnv1_1000000000000000003",
        scheduled_for_ms: 1_750_000_300_000,
        stage: "receiver"
      })

    [event] = Observability.list_events(org.id, domain: "schedule")
    assert event.project_id == project.id
    assert event.resource_id == "sched-task"
    assert event.evidence["salix_group_id"] == project.salix_group_id
    assert event.evidence["conversation_id"] == "cnv1_1000000000000000003"
    refute Map.has_key?(event.evidence, "bft_agent_id")
    refute Map.has_key?(event.evidence, "salix_agent_id")
  end

  test "ignores diagnostics for unknown Salix agents" do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-schedule-unknown"})

    assert :ok =
             SalixScheduleSink.record(%{
               event_type: "schedule.fire.failed",
               schedule_id: "sched-foreign",
               agent_id: "agent-foreign",
               status: "failed"
             })

    assert [] = Observability.list_events(org.id, domain: "schedule")
  end
end
