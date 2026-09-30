defmodule SalixAgent.InternalSessionFormat do
  @moduledoc """
  Storage write boundary: read legacy snapshots as-is, but publish only the
  current format. Format-1 coordinates are fixed by the same hot CAS as the
  business mutation, before any new segment is published. Format-2 archives
  become a frozen read-only prefix; first write never loads their history.

  Modeled in tla/salix/SessionFormat3Migration.tla.
  """
  alias SalixAgent.InternalSession
  require SalixAgent.InternalSession

  @doc """
  Normalizes a session for writing and migrates format 1 to format 3. The
  kernel owns the rule; a state map is admitted and exported around it for
  callers that still hold data.
  """
  @spec prepare_write(InternalSession.t()) :: {:ok, InternalSession.t()} | {:error, term()}
  def prepare_write(session) when InternalSession.is_session(session),
    do: InternalSession.prepare_write(session)
end
