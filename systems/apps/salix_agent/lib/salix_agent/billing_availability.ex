defmodule SalixAgent.BillingAvailability do
  @moduledoc "Financial refusal results shared by paid runtime operations."

  @denials ~w(insufficient_credits account_inactive missing_account)

  def error({:billing_unavailable, decision}), do: error(decision)

  def error(decision) when is_map(decision) do
    reason = Map.get(decision, :reason) || Map.get(decision, "reason") || "fee_control_error"

    %{
      "error_class" => "billing_unavailable",
      "reason" => reason,
      "retryable" => reason not in @denials,
      "message" => message(reason)
    }
  end

  def denied?({:error, reason}), do: denied?(reason)

  def denied?({:billing_unavailable, decision}) when is_map(decision),
    do: (Map.get(decision, :reason) || Map.get(decision, "reason")) in @denials

  def denied?(%{"error_class" => "billing_unavailable", "reason" => reason}),
    do: reason in @denials

  def denied?(_), do: false

  defp message("insufficient_credits"), do: "Not enough credits. Add credits and try again."
  defp message("account_inactive"), do: "This billing account is unavailable."
  defp message("missing_account"), do: "This operation has no billing account."
  defp message(_), do: "Billing is temporarily unavailable. Try again later."
end
