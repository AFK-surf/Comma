defmodule SalixAgent.Stop do
  @moduledoc """
  Stop existing Agent execution, one bounded page per explicit call. This does
  not change lifecycle or prevent a later task; archive owns admission. Each
  remote stop addresses a Session's pinned target, never a shared environment.
  No retry worker or durable stop-progress record is created.
  Modeled in tla/salix/AgentStop.tla.
  """
  alias SalixAgent.{Control, ExternalRuntime, ExternalSessionStore, Placement, RuntimeEnvironment}

  def stop(agent_id, tenant_id, opts \\ []) do
    with {:ok, agent} <- Control.get_including_archived(agent_id, tenant_id),
         :ok <- Placement.stop_existing(agent_id, reason: :normal, timeout: 5_000, force: true),
         {:ok, %{records: records, next: next}} <-
           ExternalSessionStore.stop_page(agent_id, Keyword.get(opts, :cursor)),
         :ok <- stop_sessions(agent, records) do
      {:ok, %{next_cursor: next}}
    end
  end

  defp stop_sessions(agent, sessions) do
    Enum.reduce_while(sessions, :ok, fn session, :ok ->
      # Never-dispatched Sessions have no remote capability or native execution.
      if is_binary(session["runtime_capability_token_hash"]) do
        binding = get_in(session, ["runtime", "binding"])

        result =
          with {:ok, transport} <-
                 RuntimeEnvironment.resolve_external_runtime_binding(
                   binding,
                   agent["tenant_id"],
                   agent["group_id"]
                 ) do
            ExternalRuntime.stop(%{
              agent_id: agent["agent_id"],
              session_id: session["session_id"],
              binding: Map.merge(binding, transport)
            })
          end

        case result do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end
end
