defmodule SalixIM.Provider.Slack.TriageReceiptConsumer do
  @moduledoc """
  Post-receipt admission port for native Triage.

  Implementations must admit only the supplied current connect authority and
  make exact duplicate receipt delivery idempotent. A stale receipt may remain
  durable for audit, but it must not produce a current Triage run or effect.
  """

  @callback handle_typed_receipt(authority :: map(), receipt :: map(), opts :: keyword()) ::
              :ok | {:error, atom()}
end
