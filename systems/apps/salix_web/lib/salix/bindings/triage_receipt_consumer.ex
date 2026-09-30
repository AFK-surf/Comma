defmodule Salix.Bindings.TriageReceiptConsumer do
  @moduledoc """
  Production adapter from one typed Slack receipt to native Triage admission.

  After native admission, historical directed-agent callback v2 receipts may
  still be staged into an existing command Router session as idempotent no-wake
  context. New agent content arrives as ClickHouse v3 and does not use that
  compatibility projection. This adapter has no Slack read/write, model, Task,
  Memory, or executor authority.
  """

  @behaviour SalixIM.Provider.Slack.TriageReceiptConsumer

  @impl true
  def handle_typed_receipt(authority, receipt, opts)
      when is_map(authority) and is_map(receipt) and is_list(opts) do
    with true <- Enum.sort(Keyword.keys(opts)) == [:delivery_mode, :runtime],
         :review <- Keyword.fetch!(opts, :delivery_mode),
         runtime <- Keyword.fetch!(opts, :runtime),
         {:ok, status, membership}
         when status in [:accepted, :duplicate] and
                membership in [:open_member, :sealed_member, :evidence_only] <-
           SalixIM.Triage.accept_current_with_membership(runtime, authority, receipt),
         :ok <- maybe_deliver_router_context(membership, authority, receipt) do
      :ok
    else
      :off -> {:error, :triage_runtime_off}
      false -> {:error, :invalid_triage_receipt_consumer}
      {:error, _reason} = error -> error
      _other -> {:error, :triage_admission_unavailable}
    end
  catch
    :exit, _reason -> {:error, :triage_admission_unavailable}
  end

  def handle_typed_receipt(_authority, _receipt, _opts),
    do: {:error, :invalid_triage_receipt_consumer}

  defp maybe_deliver_router_context(:open_member, authority, receipt),
    do: SalixIM.Triage.RouterContextProjection.deliver(authority, receipt)

  defp maybe_deliver_router_context(:sealed_member, authority, receipt),
    do: SalixIM.Triage.RouterContextProjection.deliver(authority, receipt)

  defp maybe_deliver_router_context(:evidence_only, _authority, _receipt), do: :ok
end
