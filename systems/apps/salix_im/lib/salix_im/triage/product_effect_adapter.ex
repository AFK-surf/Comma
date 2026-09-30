defmodule SalixIM.Triage.ProductEffectAdapter do
  @moduledoc """
  Final-effect boundary for native periodic Triage.

  The product worker owns durable claim and settlement. An adapter may either
  perform one idempotent production effect or capture that same intent in the
  local rehearsal sink. It never owns context persistence. A retryable error
  may report provider writes that happened before a later local-completion
  failure so the durable attempt audit remains truthful.
  """

  @type claim :: SalixStore.TriageProductRuntime.claim()
  @type effect :: %{
          required(:adapter) => :slack | :audit_sink,
          required(:outcome) => :applied | :stale | :failed,
          required(:external_writes) => non_neg_integer(),
          required(:communication) => map(),
          optional(:metadata) => map(),
          optional(:error) => String.t(),
          optional(:retry) => boolean()
        }

  @callback apply(claim(), keyword()) ::
              {:ok, effect()}
              | {:error, term(), retryable? :: boolean()}
              | {:error, term(), retryable? :: boolean(), external_writes :: non_neg_integer()}
end
