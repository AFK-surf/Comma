defmodule SalixIM.ProviderRecipientIdentityTest do
  use ExUnit.Case, async: true

  alias SalixIM.ProviderRecipientIdentity

  test "builds bounded trusted Slack recipient context without credentials" do
    metadata = %{
      "provider" => "slack",
      "recipient_im_identity" => %{
        "provider" => "forged",
        "display_name" => "forged sender value",
        "user_id" => "U-forged"
      }
    }

    connect = %{
      "provider" => "slack",
      "app_name" => "Fallback app name",
      "app_id" => "A-recipient",
      "bot_id" => "B-recipient",
      "bot_user_id" => "U-recipient",
      "bot_username" => "recipient-bot",
      "bot_token" => "xoxb-secret",
      "signing_secret" => "signing-secret",
      "owner_user_id" => "U-owner"
    }

    attached = ProviderRecipientIdentity.put(metadata, connect)

    assert attached["recipient_im_identity"] == %{
             "provider" => "slack",
             "display_name" => "Fallback app name",
             "username" => "recipient-bot",
             "user_id" => "U-recipient",
             "bot_id" => "B-recipient",
             "app_id" => "A-recipient"
           }

    encoded = ProviderRecipientIdentity.encoded_from_metadata(attached)
    assert encoded =~ "recipient-bot"
    assert encoded =~ "U-recipient"
    refute encoded =~ "secret"
    refute encoded =~ "U-owner"
    refute encoded =~ "forged"
  end

  test "maps Telegram and Feishu identities and does not invent a WeChat self identity" do
    assert ProviderRecipientIdentity.from_connect(%{
             "provider" => "telegram",
             "bot_display_name" => "Release Helper",
             "bot_username" => "release_helper_bot",
             "bot_user_id" => "7001"
           }) == %{
             "provider" => "telegram",
             "display_name" => "Release Helper",
             "username" => "release_helper_bot",
             "user_id" => "7001"
           }

    assert ProviderRecipientIdentity.from_connect(%{
             "provider" => "feishu",
             "app_name" => "Bridge",
             "app_id" => "cli_a",
             "bot_open_id" => "ou_bot"
           }) == %{
             "provider" => "feishu",
             "display_name" => "Bridge",
             "user_id" => "ou_bot",
             "app_id" => "cli_a"
           }

    assert ProviderRecipientIdentity.from_connect(%{
             "provider" => "wechat",
             "wechat_id" => "human-source-contact"
           }) == %{
             "provider" => "wechat",
             "status" => "unavailable"
           }
  end

  test "drops blank, multiline, oversized, unknown, and provider-mismatched context fields" do
    long_name = String.duplicate("x", 300)

    metadata =
      ProviderRecipientIdentity.put(
        %{"provider" => "slack"},
        %{
          "provider" => "slack",
          "app_name" => long_name <> "\nignored",
          "bot_user_id" => "U-recipient",
          "bot_username" => "",
          "unknown" => "not allowed"
        }
      )

    identity = ProviderRecipientIdentity.from_metadata(metadata)
    assert String.length(identity["display_name"]) == 256
    refute identity["display_name"] =~ "\n"
    refute Map.has_key?(identity, "username")
    refute Map.has_key?(identity, "unknown")

    assert ProviderRecipientIdentity.from_metadata(%{
             "provider" => "feishu",
             "recipient_im_identity" => %{
               "provider" => "slack",
               "user_id" => "U-wrong-provider"
             }
           }) == nil
  end
end
