defmodule SalixCluster.PrivateChatStatusPlacement do
  @moduledoc false
  @behaviour SalixIM.PrivateChatStatusPlacement

  def ensure_started(agent_id, connect, metadata) do
    owner = SalixCluster.Ring.owner(agent_id)

    if owner == Node.self() do
      SalixIM.PrivateChatStatus.ensure_local(agent_id, connect, metadata)
    else
      :erpc.call(
        owner,
        SalixIM.PrivateChatStatus,
        :ensure_local,
        [agent_id, connect, metadata],
        5_000
      )
    end
  rescue
    _ -> {:error, :owner_unavailable}
  catch
    _, _ -> {:error, :owner_unavailable}
  end

  def local_owner?(agent_id) do
    SalixCluster.Ring.owner(agent_id) == Node.self()
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
