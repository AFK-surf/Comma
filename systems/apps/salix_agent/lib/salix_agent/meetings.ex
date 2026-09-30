defmodule SalixAgent.Meetings do
  @moduledoc "Group-scoped runtime seam for Router-owned meeting tools."

  alias SalixAgent.GroupRuntime

  @callback join(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  @callback get(String.t(), map()) :: {:ok, map()} | {:ok, map(), map() | nil} | {:error, term()}

  @callback summary_materials(String.t(), map(), map()) :: term()
  @callback submit_summary(String.t(), map(), map()) :: term()
  @optional_callbacks summary_materials: 3, submit_summary: 3

  def summary_materials(agent_id, params, tool_context),
    do: call(agent_id, :summary_materials, [params, tool_context])

  def submit_summary(agent_id, params, tool_context),
    do: call(agent_id, :submit_summary, [params, tool_context])

  def join(agent_id, params, tool_context),
    do: call(agent_id, :join, [params, tool_context])

  def get(agent_id, params), do: call(agent_id, :get, [params])

  defp call(agent_id, command, args) do
    GroupRuntime.call(
      agent_id,
      :meeting_mod,
      :meeting_not_configured,
      command,
      args
    )
  end
end
