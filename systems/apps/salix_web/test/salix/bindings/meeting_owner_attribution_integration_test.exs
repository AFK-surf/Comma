defmodule Salix.Bindings.MeetingOwnerAttributionIntegrationTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.MeetingOwnerAttribution
  alias Salix.Control
  alias SalixAgent.{AgentControl, Templates}
  alias SalixStore.{CasRecord, Keys}

  defmodule FeishuRosterResolver do
    def resolve_with_roster(_state, items) do
      case Application.get_env(
             :salix_web,
             :meeting_owner_attribution_integration_feishu_members
           ) do
        members when is_list(members) ->
          {:ok,
           Salix.Bindings.FeishuMeetingOwnerResolver.resolve_members_with_context(
             items,
             members
           )}

        _ ->
          {:ok,
           %{
             mapping: %{},
             roster:
               Application.fetch_env!(
                 :salix_web,
                 :meeting_owner_attribution_integration_feishu_roster
               ),
             blocked_owner_indices: []
           }}
      end
    end
  end

  defmodule Provider do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    post "/users.list" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid(), {:slack_roster_request, URI.decode_query(body)})

      response = %{
        "ok" => true,
        "members" => [
          %{
            "id" => "U123ALICE",
            "real_name" => "Alice Example",
            "profile" => %{"display_name" => "alice"}
          }
        ],
        "response_metadata" => %{"next_cursor" => ""}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    post "/chat/completions" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      send(test_pid(), {:owner_attribution_llm_request, request})

      system_prompt = get_in(request, ["messages", Access.at(0), "content"])

      matches =
        case Application.get_env(
               :salix_web,
               :meeting_owner_attribution_integration_matches
             ) do
          nil when is_binary(system_prompt) ->
            if String.contains?(system_prompt, "Feishu") do
              [
                %{
                  "owner" => "3720",
                  "feishu_open_id" => "ou_3720",
                  "confidence" => "high"
                }
              ]
            else
              [
                %{
                  "owner" => "Alice",
                  "slack_id" => "U123ALICE",
                  "confidence" => "high"
                }
              ]
            end

          configured when is_list(configured) ->
            configured

          _other ->
            []
        end

      content =
        Jason.encode!(%{
          "matches" => matches
        })

      response = %{
        "id" => "chatcmpl-owner-attribution-test",
        "object" => "chat.completion",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    match _ do
      Plug.Conn.send_resp(conn, 404, "not found")
    end

    defp test_pid do
      Application.fetch_env!(:salix_web, :meeting_owner_attribution_integration_test_pid)
    end
  end

  setup do
    previous = %{
      s3_backend: Application.get_env(:salix_store, :s3_backend),
      slack_api_base_url: Application.get_env(:salix_im, :slack_api_base_url),
      enabled: Application.get_env(:salix_meet, :meeting_owner_attribution_enabled),
      skip_metering: Application.get_env(:salix_web, :meeting_owner_attribution_skip_metering),
      test_pid: Application.get_env(:salix_web, :meeting_owner_attribution_integration_test_pid),
      feishu_resolver: Application.get_env(:salix_web, :meeting_feishu_owner_resolver_mod),
      feishu_roster:
        Application.get_env(
          :salix_web,
          :meeting_owner_attribution_integration_feishu_roster
        ),
      feishu_members:
        Application.get_env(
          :salix_web,
          :meeting_owner_attribution_integration_feishu_members
        ),
      matches: Application.get_env(:salix_web, :meeting_owner_attribution_integration_matches)
    }

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_meet, :meeting_owner_attribution_enabled, true)
    Application.put_env(:salix_web, :meeting_owner_attribution_skip_metering, true)

    Application.put_env(
      :salix_web,
      :meeting_feishu_owner_resolver_mod,
      FeishuRosterResolver
    )

    Application.put_env(
      :salix_web,
      :meeting_owner_attribution_integration_feishu_roster,
      [
        %{"user_id" => "ou_jinfei", "display_name" => "杨晋飞"},
        %{"user_id" => "ou_3720", "display_name" => "三七二十"}
      ]
    )

    Application.put_env(
      :salix_web,
      :meeting_owner_attribution_integration_test_pid,
      self()
    )

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    start_supervised!(
      {Bandit,
       plug: Provider,
       port: 0,
       startup_log: false,
       thousand_island_options: [supervisor_options: [name: __MODULE__.ProviderServer]]}
    )

    {:ok, {_address, port}} = ThousandIsland.listener_info(__MODULE__.ProviderServer)
    base_url = "http://127.0.0.1:#{port}"
    Application.put_env(:salix_im, :slack_api_base_url, base_url)

    suffix = System.unique_integer([:positive])

    assert {:ok, %{"tenant_id" => tenant_id}} =
             Control.create_tenant(%{"name" => "Owner attribution integration tenant"})

    assert {:ok, %{"group_id" => group_id}} =
             Control.create_group(%{"name" => "Owner attribution integration group"}, tenant_id)

    assert {:ok, %{"template_id" => template_id}} =
             Templates.create(%{
               "template_id" => "tmpl-owner-attribution-integration-#{suffix}",
               "name" => "Owner attribution integration",
               "provider" => "openai",
               "model" => "mock-owner-attribution-model",
               "max_tokens" => 1_500,
               "context_tokens" => 8_192,
               "provider_config" => %{
                 "base_url" => base_url,
                 "api_key" => "test-key",
                 "protocol" => "chat_completions"
               }
             })

    assert {:ok, %{"agent_id" => router_id}} =
             AgentControl.create(
               %{
                 "group_id" => group_id,
                 "name" => "Owner attribution router",
                 "role" => "router",
                 "template_id" => template_id
               },
               tenant_id
             )

    assert {:ok, _group} =
             Control.update_group(group_id, %{"router_agent_id" => router_id}, tenant_id)

    connect_id = "slack-owner-attribution-integration-#{suffix}"
    now = System.system_time(:millisecond)

    assert {:ok, _connect} =
             CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
               "tenant_id" => tenant_id,
               "group_id" => group_id,
               "connect_id" => connect_id,
               "provider" => "slack",
               "status" => "connected",
               "workspace_id" => "T_OWNER_ATTRIBUTION_TEST",
               "bot_token" => "xoxb-owner-attribution-test",
               "oauth_completed_at" => now,
               "created_at" => now,
               "updated_at" => now
             })

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous.s3_backend)
      restore_env(:salix_im, :slack_api_base_url, previous.slack_api_base_url)
      restore_env(:salix_meet, :meeting_owner_attribution_enabled, previous.enabled)

      restore_env(
        :salix_web,
        :meeting_owner_attribution_skip_metering,
        previous.skip_metering
      )

      restore_env(
        :salix_web,
        :meeting_owner_attribution_integration_test_pid,
        previous.test_pid
      )

      restore_env(
        :salix_web,
        :meeting_feishu_owner_resolver_mod,
        previous.feishu_resolver
      )

      restore_env(
        :salix_web,
        :meeting_owner_attribution_integration_feishu_roster,
        previous.feishu_roster
      )

      restore_env(
        :salix_web,
        :meeting_owner_attribution_integration_feishu_members,
        previous.feishu_members
      )

      restore_env(
        :salix_web,
        :meeting_owner_attribution_integration_matches,
        previous.matches
      )
    end)

    {:ok, tenant_id: tenant_id, group_id: group_id, connect_id: connect_id}
  end

  test "attribute/3 sends canonical chat-only context to the real LLM request", context do
    state = %{
      "provider" => "slack",
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "connect_id" => context.connect_id,
      "captions" => [
        %{
          "speaker" => "Wrong source",
          "text" => "CAPTION_CONTEXT_MUST_NOT_REACH_PROVIDER",
          "timestamp" => 1
        }
      ],
      "chats" => []
    }

    summary = %{
      "action_items" => [
        %{
          "description" => "Publish the release checklist",
          "owner" => "Alice",
          "owner_slack_id" => "U_UNTRUSTED"
        }
      ]
    }

    canonical_context = %{
      "source" => "chat",
      "transcript" =>
        "In-meeting chat:\nAlice: I own the release checklist. " <>
          "CHAT_ONLY_CANONICAL_CONTEXT_MARKER"
    }

    assert {:ok, enriched} =
             MeetingOwnerAttribution.attribute(state, summary, canonical_context)

    assert get_in(enriched, ["action_items", Access.at(0), "owner_slack_id"]) == "U123ALICE"

    assert_receive {:slack_roster_request, %{"limit" => "200"}}, 2_000
    assert_receive {:owner_attribution_llm_request, request}, 2_000

    assert request["model"] == "mock-owner-attribution-model"
    assert request["max_tokens"] == 1_500

    user_prompt = get_in(request, ["messages", Access.at(1), "content"])
    assert user_prompt =~ "CHAT_ONLY_CANONICAL_CONTEXT_MARKER"
    refute user_prompt =~ "CAPTION_CONTEXT_MUST_NOT_REACH_PROVIDER"
  end

  test "Feishu attributes an ASR alias only to a member of the current chat roster", context do
    state = %{
      "provider" => "feishu",
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "connect_id" => "feishu-current-chat",
      "feishu_ref" => %{"chat_type" => "group", "chat_id" => "oc_current"}
    }

    summary = %{
      "action_items" => [
        %{"description" => "验证会议结果", "owner" => "3720", "deadline" => ""}
      ]
    }

    canonical_context = %{
      "source" => "captions",
      "transcript" => "杨晋飞：会议结束后请 3720 验证会议结果。"
    }

    assert {:ok, enriched} =
             MeetingOwnerAttribution.attribute(state, summary, canonical_context)

    assert get_in(enriched, ["action_items", Access.at(0), "owner_provider_identity"]) == %{
             "provider" => "feishu",
             "user_id" => "ou_3720",
             "display_name" => "三七二十"
           }

    assert_receive {:owner_attribution_llm_request, request}, 2_000

    user_prompt = get_in(request, ["messages", Access.at(1), "content"])
    assert user_prompt =~ "ou_jinfei"
    assert user_prompt =~ "杨晋飞"
    assert user_prompt =~ "ou_3720"
    assert user_prompt =~ "三七二十"
    assert user_prompt =~ "会议结束后请 3720 验证会议结果"
  end

  for %{label: label, matches: matches, item: item, transcript: transcript} <- [
        %{
          label: "an LLM identity that is absent from the current chat roster",
          matches: [
            %{"owner" => "3720", "feishu_open_id" => "ou_outsider", "confidence" => "high"}
          ],
          item: %{"description" => "验证会议结果", "owner" => "3720", "deadline" => ""},
          transcript: "请 3720 验证会议结果。"
        },
        %{
          label: "conflicting current-chat and outsider identities for one owner",
          matches: [
            %{"owner" => "3720", "feishu_open_id" => "ou_3720", "confidence" => "high"},
            %{"owner" => "3720", "feishu_open_id" => "ou_outsider", "confidence" => "high"}
          ],
          item: %{"description" => "验证会议结果", "owner" => "3720", "deadline" => ""},
          transcript: "请 3720 验证会议结果。"
        },
        %{
          label: "a numeric owner even when its string form is in the prompt",
          matches: [%{"owner" => 3720, "feishu_open_id" => "ou_3720", "confidence" => "high"}],
          item: %{"description" => "验证", "owner" => "3720"},
          transcript: "请 3720 验证。"
        },
        %{
          label: "the whole structured result when its matches array is malformed",
          matches: [
            %{"owner" => "3720", "feishu_open_id" => "ou_3720", "confidence" => "high"},
            "not-a-match-object"
          ],
          item: %{"description" => "验证", "owner" => "3720"},
          transcript: "请 3720 验证。"
        }
      ] do
    @matches matches
    @item item
    @transcript transcript
    test "Feishu rejects #{label}", context do
      Application.put_env(:salix_web, :meeting_owner_attribution_integration_matches, @matches)

      assert {:ok, enriched} =
               MeetingOwnerAttribution.attribute(
                 feishu_state(context),
                 %{"action_items" => [@item]},
                 %{"source" => "captions", "transcript" => @transcript}
               )

      refute get_in(enriched, ["action_items", Access.at(0), "owner_provider_identity"])
    end
  end

  test "Feishu never remaps a duplicate exact roster name through alias attribution", context do
    Application.put_env(:salix_web, :meeting_owner_attribution_integration_feishu_members, [
      %{"member_id" => "ou_alice_1", "name" => "Alice"},
      %{"member_id" => "ou_alice_2", "name" => "Alice"},
      %{"member_id" => "ou_bob", "name" => "Bob"}
    ])

    Application.put_env(:salix_web, :meeting_owner_attribution_integration_matches, [
      %{"owner" => "Alice", "feishu_open_id" => "ou_bob", "confidence" => "high"}
    ])

    summary = %{"action_items" => [%{"description" => "Ship", "owner" => "Alice"}]}

    assert {:ok, enriched} =
             MeetingOwnerAttribution.attribute(feishu_state(context), summary, %{
               "source" => "captions",
               "transcript" => "Alice will ship."
             })

    refute get_in(enriched, ["action_items", Access.at(0), "owner_provider_identity"])
    refute_receive {:owner_attribution_llm_request, _request}, 100
  end

  for %{label: label, matches: matches, transcript: transcript} <- [
        %{
          label: "rejects every identity when one structured match has malformed fields",
          matches: [
            %{"owner" => "Alice", "feishu_open_id" => "ou_jinfei", "confidence" => "high"},
            %{"owner" => "Bob", "feishu_open_id" => 123, "confidence" => "high"}
          ],
          transcript: "Alice will ship the summary. Bob will verify the recording."
        },
        %{
          label: "validates malformed siblings even after an owner is already conflicted",
          matches: [
            %{"owner" => "Alice", "feishu_open_id" => "ou_jinfei", "confidence" => "high"},
            %{"owner" => "Bob", "feishu_open_id" => "ou_outsider", "confidence" => "high"},
            %{"owner" => "Bob", "feishu_open_id" => 123, "confidence" => "high"}
          ],
          transcript: "Alice will ship the summary. Bob will verify the recording."
        }
      ] do
    @matches matches
    @transcript transcript
    test "Feishu #{label}", context do
      Application.put_env(:salix_web, :meeting_owner_attribution_integration_matches, @matches)

      summary = %{
        "action_items" => [
          %{"description" => "Ship the summary", "owner" => "Alice"},
          %{"description" => "Verify the recording", "owner" => "Bob"}
        ]
      }

      assert {:ok, enriched} =
               MeetingOwnerAttribution.attribute(feishu_state(context), summary, %{
                 "source" => "captions",
                 "transcript" => @transcript
               })

      assert Enum.all?(enriched["action_items"], fn item ->
               is_nil(item["owner_provider_identity"])
             end)
    end
  end

  test "Feishu keeps structurally valid low confidence local to that owner", context do
    Application.put_env(:salix_web, :meeting_owner_attribution_integration_matches, [
      %{
        "owner" => "Alice",
        "feishu_open_id" => "ou_jinfei",
        "confidence" => "high"
      },
      %{"owner" => "Bob", "feishu_open_id" => "ou_3720", "confidence" => "low"}
    ])

    assert {:ok, enriched} =
             MeetingOwnerAttribution.attribute(
               feishu_state(context),
               %{
                 "action_items" => [
                   %{"description" => "Ship the summary", "owner" => "Alice"},
                   %{"description" => "Verify the recording", "owner" => "Bob"}
                 ]
               },
               %{
                 "source" => "captions",
                 "transcript" => "Alice will ship the summary. Bob might verify the recording."
               }
             )

    assert get_in(enriched, ["action_items", Access.at(0), "owner_provider_identity"]) == %{
             "provider" => "feishu",
             "user_id" => "ou_jinfei",
             "display_name" => "杨晋飞"
           }

    refute get_in(enriched, ["action_items", Access.at(1), "owner_provider_identity"])
  end

  defp feishu_state(context) do
    %{
      "provider" => "feishu",
      "tenant_id" => context.tenant_id,
      "group_id" => context.group_id,
      "connect_id" => "feishu-current-chat",
      "feishu_ref" => %{"chat_type" => "group", "chat_id" => "oc_current"}
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
