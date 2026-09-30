defmodule SalixMediaTest do
  @moduledoc """
  Media generation and vision clients: each Req client POSTs a
  well-formed request to a mock provider server (Bandit on a random port) and
  parses the canned response, plus per-turn cap enforcement via
  `SalixMedia.Caps`.
  """
  use ExUnit.Case, async: false

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
    test "centralizes chat token cap parameter selection" do
      assert %{"max_completion_tokens" => 10} =
               SalixMedia.OpenAICompat.put_chat_max_tokens(%{}, "openai/gpt-5-mini", 10)

      assert %{"max_completion_tokens" => 10} =
               SalixMedia.OpenAICompat.put_chat_max_tokens(%{}, "o4-mini", 10)

      assert %{"max_tokens" => 10} =
               SalixMedia.OpenAICompat.put_chat_max_tokens(%{}, "gpt-4o-mini", 10)
    end
  end

  describe "Caps.check/2 (pure per-turn limits)" do
    test "allows image.generate up to 2 and rejects the 3rd" do
      assert :ok = Caps.check(%{}, "image.generate")
      assert :ok = Caps.check(%{"image.generate" => 1}, "image.generate")
      assert {:error, :cap_exceeded} = Caps.check(%{"image.generate" => 2}, "image.generate")
    end

    test "allows video.generate once and rejects the 2nd" do
      assert :ok = Caps.check(%{}, "video.generate")
      assert {:error, :cap_exceeded} = Caps.check(%{"video.generate" => 1}, "video.generate")
    end

    test "allows script.run up to 5 and rejects the 6th" do
      assert :ok = Caps.check(%{"script.run" => 4}, "script.run")
      assert {:error, :cap_exceeded} = Caps.check(%{"script.run" => 5}, "script.run")
    end

    test "unknown tools are uncapped" do
      assert :ok = Caps.check(%{"fs.read_file" => 999}, "fs.read_file")
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

      prev = Application.get_env(:salix_media, :base_url)
      prev_key = Application.get_env(:salix_media, :api_key)
      Application.put_env(:salix_media, :base_url, "http://127.0.0.1:#{port}")
      Application.put_env(:salix_media, :api_key, "test-key")

      on_exit(fn ->
        Application.put_env(:salix_media, :base_url, prev)
        Application.put_env(:salix_media, :api_key, prev_key)
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

    test "ImageGen parses a base64 response" do
      SalixMedia.MockMedia.set("/v1/images/generations", %{
        "data" => [%{"b64_json" => "aGVsbG8="}]
      })

      assert {:ok, %{b64: "aGVsbG8="}} = ImageGen.generate("a cat")
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
                     "endpoint" => Application.get_env(:salix_media, :base_url),
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

    test "facade delegates to the right client" do
      SalixMedia.MockMedia.set("/v1/images/generations", %{
        "data" => [%{"url" => "https://cdn/x.png"}]
      })

      assert {:ok, %{url: "https://cdn/x.png"}} = SalixMedia.image("hello")
    end

    test "a malformed provider response is a tagged error" do
      SalixMedia.MockMedia.set("/v1/images/generations", %{"unexpected" => true})
      assert {:error, {:bad_response, %{"unexpected" => true}}} = ImageGen.generate("x")
    end
  end
end
