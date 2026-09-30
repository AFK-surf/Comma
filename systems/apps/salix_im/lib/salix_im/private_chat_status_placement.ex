defmodule SalixIM.PrivateChatStatusPlacement do
  @moduledoc false
  @callback ensure_started(String.t(), map(), map()) :: {:ok, pid()} | {:error, term()}
  @callback local_owner?(String.t()) :: boolean()

  def ensure_started(agent_id, connect, metadata),
    do: impl().ensure_started(agent_id, connect, metadata)

  def local_owner?(agent_id), do: impl().local_owner?(agent_id)

  defp impl,
    do: Application.get_env(:salix_im, :private_chat_status_placement, __MODULE__.Local)

  defmodule Local do
    @moduledoc false
    @behaviour SalixIM.PrivateChatStatusPlacement
    def ensure_started(agent_id, connect, metadata),
      do: SalixIM.PrivateChatStatus.ensure_local(agent_id, connect, metadata)

    def local_owner?(_agent_id), do: true
  end
end
