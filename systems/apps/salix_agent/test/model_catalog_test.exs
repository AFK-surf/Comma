defmodule SalixAgent.ModelCatalogTest do
  use ExUnit.Case, async: true
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

  test "maps TokenDance catalog brands to the shared vendor keys" do
    for {name, title, vendor} <- [
          {"MoonshotAI: Kimi K2.5", "Kimi K2.5", "kimi"},
          {"Z.ai: GLM 4.7", "GLM 4.7", "glm"}
        ] do
      assert %{"name" => ^title, "vendor" => ^vendor} =
               ModelCatalog.normalize(@endpoint, %{"name" => name, "vendor" => nil})
    end
  end

  test "does not apply TokenDance formatting to a different origin or endpoint" do
    model = %{"id" => "qwen3.8-max", "name" => "Qwen: Custom name", "vendor" => nil}

    for endpoint <- [
          "https://example.com/v1",
          "https://tokendance.space.example.com/gateway/v1",
          "https://tokendance.space/another/v1",
          "http://tokendance.space/gateway/v1",
          "https://tokendance.space:8443/gateway/v1"
        ] do
      assert ModelCatalog.normalize(endpoint, model) == model
    end
  end

  test "preserves unknown prefixes, empty titles and an explicit conflicting vendor" do
    for model <- [
          %{"name" => "Research: experimental model", "vendor" => nil},
          %{"name" => "Qwen:", "vendor" => nil},
          %{"name" => "Qwen: Custom name", "vendor" => "anthropic"}
        ] do
      assert ModelCatalog.normalize(@endpoint, model) == model
    end
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

  test "distinguishes unknown declarations from no recognized protocol" do
    assert %{"supported_protocols" => []} =
             ModelCatalog.normalize(@endpoint, %{"supported_protocols" => []})

    assert %{"supported_protocols" => []} =
             ModelCatalog.normalize(@endpoint, %{"supported_protocols" => ["ark:tts"]})

    for model <- [
          %{},
          %{"supported_protocols" => nil},
          %{"supported_protocols" => "openai:responses"},
          %{"supported_protocols" => [nil]},
          %{"supported_protocols" => List.duplicate("openai:responses", 33)}
        ] do
      refute Map.has_key?(ModelCatalog.normalize(@endpoint, model), "supported_protocols")
    end
  end
end
