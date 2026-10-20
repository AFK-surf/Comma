defmodule SalixAgent.MediaSettingsTest do
  @moduledoc """
  An Agent's model choice takes the platform's media settings, which
  give it image, video, vision and analysis models, and image input follows
  the chosen model.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{MediaSettings, ModelChoice}

  setup do
    start_supervised!(SalixStore.S3.Fake)
    {:ok, tenant: SalixAgent.TestSupport.new_tenant_id()}
  end

  test "a model choice takes the platform's media settings", %{tenant: tenant} do
    {:ok, choice} = ModelChoice.choose(%{"kind" => "catalog", "model" => "gpt-5.5"}, tenant)

    assert {:ok, media} = ModelChoice.media(choice, tenant)
    assert media["image_config"] == %{}
    assert media["analyze_config"] == %{}
    assert media["supports_images"] == true

    image = %{
      "provider" => "openai",
      "model" => "gpt-image-2",
      "provider_config" => %{"base_url" => "https://images.example.test/v1"}
    }

    analyze = %{"endpoint" => "https://llm.example.test/v1", "model" => "gpt-5.4-nano"}

    assert {:ok, _} = MediaSettings.put(%{"image_config" => image, "analyze_config" => analyze})

    assert {:ok, media} = ModelChoice.media(choice, tenant)
    assert media["image_config"] == image
    assert SalixAgent.MediaResolver.generation_configured?(media["image_config"])
    # The platform pays for analysis, as for any model choice.
    assert media["analyze_config"] == Map.put(analyze, "credential_scope", "platform")

    # Clearing a purpose turns it off; an unknown purpose is refused.
    assert {:ok, settings} =
             MediaSettings.put(%{"image_config" => nil, "analyze_config" => analyze})

    refute Map.has_key?(settings, "image_config")
    assert {:error, :invalid_media_settings} = MediaSettings.put(%{"audio_config" => %{}})
  end
end
