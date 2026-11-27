defmodule CommaWeb.ProactiveOwnerTest do
  use SystemsClock.Case, async: true

  alias CommaWeb.{ProactiveCheck, ProactiveOwner}

  describe "ProactiveOwner fail-closed station row ownership" do
    test "matches owner Comma email or personal-workspace bound device email and rejects nil or other users" do
      device_emails = %{"dev_mac" => "peng@stillfail.example"}

      own_comma = %{created_by: "Kai@Example.com", device_id: "dev_other"}
      own_bound = %{created_by: "peng@stillfail.example", device_id: "dev_mac"}
      nil_creator = %{created_by: nil, device_id: "dev_mac"}

      other_user = %{
        created_by: "teammate@example.com",
        device_id: "dev_mac",
        waits_for: ["kai@example.com"]
      }

      assert ProactiveOwner.station_row_owned_by?(own_comma, "kai@example.com", device_emails)
      assert ProactiveOwner.station_row_owned_by?(own_bound, "kai@example.com", device_emails)

      # Fail closed: unknown creator, unknown owner email (even with non-empty device_emails!),
      # or teammate-created row must not pass.
      refute ProactiveOwner.station_row_owned_by?(nil_creator, "kai@example.com", device_emails)
      refute ProactiveOwner.station_row_owned_by?(other_user, "kai@example.com", device_emails)
      refute ProactiveOwner.station_row_owned_by?(own_bound, nil, device_emails)
      refute ProactiveOwner.station_row_owned_by?(own_comma, nil, %{})
      refute ProactiveOwner.station_row_owned_by?(other_user, nil, %{})
      assert ProactiveOwner.matching_emails(own_bound, nil, device_emails) == []
    end

    test "device_owner_emails fails closed in shared workspaces (Alice vs Bob two-user isolation)" do
      shared_ws = %{
        "owner_user_id" => "usr_alice",
        "members" => [%{"user_id" => "usr_alice"}, %{"user_id" => "usr_bob"}]
      }

      personal_ws = %{
        "owner_user_id" => "usr_alice",
        "members" => [%{"user_id" => "usr_alice"}]
      }

      refute ProactiveOwner.personal_workspace_owner?(shared_ws, "usr_alice")
      refute ProactiveOwner.personal_workspace_owner?(shared_ws, "usr_bob")
      refute ProactiveOwner.personal_workspace_owner?(personal_ws, "usr_bob")
      assert ProactiveOwner.personal_workspace_owner?(personal_ws, "usr_alice")

      # In a shared workspace, device_owner_emails must return %{} for both Alice and Bob,
      # so Bob's row on Bob's device never passes for Alice.
      alice_device_emails =
        ProactiveOwner.device_owner_emails("grp_shared", "usr_alice", shared_ws)

      assert alice_device_emails == %{}

      bob_row = %{created_by: "bob@example.com", device_id: "dev_bob"}

      refute ProactiveOwner.station_row_owned_by?(
               bob_row,
               "alice@example.com",
               alice_device_emails
             )
    end
  end

  describe "ProactiveCheck.sanitize_message_links/3" do
    test "keeps verified https URLs and strips unverified markdown, autolink, bare, non-https, or junk-body links" do
      matter = %{
        "url" => "https://github.com/AFK-surf/Cue/pull/5590",
        "relationship" => "authored_by_you",
        "excerpt" => "See https://dexweekly.example/issues/373",
        "linked" => [%{"url" => "https://developer.apple.com/testflight/help"}]
      }

      msg =
        "Check [PR #5590](https://github.com/AFK-surf/Cue/pull/5590), " <>
          "[DEX](https://dexweekly.example/issues/373), " <>
          "[Docs](https://developer.apple.com/testflight/help), " <>
          "[Phish](https://evil.example/steal), " <>
          "<https://evil.example/auto>, " <>
          "https://evil.example/bare, " <>
          "and [JS](javascript:alert(1))."

      cleaned = ProactiveCheck.sanitize_message_links(msg, matter)
      assert cleaned =~ "[PR #5590](https://github.com/AFK-surf/Cue/pull/5590)"
      assert cleaned =~ "[DEX](https://dexweekly.example/issues/373)"
      assert cleaned =~ "[Docs](https://developer.apple.com/testflight/help)"
      refute cleaned =~ "https://evil.example/steal"
      refute cleaned =~ "https://evil.example/auto"
      refute cleaned =~ "https://evil.example/bare"
      refute cleaned =~ "javascript:"
      assert cleaned =~ "Phish"
      assert cleaned =~ "and JS."

      # Verified bare URLs are preserved, while unverified bare URLs in junk mail are stripped.
      assert ProactiveCheck.sanitize_message_links(
               "Read https://dexweekly.example/issues/373 now.",
               matter
             ) == "Read https://dexweekly.example/issues/373 now."

      # Junk mail body URLs are never treated as verified links (markdown OR bare).
      junk = %{
        "url" => "https://mail.google.com/mail/u/0/#spam/j1",
        "relationship" => "in_your_junk_folder",
        "excerpt" => "Claim prize at https://phish.example/claim"
      }

      assert ProactiveCheck.sanitize_message_links(
               "Open [claim](https://phish.example/claim) or https://phish.example/claim now.",
               junk
             ) == "Open claim or now."
    end
  end
end
