defmodule Salix.Runtime do
  @moduledoc """
  Internal Salix runtime facade used by Comma business contexts.
  """

  def deliver(agent_id, payload, opts \\ []), do: SalixAgent.deliver(agent_id, payload, opts)

  def wake(agent_id, attrs \\ %{}, tenant_id),
    do: SalixAgent.Control.wake(agent_id, attrs, tenant_id)

  def cancel_agent(agent_id, tenant_id),
    do: SalixAgent.Control.cancel(agent_id, tenant_id)

  def get_session(agent_id, session_id, opts \\ []),
    do: SalixAgent.Runtime.get_session(agent_id, session_id, opts)

  def read_session(agent_id, session_id), do: SalixAgent.Runtime.get_session(agent_id, session_id)
  def list_sessions(agent_id, opts \\ []), do: SalixAgent.Runtime.list_sessions(agent_id, opts)

  def compact_session(agent_id, session_id),
    do: SalixAgent.Runtime.compact_session(agent_id, session_id)

  def microcompact_session(agent_id, session_id),
    do: SalixAgent.Runtime.microcompact_session(agent_id, session_id)

  def session_trace(agent_id, session_id, opts \\ []),
    do: SalixAgent.Runtime.session_trace(agent_id, session_id, opts)

  def execute_session_tool(agent_id, session_id, tool_name, attrs, tenant_id) do
    SalixAgent.Runtime.execute_session_tool(agent_id, session_id, tool_name, attrs, tenant_id)
  end

  def list_files(agent_id, path), do: SalixAgent.Workspace.list(agent_id, path)
  def read_file(agent_id, path), do: SalixAgent.Workspace.read(agent_id, path)
  def put_file(agent_id, path, body), do: SalixAgent.Workspace.write(agent_id, path, body)

  def delete_file(agent_id, path, opts \\ []),
    do: SalixAgent.Workspace.delete(agent_id, path, opts)
end
