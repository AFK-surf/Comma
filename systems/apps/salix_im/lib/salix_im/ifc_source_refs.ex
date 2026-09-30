defmodule SalixIM.IFCSourceRefs do
  @moduledoc """
  The Task conversation `source_refs` keys the information-flow design owns
  (`docs/verification.md` §8).

  `ifc_provenance` is the audience a Task inherited from the sources its
  creation declared; `ifc_members` is who it is shared with. Both are written
  once, server-side, by the operation that creates the Task, from the
  dispatcher's evidence. Declaring them protected keeps the generic
  conversation API — and therefore any agent — from introducing, changing or
  removing them.
  """

  def protected_source_ref_keys, do: ["ifc_provenance", "ifc_members"]
end
