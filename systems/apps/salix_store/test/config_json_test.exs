defmodule SalixStore.ConfigJsonTest do
  @moduledoc """
  The willow-style config.json loader: path resolution, parse, the
  config-only app-env mapping, coercions, forward compatibility.
  """
  use SystemsClock.Case, async: false

  alias SalixStore.ConfigJson

  @json %{
    "storage" => %{
      "endpoint" => "http://minio:9000",
      "bucket" => "from-file",
      "conditional_delete" => "emulate",
      "atomic_operations" => "gcp"
    },
    "web" => %{
      "port" => 4321,
      "api_token" => "file-token",
      "api_base_url" => "https://api.example.test"
    },
    "transfer" => %{
      "port" => 4400,
      "advertise_host" => "transfer.example.test",
      "advertise_port" => 14400
    },
    "meetings" => %{
      "runtime_url" => "http://meeting-runtime:8080",
      "agent_template" => "meeting-agent-template",
      "summary_template" => "meeting-summary-template",
      "asr_template" => "meeting-asr-template",
      "feishu_action_activation_enabled" => true,
      "lark_action_activation_enabled" => true,
      "calendar_autojoin" => %{
        "enabled" => true,
        "scan_interval_ms" => 120_000,
        "join_interval_ms" => 60_000,
        "max_groups_per_pass" => 25,
        "max_events_per_group" => 50,
        "max_concurrency" => 5,
        "task_timeout_ms" => 30_000,
        "channels" => %{
          "slack-abc123" => %{
            "channel" => "#botarena",
            "calendars" => ["Comma Event"]
          }
        }
      }
    },
    "cloud_vm_archives" => %{
      "r2" => %{
        "endpoint" => "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
        "bucket" => "salix-vm-archives-staging",
        "access_key_id" => "test-r2-access",
        "secret_access_key" => "test-r2-secret",
        "zstd_enabled" => false
      }
    },
    "vm" => %{
      "default_provider" => "cloudflare",
      "providers" => %{
        "cloudflare" => %{
          "enabled" => true,
          "gateway_base_url" => "https://salix-vm-gateway-staging.example.workers.dev",
          "gateway_secret" => "gateway-secret"
        }
      }
    },
    "bridge_for_teams" => %{
      "database" => %{"url" => "ecto://u:p@127.0.0.1:5432/bridge_for_teams"},
      "bft_cli" => %{
        "artifact_base_url" => "https://release.example.test/bft-cli",
        "release_id" => "latest"
      },
      "web" => %{"public_base_url" => "https://teams.example.test"},
      "dashboard" => %{
        "secret_key_base" => "bridge-secret",
        "server" => true,
        "impersonator_org_slug" => "support-admins"
      }
    },
    "search" => %{"exa_api_key" => "file-exa"},
    "email" => %{
      "postmark_server_token" => "file-postmark-token",
      "owner_notification_from_email" => "agents@file.test",
      "magic_link_from_email" => "login@file.test"
    },
    "future_section" => %{"unknown" => true}
  }

  describe "comma.apns" do
    test "only absent structured configuration admits explicit local legacy mapping" do
      legacy = [
        team_id: "LEGACYTEAM",
        key_id: "LEGACYKEY",
        private_key: "test-only-pem",
        bundle_id: "surf.comma.ios"
      ]

      assert ConfigJson.apns_config(%{}) == nil
      config = ConfigJson.apns_config(%{}, legacy)
      assert config[:profiles]["sandbox"][:legacy_bundle_id] == "surf.comma.ios"
      assert config[:profiles]["production"][:allowed_bundle_ids] == ["surf.comma.ios"]
      assert ConfigJson.apns_config(%{"comma" => %{"apns" => %{}}}, legacy) == [profiles: %{}]

      assert_raise ArgumentError, fn ->
        ConfigJson.apns_config(%{"comma" => %{"apns" => nil}}, legacy)
      end

      sandbox = %{
        "team_id" => "TEAM",
        "key_id" => "KEY",
        "private_key" => "test-only-pem",
        "allowed_bundle_ids" => ["surf.comma.ios.dev"]
      }

      config = ConfigJson.apns_config(%{"comma" => %{"apns" => %{"sandbox" => sandbox}}}, legacy)
      assert config[:profiles]["production"] == nil
      assert config[:profiles]["sandbox"][:legacy_bundle_id] == nil
    end

    test "malformed signing profiles fail without disclosing their secret values" do
      secret = "test-secret-must-not-appear-in-error"

      profile = %{
        "team_id" => "TEAM",
        "key_id" => "KEY",
        "private_key" => secret,
        "allowed_bundle_ids" => ["surf.comma.ios"]
      }

      for invalid <- [
            Map.delete(profile, "key_id"),
            Map.put(profile, "allowed_bundle_ids", ["other.apple.app"]),
            Map.put(profile, "allowed_bundle_ids", []),
            Map.put(profile, "legacy_bundle_id", "surf.comma.ios.dev"),
            Map.put(profile, "privateKey", secret),
            true
          ] do
        error =
          assert_raise ArgumentError, fn ->
            ConfigJson.apns_config(%{"comma" => %{"apns" => %{"production" => invalid}}})
          end

        refute Exception.message(error) =~ secret
      end
    end
  end

  describe "comma.synchronicity" do
    for {name, base_url, normalized} <- [
          {"maps a complete integration config and normalizes the origin",
           "https://sync.example.test/", "https://sync.example.test"},
          {"allows HTTP only for loopback development origins", "http://127.0.0.1:4400/",
           "http://127.0.0.1:4400"}
        ] do
      test name do
        secret = String.duplicate("s", 32)

        assert ConfigJson.synchronicity_env(%{
                 "comma" => %{
                   "synchronicity" => %{
                     "base_url" => unquote(base_url),
                     "provisioning_secret" => secret
                   }
                 }
               }) == [
                 {:comma_core, :synchronicity,
                  [base_url: unquote(normalized), provisioning_secret: secret]}
               ]
      end
    end

    test "does not echo an invalid provisioning secret in the boot error" do
      secret = "sensitive-but-too-short"

      error =
        assert_raise ArgumentError, fn ->
          ConfigJson.synchronicity_env(%{
            "comma" => %{
              "synchronicity" => %{
                "base_url" => "https://sync.example.test",
                "provisioning_secret" => secret
              }
            }
          })
        end

      refute Exception.message(error) =~ secret
      assert Exception.message(error) =~ "#{byte_size(secret)} bytes"
    end
  end

  test "file values land on the right app/key with coercions" do
    env = ConfigJson.app_env(@json)

    assert {:salix_store, :s3_endpoint, "http://minio:9000"} in env
    assert {:salix_store, :s3_bucket, "from-file"} in env
    assert {:salix_store, :s3_conditional_delete, :emulate} in env
    assert {:salix_store, :s3_atomic_operations, :gcp} in env
    assert {:salix_web, :port, 4321} in env
    assert {:salix_web, :api_token, "file-token"} in env
    # web.api_base_url → :public_base_url; config.json only (no SALIX_PUBLIC_BASE_URL).
    assert {:salix_web, :public_base_url, "https://api.example.test"} in env
    assert {:salix_env, :transfer_port, 4400} in env
    assert {:salix_env, :advertise_host, "transfer.example.test"} in env
    assert {:salix_env, :advertise_port, 14400} in env
    assert {:salix_meet, :runtime_base_url, "http://meeting-runtime:8080"} in env
    assert {:salix_meet, :agent_template, "meeting-agent-template"} in env
    assert {:salix_web, :meeting_summary_template, "meeting-summary-template"} in env
    assert {:salix_web, :meeting_asr_template, "meeting-asr-template"} in env

    assert {:salix_meet, :meeting_feishu_activation_enabled, true} in env
    assert {:salix_meet, :meeting_lark_activation_enabled, true} in env

    assert {:salix_meet, :calendar_autojoin,
            [
              scan_interval_ms: 120_000,
              join_interval_ms: 60_000,
              max_groups_per_pass: 25,
              max_events_per_group: 50,
              max_concurrency: 5,
              task_timeout_ms: 30_000
            ]} in env

    assert {:salix_meet, :calendar_autojoin_channels,
            [
              %{
                "connect_id" => "slack-abc123",
                "channel" => "#botarena",
                "calendars" => ["Comma Event"]
              }
            ]} in env

    # The meeting_join RPC bound is derived from the same task budget so the
    # RPC always returns strictly before the per-group task is killed.
    assert {:salix_env, :protocol_timeouts, %{"meeting_join" => 20_000}} in env

    assert {:salix_agent, :exa_api_key, "file-exa"} in env
    assert {:salix_store, :postmark_server_token, "file-postmark-token"} in env
    assert {:salix_agent, :owner_notification_from_email, "agents@file.test"} in env
    assert {:bridge_for_teams_core, :magic_link_from_email, "login@file.test"} in env

    assert {:salix_env, :cloudflare_vm_gateway,
            [
              base_url: "https://salix-vm-gateway-staging.example.workers.dev",
              secret: "gateway-secret"
            ]} in env

    assert {:salix_web, :cloud_vm_archive_r2,
            %{
              "endpoint" => "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
              "bucket" => "salix-vm-archives-staging",
              "access_key_id" => "test-r2-access",
              "secret_access_key" => "test-r2-secret",
              "zstd_enabled" => false
            }} in env

    expected_vm = %{
      "default_provider" => "cloudflare",
      "providers" => %{
        "cloudflare" => %{
          "enabled" => true,
          "gateway_base_url" => "https://salix-vm-gateway-staging.example.workers.dev",
          "gateway_secret" => "gateway-secret"
        }
      }
    }

    assert {:comma_core, :salix_vm, expected_vm} in env
    assert {:salix_web, :platform_vm, expected_vm} in env
    refute {:bridge_for_teams_core, :salix_vm, expected_vm} in env
    # LLM provider config is per agent template only — no cluster-wide section.
    refute Enum.any?(env, fn {app, _k, _v} -> app == :salix_llm end)

    assert ConfigJson.string(@json, ~w(bridge_for_teams dashboard impersonator_org_slug)) ==
             "support-admins"

    assert ConfigJson.string(@json, ~w(bridge_for_teams bft_cli artifact_base_url)) ==
             "https://release.example.test/bft-cli"

    assert ConfigJson.string(@json, ~w(bridge_for_teams bft_cli release_id)) == "latest"

    refute ConfigJson.string(@json, ~w(salix_dashboard impersonator_org_slug))
  end

  test "environment variables are not fallback configuration" do
    previous_bucket = System.get_env("SALIX_S3_BUCKET")
    previous_atomic = System.get_env("SALIX_S3_ATOMIC_OPERATIONS")
    previous_port = System.get_env("SALIX_HTTP_PORT")
    previous_runtime = System.get_env("SALIX_MEETING_RUNTIME_URL")

    System.put_env("SALIX_S3_BUCKET", "from-env")
    System.put_env("SALIX_S3_ATOMIC_OPERATIONS", "s3")
    System.put_env("SALIX_HTTP_PORT", "9999")
    System.put_env("SALIX_MEETING_RUNTIME_URL", "http://runtime-env:9000")

    on_exit(fn ->
      restore_env("SALIX_S3_BUCKET", previous_bucket)
      restore_env("SALIX_S3_ATOMIC_OPERATIONS", previous_atomic)
      restore_env("SALIX_HTTP_PORT", previous_port)
      restore_env("SALIX_MEETING_RUNTIME_URL", previous_runtime)
    end)

    env = ConfigJson.app_env(@json)

    assert {:salix_store, :s3_bucket, "from-file"} in env
    assert {:salix_store, :s3_atomic_operations, :gcp} in env
    assert {:salix_web, :port, 4321} in env
    assert {:salix_meet, :runtime_base_url, "http://meeting-runtime:8080"} in env
    assert {:salix_store, :s3_endpoint, "http://minio:9000"} in env
  end

  test "the native Meet master-token-factory is configured from the meetings section" do
    base_url = "https://master-token-factory.example.workers.dev"

    json = %{
      "meetings" => %{
        "runtime_source" => "native_runtime",
        "master_token_factory" => %{
          "base_url" => base_url,
          "secret" => "mtf-secret",
          "profile" => "Default"
        }
      }
    }

    env = ConfigJson.app_env(json)

    assert {:salix_meet_native, :master_token_factory, [base_url: base_url, secret: "mtf-secret"]} in env

    assert {:salix_meet_native, :google_profile, "Default"} in env
    assert {:salix_meet, :default_runtime_source, "native_runtime"} in env
    refute Enum.any?(ConfigJson.app_env(%{}), fn {_a, k, _v} -> k == :master_token_factory end)
  end

  test "the native Meet live ASR provider and its settings come from the meetings section" do
    json = %{
      "meetings" => %{
        "live_asr" => %{"provider" => "Elixir.LiveAsr", "config" => %{"key" => "value"}}
      }
    }

    assert {:salix_meet_native, :live_asr,
            [provider: "Elixir.LiveAsr", config: %{"key" => "value"}]} in ConfigJson.app_env(json)

    refute Enum.any?(ConfigJson.app_env(%{}), fn {_a, k, _v} -> k == :live_asr end)
  end

  test "the anonymous guest token-factory maps the guest_factory section to :token_factory" do
    json = %{
      "meetings" => %{
        "guest_factory" => %{
          "url" => "https://token-factory.example.workers.dev/v1/handoff",
          "secret" => "guest-secret"
        }
      }
    }

    env = ConfigJson.app_env(json)

    assert {:salix_meet_native, :token_factory,
            [url: "https://token-factory.example.workers.dev/v1/handoff", secret: "guest-secret"]} in env

    refute Enum.any?(ConfigJson.app_env(%{}), fn {_a, k, _v} -> k == :token_factory end)
  end

  for {gate, config_key, env_key} <- [
        {"multi-scope registration", "multi_scope_registration_enabled",
         :agent_vmm_multi_scope_registration_enabled},
        {"Environment-scoped binding", "environment_scoped_bindings_enabled",
         :agent_vmm_environment_scoped_bindings_enabled}
      ] do
  end

  test "Agent VMM managed trust signer derives its public anchor and emits low-S signatures" do
    private_key = :binary.copy(<<1>>, 32)

    assert {:salix_store, :agent_vmm_managed_trust_signing, signing} =
             Enum.find(
               ConfigJson.app_env(%{
                 "agent_vmm" => %{
                   "managed_trust_signing" => %{
                     "private_key" => Base.encode64(private_key)
                   }
                 }
               }),
               &match?({:salix_store, :agent_vmm_managed_trust_signing, _}, &1)
             )

    payload = "managed membership"
    signature = signing.signer.(payload)

    assert signing.authority_prefix == "salix-managed"

    assert signing.key_id ==
             "p256:" <>
               Base.url_encode64(:crypto.hash(:sha256, signing.public_key), padding: false)

    assert signing.key_revision == 2
    assert byte_size(signing.public_key) == 33
    assert SalixStore.P256Signature.valid_low_s?(signature)
    assert SalixStore.P256Signature.verify(payload, signature, signing.public_key)

    refute Enum.any?(ConfigJson.app_env(%{}), fn {_app, key, _value} ->
             key == :agent_vmm_managed_trust_signing
           end)
  end

  test "the example config parses and maps cleanly" do
    example = Path.expand("../../../config/config.example.json", __DIR__)
    {:ok, json} = ConfigJson.load(example)
    env = ConfigJson.app_env(json)

    assert {:salix_store, :s3_conditional_delete, :native} in env
    assert {:salix_store, :s3_atomic_operations, :s3} in env
    assert {:salix_cluster, :strategy, "kubernetes_dns"} in env
    assert {:salix_analytics, :clickhouse_url, "http://clickhouse:8123"} in env
    assert {:salix_meet, :runtime_base_url, "http://meeting-runtime:8080"} in env
    assert config_entry?(env, :calendar_autojoin)

    assert {:salix_meet, :calendar_autojoin_channels,
            [
              %{
                "connect_id" => "replace-with-feishu-connect-id",
                "mode" => "notify",
                "chat_id" => "oc_replace_with_target_group",
                "calendars" => ["Your Team Calendar"],
                "create_calendar" => "Your Team Calendar",
                "mentions" => %{"mode" => "none", "users" => []}
              },
              %{
                "connect_id" => "replace-with-lark-connect-id",
                "mode" => "notify",
                "chat_id" => "oc_replace_with_target_lark_group",
                "calendars" => ["Your Team Calendar"],
                "create_calendar" => "Your Team Calendar",
                "mentions" => %{"mode" => "none", "users" => []}
              },
              %{
                "connect_id" => "replace-with-slack-connect-id",
                "channel" => "#your-channel",
                "calendars" => ["Your Team Calendar"]
              }
            ]} in env

    assert Map.has_key?(
             ConfigJson.get(json, ~w(bridge_for_teams dashboard)),
             "impersonator_org_slug"
           )

    assert ConfigJson.get(json, ~w(bridge_for_teams bft_cli artifact_base_url)) ==
             "https://release.example.com/bft-cli"

    refute Map.has_key?(ConfigJson.get(json, ~w(salix_dashboard)), "impersonator_org_slug")
  end

  # Absent means "not configured here"; an explicit {} means "nothing is
  # selectable". They must not collapse into the same no-op, or ops could never
  # revoke the last remaining judge model — the old allowlist would survive.
  test "an explicit empty judge_providers replaces the allowlist (revocation)" do
    env = ConfigJson.app_env(%{"trajectory_eval" => %{"judge_providers" => %{}}})

    assert {:salix_agent, :trajectory_eval_judge_providers, %{}} in env
  end

  test "station_task_watch maps the canary Groups and the thresholds it names" do
    env =
      ConfigJson.app_env(%{
        "station_task_watch" => %{
          "canary_group_ids" => ["grp1_canary", "", 7],
          "given_no_reply_ms" => 60_000,
          "idle_no_reply_ms" => 30_000
        }
      })

    assert {:salix_im, :station_task_watch,
            [
              given_no_reply_ms: 60_000,
              idle_no_reply_ms: 30_000,
              canary_group_ids: ["grp1_canary"]
            ]} in env

    # Absent or malformed: nothing is set, and the watch keeps its defaults.
    for json <- [%{}, %{"station_task_watch" => %{"canary_group_ids" => "grp1_canary"}}] do
      refute Enum.any?(ConfigJson.app_env(json), fn {app, key, _value} ->
               app == :salix_im and key == :station_task_watch
             end)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp config_entry?(env, key) do
    Enum.any?(env, fn {app, env_key, _value} -> app == :salix_meet and env_key == key end)
  end
end
