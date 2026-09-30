defmodule SalixMeet.TestAgentRuntime do
  @moduledoc false

  @behaviour SalixMeet.Ports.AgentRuntime

  @impl true
  def ensure_agent(request), do: SalixAgent.MeetingRuntime.ensure_agent(request)

  @impl true
  def verify_agent(request), do: SalixAgent.MeetingRuntime.verify_agent(request)

  @impl true
  def prepare_workspace_write(agent_id, path, data),
    do: SalixAgent.MeetingRuntime.prepare_workspace_write(agent_id, path, data)

  @impl true
  def discard_prepared_workspace_write(event),
    do: SalixAgent.AgentWorkspace.discard_prepared_write(event)

  @impl true
  def stream_workspace_write(agent_id, _env_id, dst_path, src_path) do
    stream = File.stream!(src_path, 64 * 1024)
    SalixAgent.MeetingRuntime.prepare_workspace_write_stream(agent_id, dst_path, stream)
  end

  @impl true
  def stat_workspace(agent_id, path),
    do: SalixAgent.MeetingRuntime.stat_workspace(agent_id, path)

  @impl true
  def read_workspace(agent_id, path), do: SalixAgent.MeetingRuntime.read_workspace(agent_id, path)

  @impl true
  def stream_workspace_read(agent_id, path),
    do: SalixAgent.MeetingRuntime.stream_workspace(agent_id, path)

  @impl true
  def event_committed?(agent_id, session_id, source_id),
    do: SalixAgent.MeetingRuntime.event_committed?(agent_id, session_id, source_id)

  @impl true
  def workspace_event_committed?(agent_id, session_id, source_id),
    do: SalixAgent.MeetingRuntime.workspace_event_committed?(agent_id, session_id, source_id)

  @impl true
  def commit_event(request), do: SalixAgent.MeetingRuntime.commit_event(request)
end
