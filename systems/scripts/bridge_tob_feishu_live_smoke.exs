unless System.get_env("BRIDGE_TOB_LIVE_FEISHU_SKIP_RUN") == "true" do
  Logger.configure(level: :warning)

  {:ok, _} = Application.ensure_all_started(:salix_store)
  {:ok, _} = Application.ensure_all_started(:salix_agent)
  {:ok, _} = Application.ensure_all_started(:salix_im)
end

defmodule BridgeToB.FeishuLiveSmoke do
  @moduledoc false

  @default_webhook_url_file "/tmp/bridge-tob-feishu-webhook-url.txt"
  @default_evidence_path "/tmp/bridge-tob-feishu-live-smoke-evidence.json"
  @record_scan_max_records 1_000

  def run do
    webhook_url_file = env("BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE", @default_webhook_url_file)
    evidence_path = env("BRIDGE_TOB_LIVE_FEISHU_EVIDENCE_PATH", @default_evidence_path)
    router_agent_id = env("BRIDGE_TOB_SMOKE_ROUTER_AGENT_ID", "")
    send? = truthy?(env("BRIDGE_TOB_LIVE_FEISHU_SEND", "false"))

    with {:ok, selection} <- select_connect(router_agent_id, webhook_url_file) do
      connect = selection.connect
      chats = selection.chats
      router_agent_probe = router_agent_probe(router_agent_id, connect)
      effective_router_agent_id = router_agent_probe["router_agent_id"] || ""
      signature_preflight = signed_callback_preflight(selection.webhook_url, connect)

      message_surface_probe = message_surface_probe()
      target_chat_probe = target_chat_probe(effective_router_agent_id, connect, chats)
      dedicated_group_probe = dedicated_group_probe(effective_router_agent_id, connect, chats)

      evidence =
        %{
          "ok" => signature_preflight["ok"] == true,
          "checked_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "claim" => live_claim(signature_preflight),
          "signature_preflight" => signature_preflight,
          "connect_probe" => selection.evidence,
          "router_agent_probe" => redact_router_agent_probe(router_agent_probe),
          "visible_chats" => %{
            "count" => length(chats),
            "sample" => Enum.map(Enum.take(chats, 10), &redacted_chat/1)
          },
          "target_chat_probe" => target_chat_probe,
          "dedicated_group_probe" => dedicated_group_probe,
          "message_surface_probe" => message_surface_probe,
          "limits" => %{
            "live_feishu_api" => true,
            "human_inbound" => false,
            "message_body_redacted" => true
          }
        }

      evidence =
        if send? do
          Map.put(
            evidence,
            "outbound_send",
            send_outbound(effective_router_agent_id, connect, target_chat_probe, chats)
          )
        else
          Map.put(evidence, "outbound_send", %{"attempted" => false})
        end

      evidence =
        Map.put(
          evidence,
          "real_inbound_probe",
          real_inbound_probe(effective_router_agent_id, connect, message_surface_probe)
        )

      evidence =
        Map.put(
          evidence,
          "delivery_consistency_probe",
          delivery_consistency_probe_result(
            evidence["message_surface_probe"],
            evidence["target_chat_probe"],
            evidence["real_inbound_probe"],
            evidence["outbound_send"]
          )
        )

      evidence =
        Map.put(
          evidence,
          "selected_chat_identity_probe",
          selected_chat_identity_probe_result(
            evidence["target_chat_probe"],
            evidence["real_inbound_probe"],
            evidence["outbound_send"]
          )
        )

      write_evidence!(evidence_path, evidence)
      IO.puts(Jason.encode!(evidence, pretty: true))
    else
      {:error, reason} ->
        evidence = %{
          "ok" => false,
          "checked_at" =>
            DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          "claim" => "live-feishu-smoke-failed",
          "error" => redact(inspect(reason))
        }

        write_evidence!(evidence_path, evidence)
        IO.puts(Jason.encode!(evidence, pretty: true))
        System.halt(1)
    end
  end

  defp select_connect(router_agent_id, webhook_url_file) do
    case connect_from_webhook_file(router_agent_id, webhook_url_file) do
      {:ok, selection} ->
        {:ok, selection}

      {:error, reason} ->
        if truthy?(env("BRIDGE_TOB_LIVE_FEISHU_AUTO_SELECT_CONNECT", "true")) do
          auto_select_connect(router_agent_id, webhook_url_file, reason)
        else
          {:error, reason}
        end
    end
  end

  defp connect_from_webhook_file(router_agent_id, webhook_url_file) do
    with {:ok, app_id} <- app_id_from_webhook_file(webhook_url_file),
         {:ok, connect} <-
           SalixIM.ProviderIdentity.find_active_feishu_im_connect_by_app_id(app_id),
         {:ok, chats_body} <- list_chats(router_agent_id, connect, 50) do
      chats = extract_items(chats_body)

      {:ok,
       %{
         connect: connect,
         chats: chats,
         webhook_url: webhook_url(connect),
         evidence: %{
           "source" => "webhook_url_file",
           "auto_selected" => false,
           "selected_connect_id_prefix" => connect_id_prefix(connect),
           "visible_chat_count" => length(chats),
           "webhook_url_file_present" => true,
           "limits" => connect_probe_limits()
         }
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp auto_select_connect(router_agent_id, webhook_url_file, file_reason) do
    candidates =
      SalixStore.Keys.ctl_im_connects_all_prefix()
      |> records()
      |> Enum.filter(&active_feishu_connect?/1)
      |> Enum.sort_by(&(&1["updated_at"] || &1["created_at"] || 0), :desc)

    {results, selected} =
      Enum.reduce_while(candidates, {[], nil}, fn connect, {results, _selected} ->
        case list_chats(router_agent_id, connect, 50) do
          {:ok, chats_body} ->
            chats = extract_items(chats_body)

            result = %{
              "connect_id_prefix" => connect_id_prefix(connect),
              "ok" => true,
              "visible_chat_count" => length(chats)
            }

            {:halt, {results ++ [result], {connect, chats}}}

          {:error, reason} ->
            result = %{
              "connect_id_prefix" => connect_id_prefix(connect),
              "ok" => false,
              "error" => redact(inspect(reason))
            }

            {:cont, {results ++ [result], nil}}
        end
      end)

    case selected do
      {connect, chats} ->
        url = webhook_url(connect)
        repair_webhook_url_file(webhook_url_file, url)

        {:ok,
         %{
           connect: connect,
           chats: chats,
           webhook_url: url,
           evidence: %{
             "source" => "auto_selected_active_connect",
             "auto_selected" => true,
             "active_feishu_connect_count" => length(candidates),
             "webhook_url_file_failure" => redact(inspect(file_reason)),
             "selected_connect_id_prefix" => connect_id_prefix(connect),
             "visible_chat_count" => length(chats),
             "candidate_results" => results,
             "webhook_url_file_repaired" => webhook_url_file != "",
             "limits" => connect_probe_limits()
           }
         }}

      nil ->
        {:error,
         {:no_working_feishu_connect,
          %{
            file_reason: file_reason,
            active_feishu_connect_count: length(candidates),
            candidate_results: results
          }}}
    end
  end

  defp list_chats(router_agent_id, connect, limit) do
    SalixIM.Provider.Feishu.call(router_agent_id, connect, "feishu.list_chats", %{
      "limit" => limit
    })
  end

  defp app_id_from_webhook_file(path) do
    with {:ok, body} <- File.read(path),
         uri <- URI.parse(String.trim(body)),
         query <- URI.decode_query(uri.query || ""),
         app_id when is_binary(app_id) and app_id != "" <- query["app_id"] do
      {:ok, app_id}
    else
      _ -> {:error, :missing_app_id_in_webhook_url_file}
    end
  end

  defp webhook_url(connect) do
    base =
      first_nonblank([
        connect["webhook_url"],
        SalixIM.ProviderConnects.public_base_url() <> "/v1/im/feishu/events"
      ])

    uri = URI.parse(base)
    query = URI.decode_query(uri.query || "")
    app_id = trim(connect["app_id"])
    query = if app_id == "", do: query, else: Map.put(query, "app_id", app_id)

    uri
    |> Map.put(:query, URI.encode_query(query))
    |> URI.to_string()
  end

  defp repair_webhook_url_file("", _url), do: :ok

  defp repair_webhook_url_file(path, url) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, url)
    File.chmod!(path, 0o600)
  end

  defp active_feishu_connect?(connect) do
    connect["provider"] == "feishu" and connect["status"] == "connected" and
      is_nil(connect["disabled_at"]) and is_nil(connect["deleted_at"])
  end

  defp router_agent_probe(configured_router_agent_id, connect) do
    configured_router_agent_id = trim(configured_router_agent_id)

    cond do
      configured_router_agent_id != "" ->
        %{
          "attempted" => true,
          "ok" => true,
          "source" => "env",
          "router_agent_id" => configured_router_agent_id
        }

      trim(connect["group_id"]) == "" ->
        %{
          "attempted" => true,
          "ok" => false,
          "source" => "connect_group",
          "failure_code" => "connect_group_missing",
          "next_action" =>
            "repair the active Feishu connect group_id before probing router session"
        }

      true ->
        derive_router_agent_from_connect_group(connect)
    end
  end

  defp derive_router_agent_from_connect_group(connect) do
    group_id = trim(connect["group_id"])

    matches =
      SalixStore.Keys.ctl_agents_prefix()
      |> records()
      |> Enum.filter(fn agent ->
        trim(agent["group_id"]) == group_id and trim(agent["role"]) == "router"
      end)

    case matches do
      [agent] ->
        %{
          "attempted" => true,
          "ok" => true,
          "source" => "connect_group",
          "router_agent_id" => trim(agent["id"] || agent["agent_id"])
        }

      [] ->
        %{
          "attempted" => true,
          "ok" => false,
          "source" => "connect_group",
          "failure_code" => "router_agent_not_found",
          "next_action" =>
            "create or repair the BridgeForTeams router agent for the active connect group"
        }

      [_ | _] ->
        agent =
          Enum.max_by(matches, &(&1["updated_at"] || &1["created_at"] || ""), fn -> nil end)

        %{
          "attempted" => true,
          "ok" => true,
          "source" => "connect_group",
          "warning_code" => "multiple_router_agents_found",
          "router_agent_count" => length(matches),
          "router_agent_id" => trim(agent["id"] || agent["agent_id"]),
          "next_action" => "deduplicate router agents for the active connect group"
        }
    end
  end

  defp redact_router_agent_probe(%{"router_agent_id" => router_agent_id} = probe) do
    probe
    |> Map.delete("router_agent_id")
    |> Map.put("router_agent_id_prefix", String.slice(router_agent_id, 0, 12))
    |> Map.put("limits", %{"raw_router_agent_id_redacted" => true})
  end

  defp redact_router_agent_probe(probe), do: probe

  defp connect_id_prefix(connect), do: String.slice(to_string(connect["connect_id"] || ""), 0, 12)

  defp connect_probe_limits do
    %{
      "raw_app_id_redacted" => true,
      "raw_webhook_url_redacted" => true,
      "raw_token_redacted" => true
    }
  end

  defp send_outbound(router_agent_id, connect, target_chat_probe, chats) do
    case outbound_target_chat(target_chat_probe, chats) do
      {:ok, chat, chat_id} ->
        marker =
          "bridge-tob-live-outbound-" <>
            Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

        case SalixIM.Provider.Feishu.call(router_agent_id, connect, "feishu.send_text", %{
               "receive_id" => chat_id,
               "receive_id_type" => "chat_id",
               "text" => "Bridge ToB live outbound smoke: " <> marker
             }) do
          {:ok, body} ->
            message_id = get_in(body, ["data", "message_id"]) || body["message_id"] || ""

            %{
              "attempted" => true,
              "ok" => true,
              "claim" => "live-real-feishu-outbound-to-target-chat-not-human-inbound",
              "chat" => redacted_chat(chat),
              "target_source" => outbound_target_source(target_chat_probe),
              "message" => %{
                "marker_prefix" => String.slice(marker, 0, 24),
                "message_id_prefix" => String.slice(to_string(message_id), 0, 12)
              }
            }

          {:error, reason} ->
            %{"attempted" => true, "ok" => false, "error" => redact(inspect(reason))}
        end

      {:error, reason} ->
        %{"attempted" => true, "ok" => false, "error" => to_string(reason)}
    end
  end

  defp outbound_target_chat(%{"target_chat_probe" => target_chat_probe}, chats),
    do: outbound_target_chat(target_chat_probe, chats)

  defp outbound_target_chat(%{"selected_chat" => %{"chat_id_prefix" => prefix}}, chats)
       when is_binary(prefix) and prefix != "" do
    case matching_chat_by_id_prefix(chats, prefix) do
      nil -> first_chat_id(chats)
      chat -> {:ok, chat, chat_id(chat)}
    end
  end

  defp outbound_target_chat(_target_chat_probe, chats), do: first_chat_id(chats)

  defp outbound_target_source(%{"selected_chat" => %{"chat_id_prefix" => prefix}})
       when is_binary(prefix) and prefix != "",
       do: "selected_target_chat"

  defp outbound_target_source(_), do: "first_visible_chat"

  defp dedicated_group_probe(router_agent_id, connect, chats) do
    if truthy?(env("BRIDGE_TOB_LIVE_FEISHU_CREATE_DEDICATED_GROUP", "false")) do
      do_dedicated_group_probe(router_agent_id, connect, chats)
    else
      %{
        "attempted" => false,
        "reason" =>
          "set BRIDGE_TOB_LIVE_FEISHU_CREATE_DEDICATED_GROUP=true to create a live smoke group"
      }
    end
  end

  defp do_dedicated_group_probe(router_agent_id, connect, chats) do
    with {:ok, _source_chat, chat_id} <- first_chat_id(chats),
         {:ok, member_id} <- first_chat_member_id(router_agent_id, connect, chat_id),
         {:ok, token} <- feishu_tenant_access_token(connect),
         {:ok, body, status} <- create_feishu_group(connect, token, member_id) do
      ok? = status in 200..299 and success_code?(body)
      created_chat_id = get_in(body, ["data", "chat_id"]) || body["chat_id"] || ""

      %{
        "attempted" => true,
        "ok" => ok?,
        "http_status" => status,
        "feishu_code" => body["code"],
        "failure_code" => dedicated_group_failure_code(status, body),
        "failure_message_redacted" =>
          if(ok?, do: nil, else: redact(inspect(body["msg"] || body))),
        "created_chat_id_prefix" => String.slice(to_string(created_chat_id), 0, 8),
        "source_member_id_prefix" => String.slice(member_id, 0, 8),
        "next_action" => dedicated_group_next_action(status, body),
        "limits" => %{
          "group_name_redacted" => true,
          "raw_chat_id_redacted" => true,
          "raw_member_id_redacted" => true
        }
      }
    else
      {:error, reason} ->
        %{
          "attempted" => true,
          "ok" => false,
          "failure_code" => "dedicated_group_probe_failed",
          "error" => redact(inspect(reason)),
          "next_action" =>
            "inspect source chat member and Feishu create-group permission readiness"
        }
    end
  end

  defp first_chat_member_id(router_agent_id, connect, chat_id) do
    case SalixIM.Provider.Feishu.call(router_agent_id, connect, "feishu.list_chat_members", %{
           "chat_id" => chat_id,
           "limit" => 50
         }) do
      {:ok, body} ->
        case extract_items(body) do
          [member | _] ->
            member_id =
              member["member_id"] ||
                member["open_id"] ||
                member["user_id"] ||
                get_in(member, ["member_id", "open_id"]) ||
                ""

            if trim(member_id) == "",
              do: {:error, :source_member_id_missing},
              else: {:ok, trim(member_id)}

          [] ->
            {:error, :source_chat_has_no_visible_members}
        end

      {:error, reason} ->
        {:error, {:list_chat_members_failed, reason}}
    end
  end

  defp create_feishu_group(_connect, token, member_id) do
    name =
      "Bridge ToB Smoke " <>
        (DateTime.utc_now()
         |> DateTime.to_iso8601()
         |> String.replace(~r/[^0-9T]/, "")
         |> String.slice(0, 15))

    case Req.post("#{feishu_api_base()}/im/v1/chats?user_id_type=open_id",
           headers: [{"authorization", "Bearer " <> token}],
           json: %{
             "name" => name,
             "chat_mode" => "group",
             "user_id_list" => [member_id]
           },
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when is_map(body) -> {:ok, body, status}
      {:ok, %{status: status, body: body}} -> {:ok, %{"raw" => body}, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp feishu_tenant_access_token(connect) do
    case Req.post("#{feishu_api_base()}/auth/v3/tenant_access_token/internal",
           json: %{
             "app_id" => connect["app_id"],
             "app_secret" => connect["app_secret"]
           },
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        token = body["tenant_access_token"] || get_in(body, ["data", "tenant_access_token"])

        if is_binary(token) and token != "",
          do: {:ok, token},
          else: {:error, :tenant_access_token_missing}

      {:ok, %{status: status, body: body}} ->
        {:error, {:tenant_access_token_http_error, status, body}}

      {:error, reason} ->
        {:error, {:tenant_access_token_request_failed, reason}}
    end
  end

  defp feishu_api_base do
    :salix_im
    |> Application.get_env(:feishu_api_base_url, "https://open.feishu.cn/open-apis")
    |> trim()
    |> default_base("https://open.feishu.cn/open-apis")
  end

  defp success_code?(%{"code" => code}) when code in [0, nil], do: true
  defp success_code?(%{"code" => _}), do: false
  defp success_code?(_), do: true

  defp dedicated_group_failure_code(status, body) do
    cond do
      status in 200..299 and success_code?(body) ->
        nil

      body["code"] == 99_991_672 or String.contains?(to_string(body["msg"] || ""), "scope") ->
        "create_group_permission_denied"

      is_integer(status) ->
        "create_group_http_#{status}"

      true ->
        "create_group_failed"
    end
  end

  defp dedicated_group_next_action(status, body) do
    case dedicated_group_failure_code(status, body) do
      nil ->
        "rerun visible-chat and real-inbound probes against the created dedicated smoke group"

      "create_group_permission_denied" ->
        "ensure im:chat or im:chat:create is opened for the deployed app version, then reinstall or refresh app authorization if Feishu still denies the API"

      _ ->
        "inspect Feishu create-group API response and app installation state"
    end
  end

  defp signed_callback_preflight(webhook_url, connect) do
    with secret when is_binary(secret) and secret != "" <-
           first_nonblank([connect["encrypt_key"], connect["verification_token"]]) do
      webhook_url = String.trim(webhook_url)
      message_id = "om_bridge_tob_signed_" <> nonce()

      envelope = %{
        "schema" => "2.0",
        "header" => %{
          "event_id" => "evt_bridge_tob_signed_" <> nonce(),
          "event_type" => "im.message.receive_v1",
          "token" => connect["verification_token"]
        },
        "event" => %{
          "sender" => %{"sender_type" => "user", "sender_id" => %{"open_id" => "ou_redacted"}},
          "message" => %{
            "message_id" => message_id,
            "chat_id" => "oc_redacted",
            "chat_type" => "group",
            "message_type" => "text",
            "content" => Jason.encode!(%{"text" => "bridge-tob-signed-preflight"})
          }
        }
      }

      raw = Jason.encode!(envelope)
      timestamp = Integer.to_string(System.system_time(:second))
      request_nonce = nonce()
      signature = feishu_signature(timestamp, request_nonce, secret, raw)

      case Req.post(webhook_url,
             headers: [
               {"content-type", "application/json"},
               {"x-lark-request-timestamp", timestamp},
               {"x-lark-request-nonce", request_nonce},
               {"x-lark-signature", signature}
             ],
             body: raw
           ) do
        {:ok, %{status: status, body: body}} ->
          ok? = status == 200 and response_queued?(body)

          %{
            "ok" => ok?,
            "http_status" => status,
            "response_status" => response_status(body),
            "failure_code" => failure_code(status, body),
            "next_action" => next_action(status, body),
            "message_id_prefix" => String.slice(message_id, 0, 18),
            "signature_secret_source" => signature_secret_source(connect),
            "limits" => %{
              "synthetic_signed_callback" => true,
              "raw_signature_redacted" => true,
              "raw_token_redacted" => true,
              "message_body_redacted" => true
            }
          }

        {:error, reason} ->
          %{
            "ok" => false,
            "http_status" => nil,
            "failure_code" => "callback_request_failed",
            "error" => redact(inspect(reason)),
            "next_action" => "check public callback health and tunnel"
          }
      end
    else
      _ ->
        %{
          "ok" => false,
          "http_status" => nil,
          "failure_code" => "missing_signature_secret",
          "next_action" =>
            "configure Feishu verification token or encrypt key on the runtime connect",
          "limits" => %{"raw_token_redacted" => true}
        }
    end
  end

  defp live_claim(%{"ok" => true}), do: "live-feishu-visible-chat-readiness-with-signed-callback"
  defp live_claim(_), do: "live-feishu-visible-chat-readiness-callback-blocked"

  defp real_inbound_probe(router_agent_id, connect, message_surface_probe) do
    marker_prefix = env("BRIDGE_TOB_LIVE_FEISHU_MARKER_PREFIX", "")
    base_count = parse_int(env("BRIDGE_TOB_LIVE_FEISHU_BASE_MESSAGE_COUNT", ""))
    marker_visible? = truthy?(env("BRIDGE_TOB_LIVE_FEISHU_MARKER_VISIBLE", "false"))

    cond do
      marker_prefix == "" and is_nil(base_count) ->
        %{"enabled" => false}

      router_agent_id == "" ->
        %{
          "enabled" => true,
          "ok" => false,
          "failure_code" => "missing_router_agent_id",
          "next_action" => "set BRIDGE_TOB_SMOKE_ROUTER_AGENT_ID"
        }

      true ->
        do_real_inbound_probe(
          router_agent_id,
          connect,
          marker_prefix,
          base_count,
          marker_visible?,
          message_surface_probe
        )
    end
  end

  defp do_real_inbound_probe(
         router_agent_id,
         connect,
         marker_prefix,
         base_count,
         marker_visible?,
         message_surface_probe
       ) do
    group_id = connect["group_id"] || connect[:group_id] || ""
    session_id = SalixIM.ProviderConnects.agent_group_router_session_id(router_agent_id, group_id)

    with {:ok, session} <- SalixAgent.Runtime.get_session(router_agent_id, session_id) do
      messages = Map.get(session, "messages") || Map.get(session, :messages) || []
      count = length(messages)
      start_index = if is_integer(base_count) and base_count >= 0, do: base_count, else: 0
      window = Enum.drop(messages, start_index)

      content = fn m -> to_string(Map.get(m, :content) || Map.get(m, "content") || "") end
      role = fn m -> to_string(Map.get(m, :role) || Map.get(m, "role") || "") end

      feishu_users = Enum.filter(window, &real_feishu_user_message?/1)

      marker_seen? =
        marker_prefix != "" and
          Enum.any?(window, fn m -> String.contains?(content.(m), marker_prefix) end)

      live_phrase_seen? =
        Enum.any?(feishu_users, fn m ->
          c = content.(m)
          String.contains?(c, "Bridge ToB") or String.contains?(c, "bridge-tob-live")
        end)

      first_feishu_user_index =
        Enum.find_index(window, &real_feishu_user_message?/1)

      after_first =
        if is_integer(first_feishu_user_index),
          do: Enum.drop(window, first_feishu_user_index),
          else: []

      assistant_after? = Enum.any?(after_first, fn m -> role.(m) == "assistant" end)

      llm_error_after? =
        Enum.any?(after_first, fn m ->
          c = content.(m)
          String.contains?(c, "LLM request failed") or String.contains?(c, "transport_error")
        end)

      routed? = length(feishu_users) > 0

      %{
        "enabled" => true,
        "ok" => routed? and assistant_after? and not llm_error_after?,
        "claim" =>
          real_inbound_claim(routed?, assistant_after?, llm_error_after?, marker_visible?),
        "session_id_prefix" => String.slice(session_id, 0, 12),
        "message_count" => count,
        "base_message_count" => base_count,
        "new_message_count" => max(count - start_index, 0),
        "marker_prefix" => if(marker_prefix == "", do: nil, else: marker_prefix),
        "marker_prefix_seen" => marker_seen?,
        "feishu_web_marker_visible" => marker_visible?,
        "live_phrase_seen" => live_phrase_seen?,
        "content_marker_or_phrase_seen" => marker_seen? or live_phrase_seen?,
        "feishu_user_messages_after_base" => length(feishu_users),
        "assistant_after_feishu_user" => assistant_after?,
        "llm_error_after_feishu_user" => llm_error_after?,
        "same_group_reply_observed" => false,
        "limits" => %{
          "full_message_body_redacted" => true,
          "source_message_id_redacted" => true,
          "feishu_web_marker_visible_is_operator_observed" => true,
          "same_group_reply_requires_browser_or_feishu_api_observation" => true
        },
        "next_action" =>
          real_inbound_next_action(
            routed?,
            assistant_after?,
            llm_error_after?,
            marker_visible?,
            message_surface_probe
          )
      }
    else
      {:error, reason} ->
        %{
          "enabled" => true,
          "ok" => false,
          "failure_code" => "router_session_read_failed",
          "error" => redact(inspect(reason)),
          "next_action" => "check router agent and Salix store state"
        }
    end
  end

  def real_feishu_user_message?(message) do
    role = to_string(Map.get(message, :role) || Map.get(message, "role") || "")
    content = to_string(Map.get(message, :content) || Map.get(message, "content") || "")

    source =
      to_string(
        Map.get(message, :source_message_id) || Map.get(message, "source_message_id") || ""
      )

    role == "user" and String.starts_with?(source, "im_provider:feishu:") and
      not String.contains?(content, "bridge-tob-signed-preflight")
  end

  def real_inbound_claim(true, true, false, _marker_visible?),
    do: "live-real-feishu-inbound-routed-to-session-with-assistant-stored"

  def real_inbound_claim(true, false, _, _marker_visible?),
    do: "live-real-feishu-inbound-routed-to-session-no-assistant-yet"

  def real_inbound_claim(false, _, _, true),
    do: "live-real-feishu-web-marker-visible-delivery-not-observed"

  def real_inbound_claim(false, _, _, _), do: "live-real-feishu-inbound-not-routed"

  def real_inbound_next_action(true, true, false, _marker_visible?),
    do: "verify same-group Feishu reply; stored assistant alone is not customer-usable"

  def real_inbound_next_action(true, false, _, _marker_visible?),
    do: "wait for router round or inspect LLM/provider errors"

  def real_inbound_next_action(false, _, _, true),
    do:
      "inspect Feishu event subscription delivery, message receive scopes, and app availability; the marker is visible in Feishu Web but no Feishu-sourced user message reached Salix"

  def real_inbound_next_action(false, _, _, _),
    do: "send a real Feishu Web bot mention after recording base_message_count"

  def real_inbound_next_action(routed?, assistant_after?, llm_error_after?, marker_visible?) do
    real_inbound_next_action(routed?, assistant_after?, llm_error_after?, marker_visible?, %{
      "enabled" => false
    })
  end

  def real_inbound_next_action(false, _, _, _marker_visible?, %{"enabled" => true, "ok" => false}) do
    "restore an authenticated Feishu Web target-group composer, then send a fresh real @bot mention and rerun the real-inbound probe; only try the desktop client after Web is explicitly unavailable"
  end

  def real_inbound_next_action(
        routed?,
        assistant_after?,
        llm_error_after?,
        marker_visible?,
        _surface
      ) do
    real_inbound_next_action(routed?, assistant_after?, llm_error_after?, marker_visible?)
  end

  defp message_surface_probe do
    status = env("BRIDGE_TOB_LIVE_FEISHU_MESSAGE_SURFACE_STATUS", "")

    message_surface_probe_result(
      status,
      env("BRIDGE_TOB_LIVE_FEISHU_MESSAGE_SURFACE_NOTE", ""),
      env("BRIDGE_TOB_LIVE_FEISHU_MESSAGE_SURFACE_SCREENSHOT", ""),
      %{
        "send_button_confirmed" =>
          truthy?(env("BRIDGE_TOB_LIVE_FEISHU_SEND_BUTTON_CONFIRMED", "false")),
        "mention_picker_observed" =>
          truthy?(env("BRIDGE_TOB_LIVE_FEISHU_MENTION_PICKER_OBSERVED", "false")),
        "marker_visible_after_send" =>
          truthy?(env("BRIDGE_TOB_LIVE_FEISHU_MARKER_VISIBLE_AFTER_SEND", "false"))
      }
    )
  end

  def message_surface_probe_result(status, note, screenshot_path),
    do: message_surface_probe_result(status, note, screenshot_path, %{})

  def message_surface_probe_result("", _note, _screenshot_path, _send_signals),
    do: %{"enabled" => false}

  def message_surface_probe_result(status, note, screenshot_path, send_signals) do
    status = status |> to_string() |> String.trim() |> String.downcase()
    note = trim(note)
    screenshot_path = trim(screenshot_path)
    send_signals = normalize_send_signals(send_signals)

    base = %{
      "enabled" => true,
      "status" => status,
      "ok" => status == "ready",
      "operator_note_set" => note != "",
      "redacted_screenshot_path" => if(screenshot_path == "", do: nil, else: screenshot_path),
      "limits" => %{
        "raw_chat_id_redacted" => true,
        "account_identity_redacted" => true,
        "message_body_redacted" => true,
        "screenshot_must_be_redacted" => true
      },
      "send_signals" => send_signals
    }

    Map.merge(base, message_surface_status_fields(status))
  end

  defp normalize_send_signals(send_signals) when is_map(send_signals) do
    %{
      "send_button_confirmed" => send_signals["send_button_confirmed"] == true,
      "mention_picker_observed" => send_signals["mention_picker_observed"] == true,
      "marker_visible_after_send" => send_signals["marker_visible_after_send"] == true
    }
  end

  defp normalize_send_signals(_), do: normalize_send_signals(%{})

  defp message_surface_status_fields("ready") do
    %{
      "failure_code" => nil,
      "next_action" => "send a fresh real Feishu @bot message and rerun real-inbound probe"
    }
  end

  defp message_surface_status_fields("client_required_no_composer") do
    %{
      "failure_code" => "no_usable_feishu_message_surface",
      "next_action" =>
        "restore an authenticated Feishu Web composer for the target group, then rerun real-inbound probe; only open/install the desktop client if Feishu Web redirects to client handoff/download, requires login/MFA, lacks the target group, or has no composer"
    }
  end

  defp message_surface_status_fields("web_login_required") do
    %{
      "failure_code" => "feishu_web_login_required",
      "next_action" =>
        "restore authenticated Feishu Web access for the target-group composer, then rerun real-inbound probe"
    }
  end

  defp message_surface_status_fields("web_probe_blocked_by_chrome_native_pipe") do
    %{
      "failure_code" => "chrome_native_pipe_closed",
      "next_action" =>
        "repair the Codex Chrome plugin native-pipe connection, then restore authenticated Feishu Web access for the target-group composer and rerun real-inbound probe; do not open/install the desktop client unless Feishu Web is explicitly unavailable after authentication"
    }
  end

  defp message_surface_status_fields(_status) do
    %{
      "failure_code" => "feishu_message_surface_unknown",
      "next_action" =>
        "inspect Feishu Web composer availability before sending a new marker; only try the desktop client after Web is explicitly unavailable"
    }
  end

  defp response_queued?(%{"ok" => true, "status" => status})
       when status in ["queued", "duplicate"],
       do: true

  defp response_queued?(_), do: false

  defp response_status(%{"status" => status}), do: status
  defp response_status(_), do: nil

  defp failure_code(200, body) do
    if response_queued?(body), do: nil, else: "callback_not_queued"
  end

  defp failure_code(401, %{"error" => error}) when is_binary(error) do
    cond do
      String.contains?(error, "signature") -> "invalid_signature"
      String.contains?(error, "token") -> "invalid_token"
      true -> "callback_unauthorized"
    end
  end

  defp failure_code(404, _), do: "connect_not_found"
  defp failure_code(status, _) when is_integer(status), do: "callback_http_#{status}"
  defp failure_code(_, _), do: "callback_unknown"

  defp next_action(200, body) do
    if response_queued?(body),
      do: nil,
      else: "inspect callback response and router-session evidence"
  end

  defp next_action(401, %{"error" => error}) when is_binary(error) do
    cond do
      String.contains?(error, "signature") ->
        "synchronize Feishu console Verification Token or Encrypt Key with the runtime connect"

      String.contains?(error, "token") ->
        "synchronize Feishu console Verification Token with the runtime connect"

      true ->
        "inspect Feishu signature/token configuration"
    end
  end

  defp next_action(404, _), do: "check app_id query and active Feishu connect identity"
  defp next_action(_, _), do: "inspect public callback logs and Feishu event logs"

  defp signature_secret_source(connect) do
    cond do
      trim(connect["encrypt_key"]) != "" -> "encrypt_key"
      trim(connect["verification_token"]) != "" -> "verification_token"
      true -> "none"
    end
  end

  defp feishu_signature(timestamp, request_nonce, secret, raw) do
    :crypto.hash(:sha256, timestamp <> request_nonce <> secret <> raw)
    |> Base.encode16(case: :lower)
  end

  defp first_nonblank(values) do
    values
    |> Enum.map(&trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp default_base("", fallback), do: fallback
  defp default_base(base, _fallback), do: String.trim_trailing(base, "/")

  defp nonce do
    Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end

  defp first_chat_id([chat | _]) do
    chat_id = chat_id(chat)

    if is_binary(chat_id) and chat_id != "" do
      {:ok, chat, chat_id}
    else
      {:error, :missing_chat_id}
    end
  end

  defp first_chat_id([]), do: {:error, :no_visible_chats}

  defp target_chat_probe(router_agent_id, connect, chats) do
    query = trim(env("BRIDGE_TOB_LIVE_FEISHU_TARGET_CHAT_NAME", ""))
    id_prefix = trim(env("BRIDGE_TOB_LIVE_FEISHU_TARGET_CHAT_ID_PREFIX", ""))
    matches = matching_chats(chats, query)

    selected =
      case {matching_chat_by_id_prefix(chats, id_prefix), matches} do
        {chat, _} when is_map(chat) -> chat
        {nil, [chat | _]} -> chat
        {nil, []} -> List.first(chats)
      end

    detail_probe = chat_detail_probe(router_agent_id, connect, selected)
    member_probe = member_probe(router_agent_id, connect, selected)
    observed_chat_probe = observed_chat_probe(connect, selected)
    web_chat_identity_probe = web_chat_identity_probe(selected)
    targeted? = query != "" or id_prefix != ""

    %{
      "enabled" => targeted?,
      "target_name_configured" => query != "",
      "target_chat_id_prefix_configured" => id_prefix != "",
      "target_match_count" => length(matches),
      "visible_chat_count" => length(chats),
      "selected_chat" => if(selected, do: redacted_chat(selected), else: nil),
      "detail_probe" => detail_probe,
      "member_probe" => member_probe,
      "observed_chat_probe" => observed_chat_probe,
      "web_chat_identity_probe" => web_chat_identity_probe,
      "human_group_readiness" =>
        human_group_readiness(
          targeted?,
          query,
          matches,
          chats,
          selected,
          detail_probe,
          member_probe
        ),
      "limits" => %{
        "target_name_redacted" => true,
        "target_chat_id_prefix_is_redacted_evidence" => true,
        "chat_name_redacted" => true,
        "chat_description_redacted" => true,
        "observed_chat_ids_redacted" => true,
        "web_chat_name_redacted" => true,
        "member_names_redacted" => true,
        "member_ids_redacted" => true
      }
    }
  end

  defp human_group_readiness(false, "", [], chats, selected, detail_probe, member_probe)
       when length(chats) == 1 do
    selected
    |> human_group_readiness_from_selected(detail_probe, member_probe)
    |> Map.put("selection_source", "single_visible_chat")
  end

  defp human_group_readiness(
         false,
         "",
         _matches,
         _chats,
         _selected,
         _detail_probe,
         _member_probe
       ),
       do: %{
         "attempted" => false,
         "reason" => "target_name_not_configured",
         "next_action" =>
           "set BRIDGE_TOB_LIVE_FEISHU_TARGET_CHAT_NAME when multiple chats are visible"
       }

  defp human_group_readiness(true, query, [], _chats, _selected, _detail_probe, _member_probe)
       when query != "" do
    %{
      "attempted" => true,
      "ok" => false,
      "failure_code" => "target_chat_not_visible_to_bot",
      "next_action" => "invite the current Feishu app bot to the intended smoke group"
    }
  end

  defp human_group_readiness(
         _targeted?,
         _query,
         _matches,
         _chats,
         nil,
         _detail_probe,
         _member_probe
       ) do
    %{
      "attempted" => true,
      "ok" => false,
      "failure_code" => "target_chat_selection_missing",
      "next_action" => "inspect Feishu list_chats evidence and target name"
    }
  end

  defp human_group_readiness(
         _targeted?,
         _query,
         _matches,
         _chats,
         selected,
         detail_probe,
         member_probe
       ) do
    human_group_readiness_from_selected(selected, detail_probe, member_probe)
  end

  defp human_group_readiness_from_selected(nil, _detail_probe, _member_probe) do
    %{
      "attempted" => true,
      "ok" => false,
      "failure_code" => "target_chat_selection_missing",
      "next_action" => "inspect Feishu list_chats evidence and target name"
    }
  end

  defp human_group_readiness_from_selected(_selected, detail_probe, member_probe) do
    detail_probe
    |> get_in(["chat"])
    |> classify_human_group_readiness(member_probe["member_count"])
  end

  def classify_human_group_readiness(chat, member_count) when is_map(chat) do
    chat_mode = chat["chat_mode"]
    chat_type = chat["chat_type"]

    failure_codes =
      []
      |> maybe_add(chat_mode in ["p2p", "single"], "bot_visible_chat_is_p2p")
      |> maybe_add(is_integer(member_count) and member_count < 1, "no_visible_member")

    %{
      "attempted" => true,
      "ok" => failure_codes == [],
      "failure_codes" => failure_codes,
      "chat_mode" => chat_mode,
      "chat_type" => chat_type,
      "member_count" => member_count,
      "next_action" => human_group_next_action(failure_codes)
    }
  end

  def classify_human_group_readiness(_chat, member_count),
    do: classify_human_group_readiness(%{}, member_count)

  defp maybe_add(list, true, value), do: list ++ [value]
  defp maybe_add(list, false, _value), do: list

  defp human_group_next_action([]), do: nil

  defp human_group_next_action(failure_codes) do
    cond do
      "bot_visible_chat_is_p2p" in failure_codes ->
        "open a Feishu group chat rather than the bot private chat, confirm the current app bot is installed there, then rerun target-chat and real-inbound probes"

      "no_visible_member" in failure_codes ->
        "confirm the target group has at least one human member visible to the current app bot"

      true ->
        "inspect Feishu target chat readiness"
    end
  end

  defp matching_chats(_chats, ""), do: []

  defp matching_chats(chats, query) do
    normalized = String.downcase(query)

    Enum.filter(chats, fn chat ->
      name = chat["name"] |> trim() |> String.downcase()
      name == normalized or String.contains?(name, normalized)
    end)
  end

  defp matching_chat_by_id_prefix(_chats, ""), do: nil

  defp matching_chat_by_id_prefix(chats, prefix) do
    Enum.find(chats, fn chat -> String.starts_with?(chat_id(chat), prefix) end)
  end

  defp member_probe(_router_agent_id, _connect, nil), do: %{"attempted" => false}

  defp member_probe(router_agent_id, connect, chat) do
    case chat_id(chat) do
      "" ->
        %{"attempted" => false, "failure_code" => "missing_chat_id"}

      id ->
        case SalixIM.Provider.Feishu.call(router_agent_id, connect, "feishu.list_chat_members", %{
               "chat_id" => id,
               "limit" => 50
             }) do
          {:ok, body} ->
            members = extract_items(body)

            %{
              "attempted" => true,
              "ok" => true,
              "member_count" => length(members)
            }

          {:error, reason} ->
            %{
              "attempted" => true,
              "ok" => false,
              "failure_code" => "list_chat_members_failed",
              "error" => redact(inspect(reason))
            }
        end
    end
  end

  defp chat_detail_probe(_router_agent_id, _connect, nil), do: %{"attempted" => false}

  defp chat_detail_probe(router_agent_id, connect, chat) do
    case chat_id(chat) do
      "" ->
        %{"attempted" => false, "failure_code" => "missing_chat_id"}

      id ->
        case SalixIM.Provider.Feishu.call(router_agent_id, connect, "feishu.get_chat", %{
               "chat_id" => id
             }) do
          {:ok, body} ->
            detail = unwrap_data(body)

            %{
              "attempted" => true,
              "ok" => true,
              "chat" => redacted_chat_detail(detail)
            }

          {:error, reason} ->
            %{
              "attempted" => true,
              "ok" => false,
              "failure_code" => "get_chat_failed",
              "error" => redact(inspect(reason))
            }
        end
    end
  end

  defp observed_chat_probe(_connect, nil), do: %{"attempted" => false}

  defp observed_chat_probe(connect, selected_chat) do
    {:ok, observed_chats} =
      SalixIM.ProviderObservations.list_feishu_chats(connect["connect_id"], "", 100)

    observed_chat_probe_result(selected_chat, observed_chats)
  end

  def observed_chat_probe_result(selected_chat, observed_chats)
      when is_map(selected_chat) and is_list(observed_chats) do
    selected_id = chat_id(selected_chat)

    observed_ids =
      observed_chats
      |> Enum.map(&chat_id/1)
      |> Enum.reject(&(&1 == ""))

    target_observed? = selected_id != "" and selected_id in observed_ids

    %{
      "attempted" => true,
      "ok" => target_observed?,
      "observed_chat_count" => length(observed_ids),
      "target_chat_observed" => target_observed?,
      "selected_chat_id_prefix" => String.slice(selected_id, 0, 8),
      "observed_chat_id_prefixes" =>
        observed_ids
        |> Enum.take(10)
        |> Enum.map(&String.slice(&1, 0, 8)),
      "limits" => %{
        "raw_chat_ids_redacted" => true,
        "chat_names_redacted" => true
      },
      "next_action" => observed_chat_next_action(target_observed?)
    }
  end

  def observed_chat_probe_result(_selected_chat, _observed_chats),
    do: %{"attempted" => false, "failure_code" => "target_chat_selection_missing"}

  defp observed_chat_next_action(true), do: nil

  defp observed_chat_next_action(false),
    do:
      "inspect Feishu event subscription delivery for the target chat; this bot-visible chat has not been observed from inbound events"

  defp web_chat_identity_probe(nil) do
    case web_chat_identity_inputs() do
      {nil, nil} ->
        %{"attempted" => false}

      _ ->
        %{
          "attempted" => true,
          "ok" => false,
          "failure_code" => "target_chat_selection_missing",
          "next_action" =>
            "select the bot-visible target chat before comparing Web and API identity",
          "limits" => web_chat_identity_limits()
        }
    end
  end

  defp web_chat_identity_probe(selected) do
    case web_chat_identity_inputs() do
      {nil, nil} ->
        %{"attempted" => false}

      {web_hash_prefix, web_name_length} ->
        selected_name = trim(selected["name"] || selected["chat_name"])
        api_hash_prefix = hash_prefix(selected_name)
        api_name_length = String.length(selected_name)
        name_hash_match? = web_hash_prefix != nil and web_hash_prefix == api_hash_prefix

        name_length_match? =
          is_integer(web_name_length) and web_name_length == api_name_length

        ok? = name_hash_match? and (is_nil(web_name_length) or name_length_match?)

        %{
          "attempted" => true,
          "ok" => ok?,
          "name_hash_match" => name_hash_match?,
          "name_length_match" => name_length_match?,
          "web_name_hash_prefix" => web_hash_prefix,
          "api_name_hash_prefix" => api_hash_prefix,
          "web_name_length" => web_name_length,
          "api_name_length" => api_name_length,
          "failure_code" =>
            if(ok?, do: nil, else: "web_chat_and_api_selected_chat_identity_mismatch"),
          "next_action" =>
            if(ok?,
              do: nil,
              else:
                "confirm the human Web marker is being sent in the same chat selected by the Feishu bot API"
            ),
          "limits" => web_chat_identity_limits()
        }
    end
  end

  defp web_chat_identity_inputs do
    web_hash_prefix =
      "BRIDGE_TOB_LIVE_FEISHU_WEB_CHAT_NAME_SHA256_PREFIX"
      |> env("")
      |> trim()
      |> case do
        "" -> nil
        value -> value
      end

    web_name_length =
      case parse_int(env("BRIDGE_TOB_LIVE_FEISHU_WEB_CHAT_NAME_LENGTH", "")) do
        value when is_integer(value) and value >= 0 -> value
        _ -> nil
      end

    {web_hash_prefix, web_name_length}
  end

  defp web_chat_identity_limits do
    %{
      "raw_chat_ids_redacted" => true,
      "raw_chat_names_redacted" => true,
      "hash_prefix_only" => true
    }
  end

  defp hash_prefix(value) do
    :crypto.hash(:sha256, trim(value))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  def selected_chat_identity_probe_result(target_chat_probe, real_inbound_probe, outbound_send) do
    target_ready? = get_in(target_chat_probe || %{}, ["human_group_readiness", "ok"]) == true

    target_observed? =
      get_in(target_chat_probe || %{}, ["observed_chat_probe", "target_chat_observed"]) == true

    member_count = get_in(target_chat_probe || %{}, ["member_probe", "member_count"])
    chat_mode = get_in(target_chat_probe || %{}, ["human_group_readiness", "chat_mode"])
    inbound_count = get_in(real_inbound_probe || %{}, ["feishu_user_messages_after_base"])
    marker_visible? = get_in(real_inbound_probe || %{}, ["feishu_web_marker_visible"]) == true
    outbound_attempted? = get_in(outbound_send || %{}, ["attempted"]) == true
    outbound_ok? = get_in(outbound_send || %{}, ["ok"]) == true
    web_identity = get_in(target_chat_probe || %{}, ["web_chat_identity_probe"]) || %{}
    web_identity_match? = web_identity["ok"] == true

    cond do
      get_in(real_inbound_probe || %{}, ["ok"]) == true ->
        selected_chat_identity_probe(
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

      target_ready? and marker_visible? and inbound_count == 0 and web_identity_match? ->
        selected_chat_identity_probe(
          false,
          "ready_selected_chat_hash_match_but_never_observed_inbound",
          "feishu_inbound_delivery_unverified_after_group_hash_match",
          "Feishu Web group and bot API selected chat match by redacted hash, so inspect Feishu platform event delivery/app availability before sending another marker",
          target_ready?,
          target_observed?,
          member_count,
          chat_mode,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?,
          %{
            "web_chat_name_hash_match" => true,
            "web_chat_name_length_match" => web_identity["name_length_match"] == true
          }
        )

      target_ready? and marker_visible? and inbound_count == 0 and outbound_ok? and
          not target_observed? ->
        selected_chat_identity_probe(
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
        selected_chat_identity_probe(
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
        selected_chat_identity_probe(
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

      target_ready? or marker_visible? or is_integer(inbound_count) ->
        selected_chat_identity_probe(
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
        %{"attempted" => false}
    end
  end

  defp selected_chat_identity_probe(
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
         outbound_ok?,
         extra_signals \\ %{}
       ) do
    %{
      "attempted" => true,
      "ok" => ok?,
      "status" => status,
      "failure_code" => failure_code,
      "next_action" => next_action,
      "signals" =>
        %{
          "target_ready" => target_ready?,
          "target_chat_observed_from_inbound_events" => target_observed?,
          "target_member_count" => member_count,
          "target_chat_mode" => chat_mode,
          "feishu_user_messages_after_base" => inbound_count,
          "feishu_web_marker_visible" => marker_visible?,
          "bot_outbound_attempted" => outbound_attempted?,
          "bot_outbound_to_selected_chat_ok" => outbound_ok?
        }
        |> Map.merge(extra_signals),
      "limits" => %{
        "raw_chat_ids_redacted" => true,
        "raw_chat_names_redacted" => true,
        "message_body_redacted" => true,
        "account_identity_redacted" => true
      }
    }
  end

  def delivery_consistency_probe_result(
        message_surface_probe,
        target_chat_probe,
        real_inbound_probe,
        outbound_send \\ %{"attempted" => false}
      ) do
    message_surface_ready? = get_in(message_surface_probe || %{}, ["ok"]) == true
    target_ready? = get_in(target_chat_probe || %{}, ["human_group_readiness", "ok"]) == true

    target_observed? =
      get_in(target_chat_probe || %{}, ["observed_chat_probe", "target_chat_observed"]) == true

    inbound_count = get_in(real_inbound_probe || %{}, ["feishu_user_messages_after_base"])
    marker_visible? = get_in(real_inbound_probe || %{}, ["feishu_web_marker_visible"]) == true
    outbound_attempted? = get_in(outbound_send || %{}, ["attempted"]) == true
    outbound_ok? = get_in(outbound_send || %{}, ["ok"]) == true

    cond do
      get_in(real_inbound_probe || %{}, ["ok"]) == true ->
        delivery_consistency_probe(
          true,
          "real_inbound_observed",
          nil,
          nil,
          message_surface_ready?,
          target_ready?,
          target_observed?,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      message_surface_ready? and target_ready? and marker_visible? and inbound_count == 0 and
        outbound_attempted? and not outbound_ok? ->
        delivery_consistency_probe(
          false,
          "selected_chat_outbound_failed",
          "feishu_app_availability_or_send_permission_unverified",
          "inspect Feishu app availability/install state and message send permission for the selected target group before sending another human marker",
          message_surface_ready?,
          target_ready?,
          target_observed?,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      message_surface_ready? and target_ready? and marker_visible? and inbound_count == 0 and
          outbound_ok? ->
        delivery_consistency_probe(
          false,
          "visible_web_marker_not_delivered_bot_outbound_ok",
          "feishu_inbound_event_delivery_unverified",
          "bot outbound to the selected group works, so inspect inbound event delivery logs, selected-group identity, and event subscription delivery before sending another marker",
          message_surface_ready?,
          target_ready?,
          target_observed?,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      message_surface_ready? and target_ready? and marker_visible? and inbound_count == 0 ->
        delivery_consistency_probe(
          false,
          "visible_web_marker_not_delivered",
          "feishu_platform_delivery_or_app_availability_unverified",
          "inspect Feishu app availability/install state for the selected group, confirm the selected bot-visible group is the same group as the human Web marker, and inspect Feishu event delivery logs before sending another marker",
          message_surface_ready?,
          target_ready?,
          target_observed?,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      message_surface_ready? or target_ready? or
          get_in(real_inbound_probe || %{}, ["enabled"]) == true ->
        delivery_consistency_probe(
          false,
          "insufficient_delivery_evidence",
          "delivery_evidence_incomplete",
          "complete message-surface, target readiness, marker visibility, and real-inbound probes in one run",
          message_surface_ready?,
          target_ready?,
          target_observed?,
          inbound_count,
          marker_visible?,
          outbound_attempted?,
          outbound_ok?
        )

      true ->
        %{"attempted" => false}
    end
  end

  defp delivery_consistency_probe(
         ok?,
         status,
         failure_code,
         next_action,
         message_surface_ready?,
         target_ready?,
         target_observed?,
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
        "message_surface_ready" => message_surface_ready?,
        "target_ready" => target_ready?,
        "target_chat_observed_from_inbound_events" => target_observed?,
        "feishu_web_marker_visible" => marker_visible?,
        "feishu_user_messages_after_base" => inbound_count,
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

  defp redacted_chat(chat) do
    chat_id = chat_id(chat)

    %{
      "chat_id_prefix" => String.slice(chat_id, 0, 8),
      "chat_mode" => chat["chat_mode"],
      "chat_type" => chat["chat_type"] || chat["type"],
      "name_set" => is_binary(chat["name"]) and chat["name"] != ""
    }
  end

  defp redacted_chat_detail(chat) when is_map(chat) do
    chat_id = chat_id(chat)

    %{
      "chat_id_prefix" => String.slice(chat_id, 0, 8),
      "chat_mode" => chat["chat_mode"],
      "chat_type" => chat["chat_type"] || chat["type"],
      "member_count" => chat["member_count"],
      "owner_id_set" => present?(chat["owner_id"]),
      "tenant_key_set" => present?(chat["tenant_key"]),
      "name_set" => present?(chat["name"]),
      "description_set" => present?(chat["description"])
    }
  end

  defp chat_id(chat),
    do: to_string(chat["chat_id"] || chat["open_chat_id"] || chat["chat_id_v2"] || "")

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp unwrap_data(%{"data" => data}) when is_map(data), do: data
  defp unwrap_data(body) when is_map(body), do: body
  defp unwrap_data(_), do: %{}

  defp extract_items(%{"data" => %{"items" => items}}) when is_list(items), do: items
  defp extract_items(%{"items" => items}) when is_list(items), do: items
  defp extract_items(_), do: []

  defp write_evidence!(path, evidence) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(evidence, pretty: true))
  end

  defp records(prefix) do
    case SalixStore.S3.list(prefix, max_keys: @record_scan_max_records) do
      {:ok, %{objects: objects, next: nil}} when length(objects) <= @record_scan_max_records ->
        Enum.map(objects, fn %{key: key} ->
          case SalixStore.CasRecord.get(key) do
            {:ok, record} -> record
            {:error, reason} -> raise "record scan GET failed: #{inspect(reason)}"
          end
        end)

      {:ok, %{next: _continuation}} ->
        raise "record scan exceeded #{@record_scan_max_records} records"

      {:error, reason} ->
        raise "record scan LIST failed: #{inspect(reason)}"
    end
  end

  defp env(name, default),
    do: System.get_env(name) || System.get_env(legacy_name(name)) || default

  defp legacy_name("BRIDGE_TOB_FEISHU_WEBHOOK_URL_FILE"), do: "THREAD_A_FEISHU_WEBHOOK_URL_FILE"
  defp legacy_name("BRIDGE_TOB_SMOKE_ROUTER_AGENT_ID"), do: "THREAD_A_SMOKE_ROUTER_AGENT_ID"
  defp legacy_name(name), do: name

  defp truthy?(value), do: String.downcase(to_string(value)) in ["1", "true", "yes", "y"]

  defp parse_int(""), do: nil

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp redact(value) do
    value
    |> to_string()
    |> String.replace(~r/cli_[A-Za-z0-9_-]+/, "cli_REDACTED")
    |> String.replace(~r/\b(oc|ou|om|on)_[A-Za-z0-9_-]+\b/, "\\1_REDACTED")
    |> String.replace(~r/token_type=[^&\s"]+/, "token_type=<redacted>")
  end
end

unless System.get_env("BRIDGE_TOB_LIVE_FEISHU_SKIP_RUN") == "true" do
  BridgeToB.FeishuLiveSmoke.run()
end
