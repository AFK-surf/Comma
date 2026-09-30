defmodule SalixLlm.ProviderConfigReasoningTest do
  @moduledoc """
  `reasoning_effort` in llm_opts normalizes into the `reasoning` request param
  (the shape the Responses API takes). Callers that assemble opts from config —
  the trajectory-eval judge allowlist among them — rely on this seam to cap a
  reasoning model's effort per call.
  """
  use ExUnit.Case, async: true

  alias SalixLlm.ProviderConfig

  test "reasoning_effort normalizes to the reasoning param" do
    assert %{reasoning: %{"effort" => "low"}} =
             ProviderConfig.resolve(%{"model" => "m", "reasoning_effort" => "low"})

    # Atom-keyed opts (config.exs style) normalize the same way.
    assert %{reasoning: %{"effort" => "low"}} =
             ProviderConfig.resolve(model: "m", reasoning_effort: "low")
  end

  test "an explicit reasoning map wins over reasoning_effort" do
    assert %{reasoning: %{"effort" => "high", "summary" => "auto"}} =
             ProviderConfig.resolve(%{
               "reasoning" => %{"effort" => "high", "summary" => "auto"},
               "reasoning_effort" => "low"
             })
  end

  test "absent or blank effort yields no reasoning param" do
    assert %{reasoning: nil} = ProviderConfig.resolve(%{"model" => "m"})
    assert %{reasoning: nil} = ProviderConfig.resolve(%{"reasoning_effort" => ""})
    assert %{reasoning: nil} = ProviderConfig.resolve(%{"reasoning_effort" => 3})
  end
end
