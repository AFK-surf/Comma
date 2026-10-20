defmodule SalixAgent.ModelCatalogTest do
  use SystemsClock.Case, async: true
  alias SalixAgent.ModelCatalog

  @endpoint "https://tokendance.space/gateway/v1"

  test "returns a readable TokenDance name and vendor while retaining model identity and capabilities" do
    model = %{
      "id" => "qwen3.8-max",
      "name" => "Qwen: Qwen3.8 Max",
      "vendor" => nil,
      "supports_images" => false
    }

    assert %{
             "id" => "qwen3.8-max",
             "name" => "Qwen3.8 Max",
             "vendor" => "qwen",
             "supports_images" => false
           } == ModelCatalog.normalize(@endpoint, model)

    assert ModelCatalog.normalize(@endpoint <> "/", model) ==
             ModelCatalog.normalize(@endpoint, model)
  end

  test "normalizes and deduplicates declared LLM protocols without advertising other products" do
    model = %{
      "id" => "qwen3.8-max",
      "name" => "Qwen: Qwen3.8 Max",
      "vendor" => nil,
      "supported_protocols" => [
        "openai:responses",
        "openai:chat-completions",
        "anthropic:messages",
        "openai:responses",
        "openai:embeddings",
        "ark:tts"
      ]
    }

    assert %{"supported_protocols" => ["responses", "chat_completions", "anthropic"]} =
             ModelCatalog.normalize(@endpoint, model)

    refute Map.has_key?(
             ModelCatalog.normalize("https://example.com/v1", model),
             "supported_protocols"
           )
  end
end
