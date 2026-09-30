defmodule SalixIM.Triage.AuditSink do
  @moduledoc """
  Zero-write final adapter for a production-shaped local Triage rehearsal.

  The durable product effect attempt is the audit record. This adapter returns
  the exact proposed reply, reaction or silence reason and target, while deliberately
  performing no Slack, task, or other external write.
  """

  @behaviour SalixIM.Triage.ProductEffectAdapter

  def apply(claim, opts \\ [])

  @impl true
  def apply(%{obligation_id: obligation_id, payload: payload}, _opts)
      when is_binary(obligation_id) and is_map(payload) do
    with {:ok, communication} <- communication(payload["communication"]) do
      {:ok,
       %{
         adapter: :audit_sink,
         outcome: :applied,
         external_writes: 0,
         communication: communication,
         metadata: %{
           "mode" => "local_rehearsal",
           "target" => Map.take(payload["target"] || %{}, ~w(channel_id thread_ts)),
           "delegations" => payload["delegations"] || [],
           "obligation_id" => obligation_id
         }
       }}
    else
      {:error, reason} -> {:error, reason, false}
    end
  end

  def apply(_claim, _opts), do: {:error, :invalid_product_obligation, false}

  defp communication(%{"kind" => "reply", "text" => text} = communication)
       when is_binary(text) and text != "" do
    {:ok,
     %{
       "kind" => "reply",
       "status" => "captured",
       "text" => text,
       "source_refs" => communication["source_refs"] || []
     }}
  end

  defp communication(%{"kind" => "reaction", "emoji" => emoji} = communication)
       when is_binary(emoji) and emoji != "" do
    {:ok,
     %{
       "kind" => "reaction",
       "status" => "captured",
       "emoji" => emoji,
       "source_refs" => communication["source_refs"] || []
     }}
  end

  defp communication(%{"kind" => "silence", "reason" => reason} = communication)
       when is_binary(reason) and reason != "" do
    {:ok,
     %{
       "kind" => "silence",
       "status" => "recorded",
       "reason" => reason,
       "source_refs" => communication["source_refs"] || []
     }}
  end

  defp communication(_communication), do: {:error, :invalid_communication}
end
