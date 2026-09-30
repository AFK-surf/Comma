defmodule SalixAgent.InternalSessionFormat3Legacy do
  @moduledoc """
  Pure format-1 normalization for the online format-3 migration.

  Unlike the historical exclusive cutover, online stock can contain both
  unstamped legacy history and newly stamped generic/async results. Preserve
  every record and remap owned seq references before the same business hot CAS fixes
  the current immutable coordinate system. No archive objects are published
  while these coordinates can still change.

  The rule itself lives in the Lean kernel
  (`VerifiedKernel.Session.Legacy.migrateFormat1`, reached through the
  `prepare_write` lifecycle operation); this module is only the name the
  migration tools call it by.
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
