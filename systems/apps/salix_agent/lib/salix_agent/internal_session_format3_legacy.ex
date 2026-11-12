defmodule SalixAgent.InternalSessionFormat3Legacy do
  @moduledoc """
  Pure format-1 normalization for historical backup verification.

  The Lean kernel preserves records and remaps their owned seq references.
  This module does not write a Session or publish archive objects.
  """
  alias SalixAgent.InternalSession
  require SalixAgent.InternalSession

  @doc """
  Migrates a format-1 session to format 3. A handle in, a handle out; a state
  map is admitted and exported around the kernel for the one-off tools that
  still hold data.
  """
  @spec normalize(InternalSession.t()) :: {:ok, InternalSession.t()} | {:error, term()}
  def normalize(session) when InternalSession.is_session(session),
    do: InternalSession.prepare_write(session)
end
