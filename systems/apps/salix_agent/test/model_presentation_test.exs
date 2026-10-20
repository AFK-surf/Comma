defmodule SalixAgent.ModelPresentationTest do
  use SystemsClock.Case, async: true

  test "normalizes saved TokenDance display metadata without changing the model record or its alias" do
    record = %{
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

    public = SalixAgent.ModelChoice.public_json(record)

    assert %{
             "name" => "My router",
             "model" => "qwen3.8-max",
             "model_display_name" => "Qwen3.8 Max",
             "model_vendor" => "qwen",
             "model_icon" => "qwen"
           } = public

    refute inspect(public) =~ "private-key"
  end
end
