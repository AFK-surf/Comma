defmodule SalixAgent.ContextOverflow do
  @moduledoc """
  One compaction recovery per rejected transcript watermark. The marker survives
  compaction and reload. New transcript input starts a new recovery budget. The
  kernel decides whether a recovery is pending.
  """
  alias SalixAgent.InternalSession

  def pending?(session), do: InternalSession.query(session, :context_overflow_pending?)
end
