defmodule SalixAgent.InternalSession.Recovery do
  @moduledoc false

  alias SalixAgent.InternalSession

  defstruct action: :continue, checkpoint: nil, stage: nil, reason: nil, session: nil

  def observe(session, checkpoint) do
    struct!(__MODULE__, InternalSession.query(session, :reconcile, checkpoint))
    |> Map.put(:session, session)
  end

  def cleared, do: %__MODULE__{}

  def failure(checkpoint, stage, reason), do: result({:failure, checkpoint, stage, error(reason)})
  def round_failure(checkpoint, reason), do: result({:round_failure, checkpoint, error(reason)})

  def handoff(pending, reason),
    do: result({:handoff, Map.take(pending, [:visible_reply_scope]), error(reason)})

  def disposition(checkpoint), do: InternalSession.recovery_policy({:disposition, checkpoint})

  defp result(args), do: struct!(__MODULE__, InternalSession.recovery_policy(args))
  defp error(reason), do: InternalSession.Command.external_error(reason)
end
