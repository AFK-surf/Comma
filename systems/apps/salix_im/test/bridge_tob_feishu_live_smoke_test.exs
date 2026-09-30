System.put_env("BRIDGE_TOB_LIVE_FEISHU_SKIP_RUN", "true")
Code.require_file("../../../scripts/bridge_tob_feishu_live_smoke.exs", __DIR__)

defmodule BridgeToB.FeishuLiveSmokeTest do
  use ExUnit.Case, async: true

  test "private group chat is ready when a human member is visible" do
    readiness =
      BridgeToB.FeishuLiveSmoke.classify_human_group_readiness(
        %{"chat_mode" => "group", "chat_type" => "private"},
        1
      )

    assert readiness["ok"] == true
    assert readiness["failure_codes"] == []
    assert readiness["chat_mode"] == "group"
  end

  test "p2p chat is not treated as a human group" do
    readiness =
      BridgeToB.FeishuLiveSmoke.classify_human_group_readiness(
        %{"chat_mode" => "p2p", "chat_type" => "private"},
        1
      )

    assert readiness["ok"] == false
    assert "bot_visible_chat_is_p2p" in readiness["failure_codes"]
  end

  test "visible Feishu Web marker changes real-inbound blocker diagnosis" do
    assert BridgeToB.FeishuLiveSmoke.real_inbound_claim(false, false, false, true) ==
             "live-real-feishu-web-marker-visible-delivery-not-observed"

    assert BridgeToB.FeishuLiveSmoke.real_inbound_next_action(false, false, false, true) =~
             "marker is visible in Feishu Web"
  end

  test "real inbound probe ignores synthetic signed preflight user messages" do
    refute BridgeToB.FeishuLiveSmoke.real_feishu_user_message?(%{
             role: "user",
             source_message_id: "im_provider:feishu:connect:om_synthetic",
             content: "bridge-tob-signed-preflight"
           })

    assert BridgeToB.FeishuLiveSmoke.real_feishu_user_message?(%{
             role: "user",
             source_message_id: "im_provider:feishu:connect:om_real",
             content: "real Feishu user message"
           })
  end

  test "message surface probe records unavailable Feishu send surfaces" do
    result =
      BridgeToB.FeishuLiveSmoke.message_surface_probe_result(
        "client_required_no_composer",
        "operator saw client handoff",
        "/tmp/redacted.png"
      )

    assert result["enabled"] == true
    assert result["ok"] == false
    assert result["failure_code"] == "no_usable_feishu_message_surface"
    assert result["next_action"] =~ "restore an authenticated Feishu Web composer"
    assert result["next_action"] =~ "only open/install the desktop client"
    assert result["operator_note_set"] == true
    assert result["redacted_screenshot_path"] == "/tmp/redacted.png"
    assert result["limits"]["account_identity_redacted"] == true
  end

  test "web login required message surface keeps desktop as a fallback" do
    result =
      BridgeToB.FeishuLiveSmoke.message_surface_probe_result(
        "web_login_required",
        "",
        ""
      )

    assert result["enabled"] == true
    assert result["ok"] == false
    assert result["failure_code"] == "feishu_web_login_required"
    assert result["next_action"] =~ "restore authenticated Feishu Web access"
    refute result["next_action"] =~ "desktop"
  end

  test "ready message surface records send-button and mention-picker signals" do
    result =
      BridgeToB.FeishuLiveSmoke.message_surface_probe_result(
        "ready",
        "",
        "",
        %{
          "send_button_confirmed" => true,
          "mention_picker_observed" => true,
          "marker_visible_after_send" => true
        }
      )

    assert result["enabled"] == true
    assert result["ok"] == true
    assert result["send_signals"]["send_button_confirmed"] == true
    assert result["send_signals"]["mention_picker_observed"] == true
    assert result["send_signals"]["marker_visible_after_send"] == true
  end

  test "chrome native pipe blocker records browser plugin repair action" do
    result =
      BridgeToB.FeishuLiveSmoke.message_surface_probe_result(
        "web_probe_blocked_by_chrome_native_pipe",
        "",
        ""
      )

    assert result["enabled"] == true
    assert result["ok"] == false
    assert result["failure_code"] == "chrome_native_pipe_closed"
    assert result["next_action"] =~ "repair the Codex Chrome plugin native-pipe connection"
    assert result["next_action"] =~ "restore authenticated Feishu Web access"
    assert result["next_action"] =~ "do not open/install the desktop client"
  end

  test "real inbound next action prioritizes restoring the Feishu message surface" do
    surface =
      BridgeToB.FeishuLiveSmoke.message_surface_probe_result(
        "client_required_no_composer",
        "",
        ""
      )

    next_action =
      BridgeToB.FeishuLiveSmoke.real_inbound_next_action(false, false, false, true, surface)

    assert next_action =~ "restore an authenticated Feishu Web target-group composer"
    assert next_action =~ "only try the desktop client after Web is explicitly unavailable"
  end

  test "observed chat probe diagnoses target chats missing from inbound events" do
    result =
      BridgeToB.FeishuLiveSmoke.observed_chat_probe_result(
        %{"chat_id" => "oc_target"},
        [%{"chat_id" => "oc_other"}]
      )

    assert result["attempted"] == true
    assert result["ok"] == false
    assert result["target_chat_observed"] == false
    assert result["selected_chat_id_prefix"] == "oc_targe"
    assert result["observed_chat_id_prefixes"] == ["oc_other"]
    assert result["next_action"] =~ "not been observed from inbound events"
  end

  test "delivery consistency probe diagnoses visible Web marker without inbound delivery" do
    result =
      BridgeToB.FeishuLiveSmoke.delivery_consistency_probe_result(
        %{"ok" => true},
        %{
          "human_group_readiness" => %{"ok" => true},
          "observed_chat_probe" => %{"target_chat_observed" => false}
        },
        %{
          "enabled" => true,
          "ok" => false,
          "feishu_web_marker_visible" => true,
          "feishu_user_messages_after_base" => 0
        }
      )

    assert result["attempted"] == true
    assert result["ok"] == false
    assert result["status"] == "visible_web_marker_not_delivered"
    assert result["failure_code"] == "feishu_platform_delivery_or_app_availability_unverified"
    assert result["signals"]["message_surface_ready"] == true
    assert result["signals"]["target_ready"] == true
    assert result["signals"]["target_chat_observed_from_inbound_events"] == false
    assert result["signals"]["feishu_web_marker_visible"] == true
    assert result["signals"]["feishu_user_messages_after_base"] == 0
    assert result["next_action"] =~ "app availability"
    assert result["limits"]["message_body_redacted"] == true
  end

  test "delivery consistency distinguishes successful bot outbound to selected group" do
    result =
      BridgeToB.FeishuLiveSmoke.delivery_consistency_probe_result(
        %{"ok" => true},
        %{
          "human_group_readiness" => %{"ok" => true},
          "observed_chat_probe" => %{"target_chat_observed" => false}
        },
        %{
          "enabled" => true,
          "ok" => false,
          "feishu_web_marker_visible" => true,
          "feishu_user_messages_after_base" => 0
        },
        %{"attempted" => true, "ok" => true}
      )

    assert result["ok"] == false
    assert result["status"] == "visible_web_marker_not_delivered_bot_outbound_ok"
    assert result["failure_code"] == "feishu_inbound_event_delivery_unverified"
    assert result["signals"]["bot_outbound_attempted"] == true
    assert result["signals"]["bot_outbound_to_selected_chat_ok"] == true
    assert result["next_action"] =~ "inbound event delivery logs"
  end

  test "selected chat identity records ready outbound-ok chat never observed inbound" do
    result =
      BridgeToB.FeishuLiveSmoke.selected_chat_identity_probe_result(
        %{
          "human_group_readiness" => %{
            "ok" => true,
            "chat_mode" => "group"
          },
          "member_probe" => %{"member_count" => 1},
          "observed_chat_probe" => %{"target_chat_observed" => false}
        },
        %{
          "enabled" => true,
          "ok" => false,
          "feishu_web_marker_visible" => true,
          "feishu_user_messages_after_base" => 0
        },
        %{"attempted" => true, "ok" => true}
      )

    assert result["attempted"] == true
    assert result["ok"] == false
    assert result["status"] == "ready_selected_chat_outbound_ok_but_never_observed_inbound"

    assert result["failure_code"] ==
             "feishu_inbound_delivery_or_selected_group_identity_unverified"

    assert result["signals"]["target_ready"] == true
    assert result["signals"]["target_chat_observed_from_inbound_events"] == false
    assert result["signals"]["target_member_count"] == 1
    assert result["signals"]["target_chat_mode"] == "group"
    assert result["signals"]["bot_outbound_to_selected_chat_ok"] == true
    assert result["next_action"] =~ "bot outbound proves the selected chat is writable"
    assert result["next_action"] =~ "same selected chat"
  end

  test "selected chat identity records Web and API hash match before delivery failure" do
    result =
      BridgeToB.FeishuLiveSmoke.selected_chat_identity_probe_result(
        %{
          "human_group_readiness" => %{
            "ok" => true,
            "chat_mode" => "group"
          },
          "member_probe" => %{"member_count" => 1},
          "observed_chat_probe" => %{"target_chat_observed" => false},
          "web_chat_identity_probe" => %{
            "attempted" => true,
            "ok" => true,
            "name_hash_match" => true,
            "name_length_match" => true
          }
        },
        %{
          "enabled" => true,
          "ok" => false,
          "feishu_web_marker_visible" => true,
          "feishu_user_messages_after_base" => 0
        },
        %{"attempted" => false}
      )

    assert result["attempted"] == true
    assert result["ok"] == false
    assert result["status"] == "ready_selected_chat_hash_match_but_never_observed_inbound"

    assert result["failure_code"] ==
             "feishu_inbound_delivery_unverified_after_group_hash_match"

    assert result["signals"]["web_chat_name_hash_match"] == true
    assert result["signals"]["web_chat_name_length_match"] == true
    assert result["next_action"] =~ "match by redacted hash"
    assert result["next_action"] =~ "event delivery"
  end

  test "delivery consistency distinguishes selected group outbound failure" do
    result =
      BridgeToB.FeishuLiveSmoke.delivery_consistency_probe_result(
        %{"ok" => true},
        %{
          "human_group_readiness" => %{"ok" => true},
          "observed_chat_probe" => %{"target_chat_observed" => false}
        },
        %{
          "enabled" => true,
          "ok" => false,
          "feishu_web_marker_visible" => true,
          "feishu_user_messages_after_base" => 0
        },
        %{"attempted" => true, "ok" => false}
      )

    assert result["ok"] == false
    assert result["status"] == "selected_chat_outbound_failed"
    assert result["failure_code"] == "feishu_app_availability_or_send_permission_unverified"
    assert result["signals"]["bot_outbound_attempted"] == true
    assert result["signals"]["bot_outbound_to_selected_chat_ok"] == false
    assert result["next_action"] =~ "app availability/install state"
  end
end
