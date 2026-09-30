defmodule SalixAgent.ModelPresentationTest do
  use ExUnit.Case, async: true

  test "uses the model family for a provider-prefixed Qwen model" do
    template = %{
      "model" => "@preset/qwen-3-8-27b-coreweave",
      "provider_config" => %{"base_url" => "https://example.com/v1"}
    }

    assert %{"model_vendor" => "qwen", "model_icon" => "qwen"} =
             SalixAgent.ModelPresentation.public(template)
  end

  test "normalizes saved TokenDance display metadata without changing the template or its alias" do
    template = %{
      "model" => "qwen3.8-max",
      "name" => "My router",
      "model_display_name" => "Qwen: Qwen3.8 Max",
      "model_vendor" => nil,
      "provider" => "openai",
      "provider_config" => %{
        "base_url" => "https://tokendance.space/gateway/v1",
        "protocol" => "responses",
        "api_key" => "private-key"
      }
    }

    public = SalixAgent.Templates.public_json(template)

    assert %{
             "name" => "My router",
             "model" => "qwen3.8-max",
             "model_display_name" => "Qwen3.8 Max",
             "model_vendor" => "qwen",
             "model_icon" => "qwen"
           } = public

    refute inspect(public) =~ "private-key"
  end

  test "preserves display names from other sources and identifies Qwen without a separator" do
    template = %{
      "model" => "qwen3.8-max",
      "model_display_name" => "Qwen: My custom name",
      "provider_config" => %{"base_url" => "https://example.com/v1"}
    }

    assert %{"model_display_name" => "Qwen: My custom name", "model_vendor" => "qwen"} =
             SalixAgent.ModelPresentation.public(template)
  end
end
