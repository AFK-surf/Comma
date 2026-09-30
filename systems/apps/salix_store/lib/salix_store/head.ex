defmodule SalixStore.Head do
  @moduledoc """
  Root metadata folded into the compressed agent state object. The root
  object's ETag is the fencing token; every commit revalidates it.

  Carries: `epoch`, `owner_node`, `lease_until` (unix ms), `commit_uuid` (of the
  last commit, for ambiguity recovery), the monotonic root `seq` currently kept
  in `journal_tail.seq`, `message_id_hwm`, fork lineage, `format_version`, and
  the hot application metadata projection.
  """

  @type t :: %__MODULE__{
          epoch: non_neg_integer(),
          owner_node: String.t() | nil,
          lease_until: integer() | nil,
          commit_uuid: String.t() | nil,
          journal_tail: %{epoch: non_neg_integer(), seq: non_neg_integer()},
          snapshot_seq: non_neg_integer() | nil,
          message_id_hwm: non_neg_integer(),
          parent_id: String.t() | nil,
          fork_seq: non_neg_integer() | nil,
          format_version: non_neg_integer(),
          hot: map(),
          spill: [String.t()]
        }

  defstruct epoch: 0,
            owner_node: nil,
            lease_until: nil,
            commit_uuid: nil,
            journal_tail: %{epoch: 0, seq: 0},
            snapshot_seq: nil,
            message_id_hwm: 0,
            parent_id: nil,
            fork_seq: nil,
            format_version: 1,
            hot: %{},
            spill: []
end
