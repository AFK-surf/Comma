defmodule SalixMediaTest do
  @moduledoc """
  Media generation and vision clients: each Req client POSTs a
  well-formed request to a mock provider server (Bandit on a random port) and
  parses the canned response, plus per-turn cap enforcement via
  `SalixMedia.Caps`.
  """
  use SystemsClock.Case, async: false

  alias SalixMedia.{ImageGen, VideoGen, Vision, Caps}

  test "subscription image edits send reference bytes and honor the returned format" do
    transport = fn url, opts ->
      assert url == "subscription://worker/v1/images/edits"
      assert opts[:json]["images"] == [%{"image_url" => "data:image/png;base64,aW1hZ2U="}]

      {:ok,
       Req.Response.new(
         status: 200,
         body:
           Jason.encode!(%{
             "data" => [%{"b64_json" => "ZWRpdGVk"}],
             "output_format" => "png"
           })
       )}
    end

    cfg = %{
      "provider" => "openai",
      "model" => "gpt-image-2",
      "provider_config" => %{"base_url" => "subscription://worker/v1", "account_pool" => "codex"}
    }

    assert {:error, :subscription_transport_required} = ImageGen.generate("edit", config: cfg)

    assert {:ok, %{b64: "ZWRpdGVk", mime_type: "image/png"}} =
             ImageGen.generate("edit",
               config: cfg,
               transport: transport,
               format: "jpeg",
               input_images: [%{mime_type: "image/png", data: "image"}]
             )
  end

  describe "OpenAICompat.put_chat_max_tokens/3" do
  end

  describe "Caps.check/2 (pure per-turn limits)" do
    test "allows image.generate up to 2 and rejects the 3rd" do
      assert :ok = Caps.check(%{}, "image.generate")
      assert :ok = Caps.check(%{"image.generate" => 1}, "image.generate")
      assert {:error, :cap_exceeded} = Caps.check(%{"image.generate" => 2}, "image.generate")
    end
  end

  describe "clients against a mock server" do
    setup do
      start_supervised!(SalixMedia.MockMedia)

      bandit =
        start_supervised!(
          {Bandit, plug: SalixMedia.MockMedia, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

      prev = SystemsRuntime.get_env(:salix_media, :base_url)
      prev_key = SystemsRuntime.get_env(:salix_media, :api_key)
      SystemsRuntime.put_env(:salix_media, :base_url, "http://127.0.0.1:#{port}")
      SystemsRuntime.put_env(:salix_media, :api_key, "test-key")

      on_exit(fn ->
        SystemsRuntime.put_env(:salix_media, :base_url, prev)
        SystemsRuntime.put_env(:salix_media, :api_key, prev_key)
      end)

      :ok
    end

    test "ImageGen posts a well-formed request and parses a url response" do
      SalixMedia.MockMedia.set("/v1/images/generations", %{
        "data" => [%{"url" => "https://cdn/img-1.png"}]
      })

      assert {:ok, %{url: "https://cdn/img-1.png"}} =
               ImageGen.generate("a red fox", size: "1024x1024")

      assert SalixMedia.MockMedia.last_path() == "/v1/images/generations"
      req = SalixMedia.MockMedia.last_request()
      assert req["prompt"] == "a red fox"
      assert req["size"] == "1024x1024"
      assert req["n"] == 1
    end

    test "VideoGen posts a well-formed request and parses a url response" do
      SalixMedia.MockMedia.set("/v1/videos/generations", %{
        "video" => %{"url" => "https://cdn/clip-1.mp4"}
      })

      assert {:ok, %{url: "https://cdn/clip-1.mp4"}} =
               VideoGen.generate("waves at dusk", duration: 4)

      assert SalixMedia.MockMedia.last_path() == "/v1/videos/generations"
      req = SalixMedia.MockMedia.last_request()
      assert req["prompt"] == "waves at dusk"
      assert req["duration"] == 4
    end

    test "Vision posts the image reference and parses a description" do
      SalixMedia.MockMedia.set("/v1/vision", %{"description" => "A red fox in snow."})

      assert {:ok, %{description: "A red fox in snow."}} =
               Vision.generate("https://cdn/img-1.png", question: "What is this?")

      assert SalixMedia.MockMedia.last_path() == "/v1/vision"
      req = SalixMedia.MockMedia.last_request()
      assert req["image_url"] == "https://cdn/img-1.png"
      assert req["question"] == "What is this?"
    end

    # {name, model, max tokens, description, token field sent, token field omitted}
    @vision_token_field_cases [
      {"Vision describe uses max_completion_tokens for newer OpenAI chat models",
       "openai/gpt-5-mini", 321, "A UI screenshot.", "max_completion_tokens", "max_tokens"},
      {"Vision describe keeps max_tokens for legacy chat models", "gpt-4o-mini", 123, "A chart.",
       "max_tokens", "max_completion_tokens"}
    ]

    for {name, model, max_tokens, description, sent, omitted} <- @vision_token_field_cases do
      test name do
        SalixMedia.MockMedia.set("/chat/completions", %{
          "choices" => [%{"message" => %{"content" => unquote(description)}}],
          "usage" => %{"total_tokens" => 12}
        })

        assert {:ok, %{description: unquote(description), usage: %{"total_tokens" => 12}}} =
                 Vision.describe("https://cdn/ui.png",
                   question: "Describe",
                   config: %{
                     "endpoint" => SystemsRuntime.get_env(:salix_media, :base_url),
                     "model" => unquote(model),
                     "max_tokens" => unquote(max_tokens)
                   }
                 )

        assert SalixMedia.MockMedia.last_path() == "/chat/completions"
        req = SalixMedia.MockMedia.last_request()
        assert req["model"] == unquote(model)
        assert req[unquote(sent)] == unquote(max_tokens)
        refute Map.has_key?(req, unquote(omitted))
      end
    end
  end
end
