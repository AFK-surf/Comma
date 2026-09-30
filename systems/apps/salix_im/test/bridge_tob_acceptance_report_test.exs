System.put_env("BRIDGE_TOB_ACCEPTANCE_REPORT_SKIP_RUN", "true")
Code.require_file("../../../scripts/bridge_tob_acceptance_report.exs", __DIR__)

defmodule BridgeToB.AcceptanceReportTest do
  use ExUnit.Case, async: true

  test "sanitizes secret-like evidence fields but keeps redacted prefixes" do
    sanitized =
      BridgeToB.AcceptanceReport.sanitize(%{
        "verification_token" => "real-token",
        "raw_body" => "full payload",
        "user_email" => "person@example.com",
        "chat_id" => "oc_real",
        "chat_id_prefix" => "oc_reda",
        "limits" => %{"raw_chat_id_redacted" => true, "app_id_redacted" => true}
      })

    assert sanitized["verification_token"] == "[redacted]"
    assert sanitized["raw_body"] == "[redacted]"
    assert sanitized["user_email"] == "[redacted]"
    assert sanitized["chat_id"] == "[redacted]"
    assert sanitized["chat_id_prefix"] == "oc_reda"
    assert sanitized["limits"]["raw_chat_id_redacted"] == true
    assert sanitized["limits"]["app_id_redacted"] == true
  end

  test "does not claim customer usable without real inbound and same-group reply evidence" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"enabled" => true, "ok" => false},
          "real_inbound_probe" => %{
            "feishu_user_messages_after_base" => 0,
            "assistant_after_feishu_user" => false
          }
        }
      }
    ]

    refute BridgeToB.AcceptanceReport.customer_usable?(evidence)
    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)

    assert Enum.find(gates, &(&1["id"] == "signed_public_callback"))["ok"] == true
    assert Enum.find(gates, &(&1["id"] == "ready_human_group"))["ok"] == true
    assert Enum.find(gates, &(&1["id"] == "usable_message_surface"))["ok"] == false
    assert Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))["observed_count"] == 0

    assert Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))["next_action"] =~
             "send a fresh real Feishu @bot message"

    html =
      BridgeToB.AcceptanceReport.render_report(evidence, [], %{
        "title" => "Thread A Report",
        "git_head" => "e945ea4",
        "checks" => "green"
      })

    assert html =~ "Customer-usable claim"
    assert html =~ "Customer-usable Gates"
    assert html =~ "not proved"
    assert html =~ "usable_message_surface"
    assert html =~ "real_feishu_user_message"
    assert html =~ "Next action:"
    assert html =~ "e945ea4"
  end

  test "missing message surface evidence does not satisfy customer usable gates" do
    gates =
      BridgeToB.AcceptanceReport.customer_usable_gate_results([
        %{
          "data" => %{
            "signature_preflight" => %{"ok" => true},
            "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
            "real_inbound_probe" => %{
              "feishu_user_messages_after_base" => 1,
              "assistant_after_feishu_user" => true
            }
          }
        }
      ])

    refute Enum.find(gates, &(&1["id"] == "usable_message_surface"))["ok"]
    refute BridgeToB.AcceptanceReport.customer_usable?(gates)
  end

  test "customer usable gates merge separate live and message surface evidence" do
    gates =
      BridgeToB.AcceptanceReport.customer_usable_gate_results([
        %{
          "data" => %{
            "signature_preflight" => %{"ok" => true},
            "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
            "real_inbound_probe" => %{
              "feishu_user_messages_after_base" => 0,
              "assistant_after_feishu_user" => false
            }
          }
        },
        %{
          "data" => %{
            "message_surface_probe" => %{
              "enabled" => true,
              "ok" => false,
              "next_action" => "restore browser composer"
            }
          }
        }
      ])

    assert Enum.find(gates, &(&1["id"] == "signed_public_callback"))["ok"]
    assert Enum.find(gates, &(&1["id"] == "ready_human_group"))["ok"]
    refute Enum.find(gates, &(&1["id"] == "usable_message_surface"))["ok"]

    assert Enum.find(gates, &(&1["id"] == "usable_message_surface"))["next_action"] ==
             "restore browser composer"
  end

  test "delivery diagnostics narrow real inbound next action after console checks" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"enabled" => true, "ok" => true},
          "real_inbound_probe" => %{
            "feishu_user_messages_after_base" => 0,
            "assistant_after_feishu_user" => false
          }
        }
      },
      %{
        "data" => %{
          "console_probe" => %{"app_detail_opened" => true},
          "event_subscription_probe" => %{"receive_message_event_hint" => true},
          "permission_probe" => %{"receive_message_hint" => true},
          "version_publish_probe" => %{"published_hint" => true},
          "post_publish_marker_probe" => %{"fresh_marker_visible" => true}
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    real_inbound = Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))

    refute real_inbound["ok"]
    assert real_inbound["next_action"] =~ "Feishu platform event delivery"
    assert real_inbound["console_diagnostics"]["event_subscription_checked"] == true
    assert real_inbound["console_diagnostics"]["permission_checked"] == true
    assert real_inbound["console_diagnostics"]["version_publish_checked"] == true
    assert real_inbound["console_diagnostics"]["post_publish_marker_visible"] == true

    html = BridgeToB.AcceptanceReport.render_report(evidence, [], %{})

    assert html =~ "console_diagnostics="
    assert html =~ "post_publish_marker_visible"
  end

  test "delivery consistency narrows real inbound next action after visible marker" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"enabled" => true, "ok" => true},
          "real_inbound_probe" => %{
            "feishu_user_messages_after_base" => 0,
            "assistant_after_feishu_user" => false
          },
          "delivery_consistency_probe" => %{
            "attempted" => true,
            "ok" => false,
            "status" => "visible_web_marker_not_delivered",
            "failure_code" => "feishu_platform_delivery_or_app_availability_unverified",
            "next_action" =>
              "inspect Feishu app availability/install state for the selected group",
            "signals" => %{
              "message_surface_ready" => true,
              "target_ready" => true,
              "target_chat_observed_from_inbound_events" => false,
              "feishu_web_marker_visible" => true,
              "feishu_user_messages_after_base" => 0
            }
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    real_inbound = Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))

    refute real_inbound["ok"]
    assert real_inbound["next_action"] =~ "app availability/install"

    assert real_inbound["delivery_consistency"]["status"] ==
             "visible_web_marker_not_delivered"

    assert real_inbound["delivery_consistency"]["signals"]["feishu_web_marker_visible"] == true

    html = BridgeToB.AcceptanceReport.render_report(evidence, [], %{})

    assert html =~ "delivery_consistency=visible_web_marker_not_delivered"
  end

  test "same-app auxiliary event consumer evidence narrows real inbound next action" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"enabled" => true, "ok" => true},
          "real_inbound_probe" => %{
            "feishu_web_marker_visible" => true,
            "feishu_user_messages_after_base" => 0,
            "assistant_after_feishu_user" => false
          },
          "event_consumer_probe" => %{
            "attempted" => true,
            "ok" => false,
            "status" => "same_app_lark_cli_consumer_no_receive_event",
            "failure_code" => "lark_cli_consumer_no_receive_event",
            "event_count" => 0,
            "marker_prefix_seen" => false,
            "app_identity_match" => true,
            "next_action" =>
              "same app lark-cli consumer and developer-server both saw no receive event; inspect Feishu subscription mode, message scopes, app publish/install state"
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    real_inbound = Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))

    refute real_inbound["ok"]
    assert real_inbound["observed_count"] == 0
    assert real_inbound["next_action"] =~ "same app lark-cli consumer"

    assert real_inbound["event_consumer"]["status"] ==
             "same_app_lark_cli_consumer_no_receive_event"

    assert real_inbound["event_consumer"]["event_count"] == 0
    assert real_inbound["event_consumer"]["app_identity_match"] == true

    html = BridgeToB.AcceptanceReport.render_report(evidence, [], %{})

    assert html =~ "event_consumer=no_receive_event"
  end

  test "delivery consistency prefers selected-target outbound result over older marker-only diagnosis" do
    base = %{
      "signature_preflight" => %{"ok" => true},
      "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
      "message_surface_probe" => %{"enabled" => true, "ok" => true},
      "real_inbound_probe" => %{
        "feishu_user_messages_after_base" => 0,
        "assistant_after_feishu_user" => false
      }
    }

    evidence = [
      %{
        "data" =>
          Map.put(base, "delivery_consistency_probe", %{
            "attempted" => true,
            "ok" => false,
            "status" => "visible_web_marker_not_delivered",
            "failure_code" => "feishu_platform_delivery_or_app_availability_unverified",
            "next_action" => "older marker-only diagnosis"
          })
      },
      %{
        "data" =>
          Map.put(base, "delivery_consistency_probe", %{
            "attempted" => true,
            "ok" => false,
            "status" => "visible_web_marker_not_delivered_bot_outbound_ok",
            "failure_code" => "feishu_inbound_event_delivery_unverified",
            "next_action" => "bot outbound to the selected group works"
          })
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    real_inbound = Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))

    assert real_inbound["next_action"] == "bot outbound to the selected group works"

    assert real_inbound["delivery_consistency"]["status"] ==
             "visible_web_marker_not_delivered_bot_outbound_ok"
  end

  test "selected chat identity can be derived from older live evidence" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{
            "human_group_readiness" => %{"ok" => true, "chat_mode" => "group"},
            "member_probe" => %{"member_count" => 1},
            "observed_chat_probe" => %{"target_chat_observed" => false}
          },
          "message_surface_probe" => %{"enabled" => true, "ok" => true},
          "real_inbound_probe" => %{
            "feishu_web_marker_visible" => true,
            "feishu_user_messages_after_base" => 0,
            "assistant_after_feishu_user" => false
          },
          "outbound_send" => %{"attempted" => true, "ok" => true}
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    real_inbound = Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))

    refute real_inbound["ok"]
    assert real_inbound["next_action"] =~ "bot outbound proves the selected chat is writable"
    assert real_inbound["next_action"] =~ "same selected chat"

    assert real_inbound["selected_chat_identity"]["status"] ==
             "ready_selected_chat_outbound_ok_but_never_observed_inbound"

    assert real_inbound["selected_chat_identity"]["signals"]["target_chat_mode"] == "group"
    assert real_inbound["selected_chat_identity"]["signals"]["bot_outbound_to_selected_chat_ok"]

    html = BridgeToB.AcceptanceReport.render_report(evidence, [], %{})

    assert html =~
             "selected_identity=ready_selected_chat_outbound_ok_but_never_observed_inbound"
  end

  test "console recheck records missing receive-message delivery row" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"enabled" => true, "ok" => true},
          "real_inbound_probe" => %{
            "feishu_user_messages_after_base" => 0,
            "assistant_after_feishu_user" => false
          },
          "event_log_recheck_probe" => %{
            "attempted" => true,
            "receive_message_delivery_row_hint" => false,
            "empty_hint" => true
          },
          "app_availability_recheck_probe" => %{
            "attempted" => true,
            "enabled_or_published_hint" => true,
            "install_or_visibility_hint" => true
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    real_inbound = Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))

    assert real_inbound["console_recheck"]["event_log_checked"] == true
    assert real_inbound["console_recheck"]["receive_message_delivery_row_visible"] == false
    assert real_inbound["console_recheck"]["event_log_empty_hint"] == true
    assert real_inbound["console_recheck"]["app_enabled_or_published_hint"] == true

    html = BridgeToB.AcceptanceReport.render_report(evidence, [], %{})

    assert html =~ "console_recheck=no_receive_message_delivery_row"
  end

  test "post-Web-send diagnostics derive console recheck and hash-match identity" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{
            "status" => "ready",
            "marker_visible_after_send" => true
          },
          "real_inbound_probe" => %{
            "feishu_user_messages_after_base" => 0,
            "assistant_after_feishu_user" => false,
            "delivery_consistency" => "visible_web_marker_not_delivered"
          },
          "chat_identity_probe" => %{
            "name_hash_match" => true,
            "name_length_match" => true
          },
          "console_probe" => %{
            "event_page_accessible" => true,
            "receive_message_event_signal" => true,
            "event_log_page_accessible" => true,
            "event_log_receive_message_delivery_row_hint" => false,
            "event_log_receive_row_count" => 0,
            "permission_page_accessible" => true
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    message_surface = Enum.find(gates, &(&1["id"] == "usable_message_surface"))
    real_inbound = Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))

    assert message_surface["ok"] == true
    assert real_inbound["console_recheck"]["event_log_checked"] == true
    assert real_inbound["console_recheck"]["receive_message_delivery_row_visible"] == false
    assert real_inbound["console_recheck"]["app_enabled_or_published_hint"] == true
    assert real_inbound["delivery_consistency"]["status"] == "visible_web_marker_not_delivered"

    assert real_inbound["selected_chat_identity"]["status"] ==
             "ready_selected_chat_hash_match_but_never_observed_inbound"

    assert real_inbound["selected_chat_identity"]["signals"]["name_hash_match"] == true

    html = BridgeToB.AcceptanceReport.render_report(evidence, [], %{})

    assert html =~ "console_recheck=no_receive_message_delivery_row"
    assert html =~ "selected_identity=ready_selected_chat_hash_match_but_never_observed_inbound"
  end

  test "newer marker-window real inbound evidence wins over historical baseline counts" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"status" => "ready"},
          "real_inbound_probe" => %{
            "base_message_count" => 0,
            "feishu_user_messages_after_base" => 14,
            "assistant_after_feishu_user" => true
          }
        }
      },
      %{
        "data" => %{
          "real_inbound_probe" => %{
            "base_message_count" => 155,
            "feishu_user_messages_after_base" => 0,
            "assistant_after_feishu_user" => false
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    real_inbound = Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))
    reply = Enum.find(gates, &(&1["id"] == "same_group_assistant_reply"))

    refute real_inbound["ok"]
    assert real_inbound["observed_count"] == 0
    refute reply["ok"]

    html = BridgeToB.AcceptanceReport.render_report(evidence, [], %{})

    assert html =~ "observed_count=0"
    refute html =~ "observed_count=14"
  end

  test "latest signed callback evidence wins over stale successful callback evidence" do
    evidence = [
      %{
        "data" => %{
          "checked_at" => "2026-06-17T12:00:00Z",
          "signature_preflight" => %{"ok" => true, "http_status" => 200},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"status" => "ready"},
          "real_inbound_probe" => %{
            "base_message_count" => 160,
            "feishu_user_messages_after_base" => 1,
            "assistant_after_feishu_user" => true,
            "same_group_reply_observed" => true
          }
        }
      },
      %{
        "data" => %{
          "checked_at" => "2026-06-17T12:10:00Z",
          "signature_preflight" => %{
            "ok" => false,
            "http_status" => 502,
            "failure_code" => "callback_http_502"
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    signed_callback = Enum.find(gates, &(&1["id"] == "signed_public_callback"))

    refute signed_callback["ok"]
    assert signed_callback["http_status"] == 502
    assert signed_callback["next_action"] =~ "local Salix listener"
    refute BridgeToB.AcceptanceReport.customer_usable?(gates)
  end

  test "latest message surface blocker wins over stale ready surface evidence" do
    evidence = [
      %{
        "data" => %{
          "checked_at" => "2026-06-17T12:00:00Z",
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"status" => "ready"}
        }
      },
      %{
        "data" => %{
          "checked_at" => "2026-06-17T12:10:00Z",
          "message_surface_probe" => %{
            "enabled" => true,
            "ok" => false,
            "status" => "web_probe_blocked_by_chrome_native_pipe",
            "next_action" => "repair Chrome plugin connection"
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    message_surface = Enum.find(gates, &(&1["id"] == "usable_message_surface"))

    refute message_surface["ok"]
    assert message_surface["next_action"] == "repair Chrome plugin connection"
  end

  test "stored assistant message is not enough for same-group reply gate" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"status" => "ready"},
          "real_inbound_probe" => %{
            "base_message_count" => 180,
            "feishu_user_messages_after_base" => 1,
            "assistant_after_feishu_user" => true,
            "same_group_reply_observed" => false
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    inbound = Enum.find(gates, &(&1["id"] == "real_feishu_user_message"))
    same_group_reply = Enum.find(gates, &(&1["id"] == "same_group_assistant_reply"))

    assert inbound["ok"]
    refute same_group_reply["ok"]
    refute BridgeToB.AcceptanceReport.customer_usable?(gates)
  end

  test "same-group reply probe can satisfy same-group reply gate" do
    evidence = [
      %{
        "data" => %{
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"status" => "ready"},
          "real_inbound_probe" => %{
            "base_message_count" => 180,
            "feishu_user_messages_after_base" => 1,
            "assistant_after_feishu_user" => true,
            "same_group_reply_observed" => false
          },
          "same_group_reply_probe" => %{
            "ok" => true,
            "status" => "feishu_group_app_reply_after_user",
            "method" => "lark_cli_chat_messages_list",
            "limits" => %{"raw_message_body_redacted" => true}
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    same_group_reply = Enum.find(gates, &(&1["id"] == "same_group_assistant_reply"))

    assert same_group_reply["ok"]

    html = BridgeToB.AcceptanceReport.render_report(evidence, [], %{})

    assert html =~ "same_group_reply=feishu_group_app_reply_after_user"
    assert html =~ "lark_cli_chat_messages_list"
  end

  test "latest same-group reply probe wins over stale successful probe" do
    evidence = [
      %{
        "data" => %{
          "checked_at" => "2026-06-17T12:00:00Z",
          "signature_preflight" => %{"ok" => true},
          "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}},
          "message_surface_probe" => %{"status" => "ready"},
          "real_inbound_probe" => %{
            "base_message_count" => 180,
            "feishu_user_messages_after_base" => 1,
            "assistant_after_feishu_user" => true,
            "same_group_reply_observed" => false
          },
          "same_group_reply_probe" => %{
            "ok" => true,
            "status" => "feishu_group_app_reply_after_user",
            "method" => "lark_cli_chat_messages_list"
          }
        }
      },
      %{
        "data" => %{
          "checked_at" => "2026-06-17T12:05:00Z",
          "same_group_reply_probe" => %{
            "ok" => false,
            "status" => "no_app_reply_after_latest_user",
            "method" => "lark_cli_chat_messages_list",
            "next_action" => "wait for bot reply or inspect outbound send"
          }
        }
      }
    ]

    gates = BridgeToB.AcceptanceReport.customer_usable_gate_results(evidence)
    same_group_reply = Enum.find(gates, &(&1["id"] == "same_group_assistant_reply"))

    refute same_group_reply["ok"]
    assert same_group_reply["next_action"] == "wait for bot reply or inspect outbound send"
  end

  test "missing message surface evidence defaults to Web-first next action" do
    gates =
      BridgeToB.AcceptanceReport.customer_usable_gate_results([
        %{
          "data" => %{
            "signed_callback_preflight" => %{"response" => %{"ok" => true, "status" => "queued"}},
            "target_chat_probe" => %{"human_group_readiness" => %{"ok" => true}}
          }
        }
      ])

    next_action = Enum.find(gates, &(&1["id"] == "usable_message_surface"))["next_action"]

    assert next_action =~ "restore an authenticated Feishu Web composer"
    assert next_action =~ "only try the desktop client after Web is explicitly unavailable"
  end

  test "renders screenshots from manifest entries" do
    html =
      BridgeToB.AcceptanceReport.render_report(
        [],
        [
          %{
            "path" => "assets/redacted.png",
            "title" => "Feishu client handoff",
            "caption" => "Redacted screenshot"
          }
        ],
        %{}
      )

    assert html =~ ~s(src="assets/redacted.png")
    assert html =~ "Feishu client handoff"
    assert html =~ "Redacted screenshot"
  end
end
