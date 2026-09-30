defmodule BillingCore.Metering.LLMUsageSink do
  @moduledoc """
  Background LLM usage delivery. Failed batches stay in the bounded ETS queue.
  Repeated rows preserve their version and source key. Ledger debits are idempotent.
  """

  def insert(entries) do
    Enum.reduce_while(entries, {:ok, 0}, fn %{row: row, fact: fact}, {:ok, count} ->
      case BillingCore.LLMMetering.deliver(row, fact) do
        :ok -> {:cont, {:ok, count + 1}}
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:pending, _} -> {:cont, {:ok, count + 1}}
        error -> {:halt, error}
      end
    end)
  end
end
