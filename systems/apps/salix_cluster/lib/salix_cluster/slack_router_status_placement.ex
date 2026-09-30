defmodule SalixCluster.SlackRouterStatusPlacement do
  @moduledoc false

  @behaviour SalixIM.SlackRouterStatusPlacement

  @impl true
  def ensure_started(agent_id, connect_id) do
    owner = SalixCluster.Ring.owner(agent_id)

    if owner == Node.self() do
      SalixIM.SlackRouterStatus.ensure_actor_local(connect_id, agent_id)
    else
      :erpc.call(
        owner,
        SalixIM.SlackRouterStatus,
        :ensure_actor_local,
        [connect_id, agent_id],
        5_000
      )
    end
  rescue
    error -> {:error, {:owner_unreachable, agent_id, error}}
  catch
    :exit, reason -> {:error, {:owner_unreachable, agent_id, reason}}
  end

  @impl true
  def local_owner?(agent_id) do
    SalixCluster.Ring.owner(agent_id) == Node.self()
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end
end
