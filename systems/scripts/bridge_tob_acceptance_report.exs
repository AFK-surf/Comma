unless System.get_env("BRIDGE_TOB_ACCEPTANCE_REPORT_SKIP_RUN") == "true" do
  Logger.configure(level: :warning)
end

defmodule BridgeToB.AcceptanceReport do
  @moduledoc false

  @default_report_path "/tmp/bridge-tob-acceptance-report.html"

  @sensitive_key_parts [
    "authorization",
    "token",
    "secret",
    "email",
    "app_id",
    "chat_id",
    "open_id",
    "union_id",
    "user_id",
    "raw",
    "body",
    "argv"
  ]

  @allowed_sensitive_keys MapSet.new([
                            "chat_id_prefix",
                            "selected_chat_id_prefix",
                            "observed_chat_id_prefixes",
                            "raw_chat_id_redacted",
                            "raw_chat_ids_redacted",
                            "raw_secret_redacted",
                            "raw_token_redacted",
                            "raw_body_redacted"
                          ])

  def run do
    evidence_paths = split_env("BRIDGE_TOB_ACCEPTANCE_REPORT_EVIDENCE_PATHS")
    screenshot_manifest = env("BRIDGE_TOB_ACCEPTANCE_REPORT_SCREENSHOTS", "")
    report_path = env("BRIDGE_TOB_ACCEPTANCE_REPORT_PATH", @default_report_path)

    evidence =
      evidence_paths
      |> Enum.map(&load_json_file!/1)
      |> Enum.map(fn {path, data} -> %{"path" => path, "data" => data} end)

    screenshots =
      case screenshot_manifest do
        "" -> []
        path -> load_screenshot_manifest!(path)
      end

    html =
      render_report(evidence, screenshots, %{
        "title" => env("BRIDGE_TOB_ACCEPTANCE_REPORT_TITLE", "Bridge ToB Acceptance Report"),
        "pr_url" => env("BRIDGE_TOB_ACCEPTANCE_REPORT_PR_URL", ""),
        "git_head" => env("BRIDGE_TOB_ACCEPTANCE_REPORT_GIT_HEAD", ""),
        "checks" => env("BRIDGE_TOB_ACCEPTANCE_REPORT_CHECKS", "")
      })

    File.mkdir_p!(Path.dirname(report_path))
    File.write!(report_path, html)
    IO.puts(report_path)
  end

  def render_report(evidence, screenshots, opts \\ %{}) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    sanitized_evidence = Enum.map(evidence, &sanitize/1)
    gate_results = customer_usable_gate_results(evidence)
    usable = customer_usable?(gate_results)

    """
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>#{esc(opts["title"] || "Bridge ToB Acceptance Report")}</title>
      <style>
        body { margin: 0; background: #f7f8fb; color: #172033; font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        main { max-width: 1120px; margin: 0 auto; padding: 32px 24px 56px; }
        h1 { margin: 0 0 8px; font-size: 30px; line-height: 1.2; letter-spacing: 0; }
        h2 { margin: 28px 0 12px; font-size: 20px; letter-spacing: 0; }
        .note { color: #667085; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 12px; }
        .card, figure { background: #fff; border: 1px solid #d9dee8; border-radius: 8px; padding: 16px; margin: 14px 0; }
        .ok { color: #0f8a4b; font-weight: 700; }
        .bad { color: #b42318; font-weight: 700; }
        code, pre { background: #eef2f8; border-radius: 4px; }
        code { padding: 1px 5px; }
        pre { overflow-x: auto; padding: 12px; }
        img { display: block; max-width: 100%; height: auto; border: 1px solid #d9dee8; }
        figcaption { color: #667085; margin-top: 8px; }
      </style>
    </head>
    <body>
      <main>
        <h1>#{esc(opts["title"] || "Bridge ToB Acceptance Report")}</h1>
        <p class="note">Generated: <code>#{esc(generated_at)}</code></p>
        #{summary_html(opts, usable)}
        #{customer_usable_gates_html(gate_results)}
        #{evidence_html(sanitized_evidence)}
        #{screenshots_html(screenshots)}
      </main>
    </body>
    </html>
    """
  end

  def customer_usable?(evidence_or_results) do
    evidence_or_results
    |> customer_usable_gate_results()
    |> Enum.all?(& &1["ok"])
  end

  def customer_usable_gate_results(results) when is_list(results) do
    if Enum.all?(results, &gate_result?/1) do
      results
    else
      evidence_gate_results(results)
    end
  end

  def customer_usable_gate_results(evidence), do: evidence_gate_results(evidence)

  defp evidence_gate_results(evidence) do
    entries = evidence |> List.wrap() |> Enum.map(&Map.get(&1, "data", &1))
    signature_preflight = best_signature_preflight(entries)
    real_inbound = best_real_inbound_probe(entries)
    inbound_count = real_inbound_count(real_inbound)
    message_surface = best_message_surface_probe(entries)
    delivery_diagnostics = best_delivery_diagnostics(entries)
    delivery_consistency = best_delivery_consistency(entries)
    console_recheck = best_console_recheck(entries)
    selected_identity = best_selected_identity(entries)
    event_consumer = best_event_consumer_probe(entries)
    same_group_reply = best_same_group_reply_probe(entries)

    [
      gate_result(
        "signed_public_callback",
        signature_preflight["ok"] == true,
        "signed Feishu-style callback preflight reached the public webhook and returned queued",
        signature_preflight_next_action(signature_preflight),
        signature_preflight_extra(signature_preflight)
      ),
      gate_result(
        "ready_human_group",
        any_path?(entries, ["target_chat_probe", "human_group_readiness", "ok"]),
        "target Feishu chat is classified as a human group, not a p2p/bot-only chat",
        "select or create a bot-visible Feishu group with a human member, then rerun target chat readiness"
      ),
      gate_result(
        "usable_message_surface",
        message_surface_ready?(message_surface),
        "operator/browser can send a fresh real Feishu @bot message",
        message_surface_next_action(message_surface)
      ),
      gate_result(
        "real_feishu_user_message",
        inbound_count > 0,
        "Salix observed at least one non-synthetic Feishu-sourced user message after the base count",
        real_feishu_user_message_next_action(
          delivery_diagnostics,
          delivery_consistency,
          selected_identity,
          event_consumer
        ),
        delivery_extra(
          inbound_count,
          delivery_diagnostics,
          delivery_consistency,
          console_recheck,
          selected_identity,
          event_consumer
        )
      ),
      gate_result(
        "same_group_assistant_reply",
        real_inbound["same_group_reply_observed"] == true or same_group_reply["ok"] == true,
        "a Bridge/Codex assistant reply was observed after the real Feishu user message in the same group",
        same_group_reply_next_action(same_group_reply),
        same_group_reply_extra(same_group_reply)
      )
    ]
  end

  defp best_signature_preflight(entries) do
    entries
    |> Enum.map(fn entry -> {entry_checked_at(entry), get_in(entry, ["signature_preflight"])} end)
    |> Enum.reject(fn {_checked_at, probe} -> is_nil(probe) end)
    |> Enum.sort_by(
      fn {checked_at, probe} ->
        {timestamp_rank(checked_at), checked_at || "", signature_preflight_score(probe)}
      end,
      :desc
    )
    |> List.first()
    |> case do
      nil -> %{}
      {_checked_at, probe} -> probe
    end
  end

  defp signature_preflight_score(%{"ok" => true}), do: 1
  defp signature_preflight_score(_), do: 0

  defp signature_preflight_next_action(%{"next_action" => action})
       when is_binary(action) and action != "",
       do: action

  defp signature_preflight_next_action(%{"failure_code" => "callback_http_502"}),
    do:
      "restore the local Salix listener and public tunnel, then rerun URL-verification and signed callback preflights before sending another real marker"

  defp signature_preflight_next_action(_),
    do:
      "restore public callback health, synchronize Feishu verification token/signature settings, then rerun the signed callback preflight"

  defp signature_preflight_extra(%{"http_status" => status}) when is_number(status),
    do: %{"http_status" => status}

  defp signature_preflight_extra(_), do: %{}

  defp best_real_inbound_probe(entries) do
    entries
    |> Enum.map(&get_in(&1, ["real_inbound_probe"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&real_inbound_score/1, :desc)
    |> List.first()
    |> case do
      nil -> %{}
      probe -> probe
    end
  end

  defp real_inbound_score(probe) do
    base_count = probe["base_message_count"]
    has_base? = is_number(base_count)
    inbound_count = real_inbound_count(probe)

    ok_score =
      cond do
        probe["ok"] == true -> 2
        inbound_count > 0 -> 1
        true -> 0
      end

    {
      if(has_base?, do: 1, else: 0),
      if(has_base?, do: base_count, else: -1),
      ok_score,
      inbound_count
    }
  end

  defp real_inbound_count(%{"feishu_user_messages_after_base" => count}) when is_number(count),
    do: count

  defp real_inbound_count(_), do: 0

  defp any_path?(entries, path) do
    Enum.any?(entries, &(get_in(&1, path) == true))
  end

  defp best_message_surface_probe(entries) do
    entries
    |> Enum.map(fn entry ->
      {entry_checked_at(entry), get_in(entry, ["message_surface_probe"])}
    end)
    |> Enum.reject(fn {_checked_at, probe} -> is_nil(probe) end)
    |> Enum.sort_by(
      fn {checked_at, probe} ->
        {timestamp_rank(checked_at), checked_at || "", message_surface_score(probe)}
      end,
      :desc
    )
    |> List.first()
    |> case do
      nil -> nil
      {_checked_at, probe} -> probe
    end
  end

  defp message_surface_score(%{"ok" => true}), do: 2
  defp message_surface_score(%{"status" => "ready"}), do: 2
  defp message_surface_score(%{"enabled" => true}), do: 1
  defp message_surface_score(_), do: 0

  defp entry_checked_at(%{"checked_at" => checked_at})
       when is_binary(checked_at) and checked_at != "",
       do: checked_at

  defp entry_checked_at(_), do: nil

  defp timestamp_rank(checked_at) when is_binary(checked_at) and checked_at != "", do: 1
  defp timestamp_rank(_), do: 0

  defp best_same_group_reply_probe(entries) do
    entries
    |> Enum.map(fn entry ->
      {entry_checked_at(entry), get_in(entry, ["same_group_reply_probe"])}
    end)
    |> Enum.reject(fn {_checked_at, probe} -> is_nil(probe) end)
    |> Enum.sort_by(
      fn {checked_at, probe} ->
        {timestamp_rank(checked_at), checked_at || "", same_group_reply_score(probe)}
      end,
      :desc
    )
    |> List.first()
    |> case do
      nil -> %{}
      {_checked_at, probe} -> probe
    end
  end

  defp same_group_reply_score(%{"ok" => true}), do: 1
  defp same_group_reply_score(_), do: 0

  defp same_group_reply_next_action(%{"next_action" => action})
       when is_binary(action) and action != "",
       do: action

  defp same_group_reply_next_action(_),
    do:
      "after a real Feishu user message is observed, inspect router/LLM/outbound Feishu send evidence until a same-group assistant reply is visible"

  defp same_group_reply_extra(%{"ok" => true} = probe) do
    %{
      "same_group_reply_probe" => %{
        "status" => probe["status"],
        "method" => probe["method"],
        "raw_message_body_redacted" =>
          get_in(probe, ["limits", "raw_message_body_redacted"]) == true
      }
    }
  end

  defp same_group_reply_extra(_), do: %{}

  defp best_delivery_diagnostics(entries) do
    entries
    |> Enum.reject(&is_nil(get_in(&1, ["console_probe"])))
    |> Enum.sort_by(&delivery_diagnostics_score/1, :desc)
    |> List.first()
  end

  defp delivery_diagnostics_score(%{
         "event_subscription_probe" => %{"receive_message_event_hint" => true},
         "permission_probe" => %{"receive_message_hint" => true},
         "version_publish_probe" => %{"published_hint" => true}
       }),
       do: 3

  defp delivery_diagnostics_score(%{"console_probe" => %{"app_detail_opened" => true}}), do: 1
  defp delivery_diagnostics_score(_), do: 0

  defp best_delivery_consistency(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      [
        get_in(entry, ["delivery_consistency_probe"]),
        derived_delivery_consistency(entry)
      ]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&delivery_consistency_score/1, :desc)
    |> List.first()
  end

  defp derived_delivery_consistency(entry) do
    case get_in(entry, ["real_inbound_probe", "delivery_consistency"]) do
      status when is_binary(status) and status != "" ->
        %{
          "attempted" => true,
          "status" => status,
          "signals" => %{
            "feishu_user_messages_after_base" =>
              get_in(entry, ["real_inbound_probe", "feishu_user_messages_after_base"]),
            "feishu_web_marker_visible" =>
              get_in(entry, ["message_surface_probe", "marker_visible_after_send"]) == true or
                get_in(entry, ["real_inbound_probe", "feishu_web_marker_visible"]) == true
          }
        }

      _ ->
        nil
    end
  end

  defp delivery_consistency_score(%{
         "attempted" => true,
         "status" => "visible_web_marker_not_delivered_bot_outbound_ok"
       }),
       do: 4

  defp delivery_consistency_score(%{
         "attempted" => true,
         "status" => "selected_chat_outbound_failed"
       }),
       do: 4

  defp delivery_consistency_score(%{
         "attempted" => true,
         "status" => "visible_web_marker_not_delivered"
       }),
       do: 3

  defp delivery_consistency_score(%{"attempted" => true}), do: 1
  defp delivery_consistency_score(_), do: 0

  defp best_console_recheck(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      [
        if(get_in(entry, ["event_log_recheck_probe"]), do: entry, else: nil),
        derived_console_recheck(entry)
      ]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&console_recheck_score/1, :desc)
    |> List.first()
  end

  defp derived_console_recheck(entry) do
    console = entry["console_probe"] || %{}

    if console["event_log_page_accessible"] == true or
         is_boolean(console["event_log_receive_message_delivery_row_hint"]) do
      receive_rows = console["event_log_receive_row_count"]

      %{
        "event_log_recheck_probe" => %{
          "attempted" => true,
          "receive_message_delivery_row_hint" =>
            console["event_log_receive_message_delivery_row_hint"] == true,
          "empty_hint" => receive_rows == 0
        },
        "app_availability_recheck_probe" => %{
          "attempted" =>
            console["event_page_accessible"] == true or
              console["permission_page_accessible"] == true,
          "enabled_or_published_hint" =>
            console["event_page_accessible"] == true and
              console["receive_message_event_signal"] == true,
          "install_or_visibility_hint" => console["permission_page_accessible"] == true
        }
      }
    end
  end

  defp console_recheck_score(%{
         "event_log_recheck_probe" => %{"attempted" => true},
         "app_availability_recheck_probe" => %{"attempted" => true}
       }),
       do: 2

  defp console_recheck_score(%{"event_log_recheck_probe" => %{"attempted" => true}}), do: 1
  defp console_recheck_score(_), do: 0

  defp best_selected_identity(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      [
        get_in(entry, ["selected_chat_identity_probe"]),
        derived_selected_identity_from_hash(entry),
        derived_selected_identity(entry)
      ]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&selected_identity_score/1, :desc)
    |> List.first()
  end

  defp derived_selected_identity(entry) do
    target_ready? = get_in(entry, ["target_chat_probe", "human_group_readiness", "ok"]) == true

    target_observed? =
      get_in(entry, ["target_chat_probe", "observed_chat_probe", "target_chat_observed"]) ==
        true

    member_count = get_in(entry, ["target_chat_probe", "member_probe", "member_count"])
    chat_mode = get_in(entry, ["target_chat_probe", "human_group_readiness", "chat_mode"])
    inbound_count = get_in(entry, ["real_inbound_probe", "feishu_user_messages_after_base"])
    marker_visible? = get_in(entry, ["real_inbound_probe", "feishu_web_marker_visible"]) == true
    outbound_attempted? = get_in(entry, ["outbound_send", "attempted"]) == true
    outbound_ok? = get_in(entry, ["outbound_send", "ok"]) == true

    cond do
      get_in(entry, ["real_inbound_probe", "ok"]) == true ->
        selected_identity_probe(
          true,
          "real_inbound_observed_for_selected_chat",
          nil,
          nil,
          target_ready?,
          target_observed?,
          member_count,
          chat_mode,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      target_ready? and marker_visible? and inbound_count == 0 and outbound_ok? and
          not target_observed? ->
        selected_identity_probe(
          false,
          "ready_selected_chat_outbound_ok_but_never_observed_inbound",
          "feishu_inbound_delivery_or_selected_group_identity_unverified",
          "bot outbound proves the selected chat is writable, but Salix has never observed inbound events for that chat; inspect Feishu event delivery rows and confirm the human Web marker is in the same selected chat",
          target_ready?,
          target_observed?,
          member_count,
          chat_mode,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      target_ready? and marker_visible? and inbound_count == 0 and not target_observed? ->
        selected_identity_probe(
          false,
          "ready_selected_chat_never_observed_inbound",
          "feishu_inbound_delivery_or_selected_group_identity_unverified",
          "confirm the selected bot-visible chat is the same group as the human Web marker, then inspect Feishu event delivery rows for receive-message events",
          target_ready?,
          target_observed?,
          member_count,
          chat_mode,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      target_ready? and outbound_attempted? and not outbound_ok? ->
        selected_identity_probe(
          false,
          "selected_chat_outbound_failed",
          "feishu_selected_chat_write_or_app_availability_unverified",
          "inspect app availability/install state and message send permission for the selected chat",
          target_ready?,
          target_observed?,
          member_count,
          chat_mode,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      marker_visible? or outbound_attempted? or target_observed? ->
        selected_identity_probe(
          false,
          "selected_chat_identity_incomplete",
          "selected_chat_identity_evidence_incomplete",
          "complete target readiness, marker visibility, bot outbound, and real-inbound probes in one run",
          target_ready?,
          target_observed?,
          member_count,
          chat_mode,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      true ->
        nil
    end
  end

  defp derived_selected_identity_from_hash(entry) do
    identity = entry["chat_identity_probe"] || %{}
    inbound_count = get_in(entry, ["real_inbound_probe", "feishu_user_messages_after_base"])

    marker_visible? =
      get_in(entry, ["message_surface_probe", "marker_visible_after_send"]) == true

    if identity["name_hash_match"] == true and inbound_count == 0 and marker_visible? do
      %{
        "attempted" => true,
        "ok" => false,
        "status" => "ready_selected_chat_hash_match_but_never_observed_inbound",
        "failure_code" => "feishu_inbound_delivery_unverified_after_group_hash_match",
        "next_action" =>
          "Feishu Web group and bot API selected chat match by redacted hash, so inspect Feishu platform event delivery/app availability before sending another marker",
        "signals" => %{
          "name_hash_match" => true,
          "name_length_match" => identity["name_length_match"] == true,
          "feishu_user_messages_after_base" => inbound_count,
          "feishu_web_marker_visible" => marker_visible?
        },
        "limits" => %{
          "raw_chat_ids_redacted" => true,
          "raw_chat_names_redacted" => true,
          "message_body_redacted" => true,
          "account_identity_redacted" => true
        }
      }
    end
  end

  defp selected_identity_probe(
         ok?,
         status,
         failure_code,
         next_action,
         target_ready?,
         target_observed?,
         member_count,
         chat_mode,
         inbound_count,
         marker_visible?,
         outbound_attempted?,
         outbound_ok?
       ) do
    %{
      "attempted" => true,
      "ok" => ok?,
      "status" => status,
      "failure_code" => failure_code,
      "next_action" => next_action,
      "signals" => %{
        "target_ready" => target_ready?,
        "target_chat_observed_from_inbound_events" => target_observed?,
        "target_member_count" => member_count,
        "target_chat_mode" => chat_mode,
        "feishu_user_messages_after_base" => inbound_count,
        "feishu_web_marker_visible" => marker_visible?,
        "bot_outbound_attempted" => outbound_attempted?,
        "bot_outbound_to_selected_chat_ok" => outbound_ok?
      },
      "limits" => %{
        "raw_chat_ids_redacted" => true,
        "message_body_redacted" => true,
        "account_identity_redacted" => true
      }
    }
  end

  defp selected_identity_score(%{
         "attempted" => true,
         "status" => "ready_selected_chat_hash_match_but_never_observed_inbound"
       }),
       do: 5

  defp selected_identity_score(%{
         "attempted" => true,
         "status" => "ready_selected_chat_outbound_ok_but_never_observed_inbound"
       }),
       do: 4

  defp selected_identity_score(%{
         "attempted" => true,
         "status" => "ready_selected_chat_never_observed_inbound"
       }),
       do: 3

  defp selected_identity_score(%{"attempted" => true}), do: 1
  defp selected_identity_score(_), do: 0

  defp best_event_consumer_probe(entries) do
    entries
    |> Enum.map(&get_in(&1, ["event_consumer_probe"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&event_consumer_score/1, :desc)
    |> List.first()
  end

  defp event_consumer_score(%{"ok" => true}), do: 3

  defp event_consumer_score(%{
         "attempted" => true,
         "status" => status
       })
       when status in [
              "same_app_lark_cli_consumer_no_receive_event",
              "same_app_long_connection_no_receive_event"
            ],
       do: 2

  defp event_consumer_score(%{"attempted" => true}), do: 1
  defp event_consumer_score(_), do: 0

  defp real_feishu_user_message_next_action(
         _diagnostics,
         _delivery_consistency,
         _selected_identity,
         %{
           "attempted" => true,
           "status" => status,
           "next_action" => action
         }
       )
       when status in [
              "same_app_lark_cli_consumer_no_receive_event",
              "same_app_long_connection_no_receive_event"
            ] and is_binary(action) and action != "",
       do: action

  defp real_feishu_user_message_next_action(
         _diagnostics,
         _delivery_consistency,
         _selected_identity,
         %{
           "attempted" => true,
           "next_action" => action
         }
       )
       when is_binary(action) and action != "",
       do: action

  defp real_feishu_user_message_next_action(
         _diagnostics,
         %{
           "attempted" => true,
           "next_action" => action
         },
         _selected_identity,
         _event_consumer
       )
       when is_binary(action) and action != "",
       do: action

  defp real_feishu_user_message_next_action(
         _diagnostics,
         _delivery_consistency,
         %{"attempted" => true, "next_action" => action},
         _event_consumer
       )
       when is_binary(action) and action != "",
       do: action

  defp real_feishu_user_message_next_action(
         %{
           "event_subscription_probe" => %{"receive_message_event_hint" => true},
           "permission_probe" => %{"receive_message_hint" => true},
           "version_publish_probe" => %{"published_hint" => true},
           "post_publish_marker_probe" => %{"fresh_marker_visible" => true}
         },
         _delivery_consistency,
         _selected_identity,
         _event_consumer
       ) do
    "Feishu Web marker is visible and console prerequisites were checked/published; inspect Feishu platform event delivery or app availability for the selected ready target group"
  end

  defp real_feishu_user_message_next_action(_, _, _, _),
    do:
      "send a fresh real Feishu @bot message from the usable message surface, then rerun the real-inbound probe and inspect event delivery if the count stays zero"

  defp delivery_extra(inbound_count, nil, nil, nil, nil, nil),
    do: %{"observed_count" => inbound_count}

  defp delivery_extra(
         inbound_count,
         diagnostics,
         consistency,
         console_recheck,
         selected_identity,
         event_consumer
       ) do
    %{"observed_count" => inbound_count}
    |> maybe_put_console_diagnostics(diagnostics)
    |> maybe_put_delivery_consistency(consistency)
    |> maybe_put_console_recheck(console_recheck)
    |> maybe_put_selected_identity(selected_identity)
    |> maybe_put_event_consumer(event_consumer)
  end

  defp maybe_put_console_diagnostics(extra, nil), do: extra

  defp maybe_put_console_diagnostics(extra, diagnostics) do
    Map.put(extra, "console_diagnostics", %{
      "event_subscription_checked" =>
        get_in(diagnostics, ["event_subscription_probe", "receive_message_event_hint"]) == true,
      "permission_checked" =>
        get_in(diagnostics, ["permission_probe", "receive_message_hint"]) == true,
      "version_publish_checked" =>
        get_in(diagnostics, ["version_publish_probe", "published_hint"]) == true,
      "post_publish_marker_visible" =>
        get_in(diagnostics, ["post_publish_marker_probe", "fresh_marker_visible"]) == true
    })
  end

  defp maybe_put_delivery_consistency(extra, %{"attempted" => true} = consistency) do
    Map.put(extra, "delivery_consistency", %{
      "status" => consistency["status"],
      "failure_code" => consistency["failure_code"],
      "signals" => consistency["signals"] || %{}
    })
  end

  defp maybe_put_delivery_consistency(extra, _), do: extra

  defp maybe_put_console_recheck(extra, nil), do: extra

  defp maybe_put_console_recheck(extra, console_recheck) do
    Map.put(extra, "console_recheck", %{
      "event_log_checked" =>
        get_in(console_recheck, ["event_log_recheck_probe", "attempted"]) == true,
      "receive_message_delivery_row_visible" =>
        get_in(console_recheck, ["event_log_recheck_probe", "receive_message_delivery_row_hint"]) ==
          true,
      "event_log_empty_hint" =>
        get_in(console_recheck, ["event_log_recheck_probe", "empty_hint"]) == true,
      "app_enabled_or_published_hint" =>
        get_in(console_recheck, [
          "app_availability_recheck_probe",
          "enabled_or_published_hint"
        ]) == true,
      "install_or_visibility_hint" =>
        get_in(console_recheck, [
          "app_availability_recheck_probe",
          "install_or_visibility_hint"
        ]) == true
    })
  end

  defp maybe_put_selected_identity(extra, nil), do: extra

  defp maybe_put_selected_identity(extra, %{"attempted" => true} = selected_identity) do
    Map.put(extra, "selected_chat_identity", %{
      "status" => selected_identity["status"],
      "failure_code" => selected_identity["failure_code"],
      "signals" => selected_identity["signals"] || %{}
    })
  end

  defp maybe_put_selected_identity(extra, _), do: extra

  defp maybe_put_event_consumer(extra, nil), do: extra

  defp maybe_put_event_consumer(extra, %{"attempted" => true} = event_consumer) do
    Map.put(extra, "event_consumer", %{
      "status" => event_consumer["status"],
      "failure_code" => event_consumer["failure_code"],
      "event_count" => event_consumer["event_count"],
      "marker_prefix_seen" => event_consumer["marker_prefix_seen"],
      "app_identity_match" => event_consumer["app_identity_match"]
    })
  end

  defp maybe_put_event_consumer(extra, _), do: extra

  defp gate_result(id, ok?, description, next_action, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "ok" => ok?,
        "description" => description,
        "next_action" => if(ok?, do: nil, else: next_action)
      },
      extra
    )
  end

  defp gate_result?(%{"id" => id, "ok" => ok}) when is_binary(id) and is_boolean(ok), do: true
  defp gate_result?(_), do: false

  def sanitize(value), do: sanitize(value, nil)

  defp sanitize(%{} = map, parent_key) do
    Map.new(map, fn {key, value} ->
      key = to_string(key)

      cond do
        sensitive_key?(key) ->
          {key, "[redacted]"}

        sensitive_key?(parent_key) ->
          {key, "[redacted]"}

        true ->
          {key, sanitize(value, key)}
      end
    end)
  end

  defp sanitize(list, parent_key) when is_list(list),
    do: Enum.map(list, &sanitize(&1, parent_key))

  defp sanitize(value, _parent_key) when is_binary(value) do
    if String.length(value) > 240 do
      String.slice(value, 0, 240) <> "...[truncated]"
    else
      value
    end
  end

  defp sanitize(value, _parent_key), do: value

  defp sensitive_key?(nil), do: false

  defp sensitive_key?(key) do
    key = to_string(key)

    not redaction_declaration_key?(key) and
      not MapSet.member?(@allowed_sensitive_keys, key) and
      Enum.any?(@sensitive_key_parts, &String.contains?(key, &1))
  end

  defp redaction_declaration_key?(key) do
    String.ends_with?(key, "_redacted") or String.contains?(key, "_redacted_")
  end

  defp message_surface_ready?(%{"ok" => true}), do: true
  defp message_surface_ready?(%{"status" => "ready"}), do: true
  defp message_surface_ready?(_), do: false

  defp message_surface_next_action(%{"next_action" => action})
       when is_binary(action) and action != "",
       do: action

  defp message_surface_next_action(_),
    do:
      "restore an authenticated Feishu Web composer for the target group, then rerun the real-inbound probe; only try the desktop client after Web is explicitly unavailable"

  defp summary_html(opts, usable) do
    pr_url = opts["pr_url"] || ""
    git_head = opts["git_head"] || ""
    checks = opts["checks"] || ""

    """
    <section class="grid">
      <div class="card">
        <strong>Customer-usable claim</strong><br />
        #{if usable, do: ~s(<span class="ok">proved</span>), else: ~s(<span class="bad">not proved</span>)}<br />
        <span class="note">Requires signed public callback, ready human group, usable message surface, real Feishu-sourced user message, and same-group assistant reply evidence.</span>
      </div>
      <div class="card">
        <strong>PR / CI</strong><br />
        #{link_or_dash(pr_url)}<br />
        Head: <code>#{esc(git_head)}</code><br />
        Checks: <code>#{esc(checks)}</code>
      </div>
    </section>
    """
  end

  defp customer_usable_gates_html(gate_results) do
    rows =
      gate_results
      |> Enum.map(fn gate ->
        status =
          if gate["ok"],
            do: ~s(<span class="ok">pass</span>),
            else: ~s(<span class="bad">missing</span>)

        observed =
          case Map.fetch(gate, "observed_count") do
            {:ok, count} -> " · observed_count=#{esc(count)}"
            :error -> ""
          end

        diagnostics = console_diagnostics_summary(gate)
        consistency = delivery_consistency_summary(gate)
        recheck = console_recheck_summary(gate)
        identity = selected_identity_summary(gate)
        event_consumer = event_consumer_summary(gate)
        same_group_reply = same_group_reply_summary(gate)

        """
        <tr>
          <td><code>#{esc(gate["id"])}</code></td>
          <td>#{status}</td>
          <td>
            #{esc(gate["description"])}#{observed}#{diagnostics}#{consistency}#{recheck}#{identity}#{event_consumer}#{same_group_reply}
            #{next_action_html(gate)}
          </td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    """
    <section>
      <h2>Customer-usable Gates</h2>
      <table>
        <thead><tr><th>Gate</th><th>Status</th><th>Evidence expectation</th></tr></thead>
        <tbody>#{rows}</tbody>
      </table>
    </section>
    """
  end

  defp next_action_html(%{"ok" => true}), do: ""
  defp next_action_html(%{"next_action" => nil}), do: ""

  defp next_action_html(%{"next_action" => action}) do
    "<br /><span class=\"note\">Next action: #{esc(action)}</span>"
  end

  defp console_diagnostics_summary(%{"console_diagnostics" => diagnostics})
       when is_map(diagnostics) do
    checked =
      diagnostics
      |> Enum.filter(fn {_key, value} -> value == true end)
      |> Enum.map(fn {key, _value} -> key end)
      |> Enum.sort()

    if checked == [] do
      ""
    else
      " · console_diagnostics=#{esc(Enum.join(checked, ","))}"
    end
  end

  defp console_diagnostics_summary(_), do: ""

  defp delivery_consistency_summary(%{"delivery_consistency" => %{"status" => status}})
       when is_binary(status) and status != "" do
    " · delivery_consistency=#{esc(status)}"
  end

  defp delivery_consistency_summary(_), do: ""

  defp console_recheck_summary(%{
         "console_recheck" => %{
           "event_log_checked" => true,
           "receive_message_delivery_row_visible" => false
         }
       }) do
    " · console_recheck=no_receive_message_delivery_row"
  end

  defp console_recheck_summary(%{
         "console_recheck" => %{"event_log_checked" => true}
       }) do
    " · console_recheck=event_log_checked"
  end

  defp console_recheck_summary(_), do: ""

  defp selected_identity_summary(%{"selected_chat_identity" => %{"status" => status}})
       when is_binary(status) and status != "" do
    " · selected_identity=#{esc(status)}"
  end

  defp selected_identity_summary(_), do: ""

  defp event_consumer_summary(%{
         "event_consumer" => %{
           "status" => status,
           "event_count" => 0
         }
       }) do
    if status in [
         "same_app_lark_cli_consumer_no_receive_event",
         "same_app_long_connection_no_receive_event"
       ] do
      " · event_consumer=no_receive_event"
    else
      " · event_consumer=#{esc(status)}"
    end
  end

  defp event_consumer_summary(%{"event_consumer" => %{"status" => status}})
       when is_binary(status) and status != "" do
    " · event_consumer=#{esc(status)}"
  end

  defp event_consumer_summary(_), do: ""

  defp same_group_reply_summary(%{
         "same_group_reply_probe" => %{"status" => status, "method" => method}
       })
       when is_binary(status) and status != "" do
    method = if is_binary(method) and method != "", do: ":#{method}", else: ""
    " · same_group_reply=#{esc(status <> method)}"
  end

  defp same_group_reply_summary(_), do: ""

  defp evidence_html([]),
    do: "<section><h2>Evidence</h2><p class=\"note\">No evidence files supplied.</p></section>"

  defp evidence_html(evidence) do
    items =
      evidence
      |> Enum.map(fn entry ->
        """
        <div class="card">
          <strong>#{esc(entry["path"] || "inline evidence")}</strong>
          <pre>#{esc(Jason.encode!(entry["data"], pretty: true))}</pre>
        </div>
        """
      end)
      |> Enum.join("\n")

    "<section><h2>Evidence</h2>#{items}</section>"
  end

  defp screenshots_html([]),
    do: "<section><h2>Screenshots</h2><p class=\"note\">No screenshots supplied.</p></section>"

  defp screenshots_html(screenshots) do
    figures =
      screenshots
      |> Enum.map(fn shot ->
        path = shot["path"] || ""
        title = shot["title"] || Path.basename(path)
        caption = shot["caption"] || ""

        """
        <figure>
          <img src="#{esc(path)}" alt="#{esc(title)}" />
          <figcaption><strong>#{esc(title)}</strong><br />#{esc(caption)}</figcaption>
        </figure>
        """
      end)
      |> Enum.join("\n")

    "<section><h2>Screenshots</h2>#{figures}</section>"
  end

  defp link_or_dash(""), do: "<span class=\"note\">not set</span>"
  defp link_or_dash(url), do: ~s(<a href="#{esc(url)}">#{esc(url)}</a>)

  defp load_json_file!(path) do
    data = path |> File.read!() |> Jason.decode!()
    {path, data}
  end

  defp load_screenshot_manifest!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.get("screenshots", [])
  end

  defp split_env(name) do
    name
    |> env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp env(name, default), do: System.get_env(name, default) |> to_string() |> String.trim()

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end

unless System.get_env("BRIDGE_TOB_ACCEPTANCE_REPORT_SKIP_RUN") == "true" do
  BridgeToB.AcceptanceReport.run()
end
