defmodule BridgeForTeams.ContextLifecycle.Purger do
  @moduledoc """
  Source-layout adapter used by the shared Context Lifecycle owner.

  `purge/1` runs inside the lifecycle owner's database transaction. It must be
  idempotent, bounded, and delete content rather than making retention policy.
  Count keys and error classes are protocol codes owned by the lifecycle layer,
  never source text. Unknown keys fail closed and unknown errors are persisted
  only as `unknown`. On any error the transaction is rolled back before retry
  state is persisted.
  """

  alias BridgeForTeams.Schema.ContextBundle

  @callback purge(ContextBundle.t()) ::
              {:ok, %{optional(atom() | String.t()) => non_neg_integer()}}
              | {:error, term()}
end
