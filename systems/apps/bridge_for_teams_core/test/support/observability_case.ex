defmodule BridgeForTeams.ObservabilityCase do
  @moduledoc """
  Test helpers for Operations producer contracts.
  """

  import ExUnit.Assertions

  alias BridgeForTeams.Observability.Producer

  @doc """
  Assert that a producer publishes a valid Operations integration contract.
  """
  def assert_observability_contract!(module, expected \\ %{}) do
    contract = Producer.validate_contract!(module)

    Enum.each(expected, fn {key, expected_value} ->
      assert Map.fetch!(contract, key) == expected_value
    end)

    contract
  end
end
