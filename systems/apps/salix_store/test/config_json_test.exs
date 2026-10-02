defmodule SalixStore.ConfigJsonTest do
  @moduledoc """
  The willow-style config.json loader: path resolution, parse, the
  config-only app-env mapping, coercions, forward compatibility.
  """
  use ExUnit.Case, async: false

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
    test "secret-backed profiles are selected independently and allow both Comma topics" do
      sandbox = %{
        "team_id" => "SANDBOXTEAM",
        "key_id" => "SANDBOXKEY",
        "private_key" => "test-only-pem",
        "allowed_bundle_ids" => ["surf.comma.ios", "surf.comma.ios.dev"]
      }

      production =
        Map.merge(sandbox, %{
          "team_id" => "PRODTEAM",
          "key_id" => "PRODKEY",
          "legacy_bundle_id" => "surf.comma.ios"
        })

      json = %{"comma" => %{"apns" => %{"sandbox" => sandbox, "production" => production}}}
      config = ConfigJson.apns_config(json)
      assert config[:profiles]["sandbox"][:key_id] == "SANDBOXKEY"
      assert config[:profiles]["production"][:key_id] == "PRODKEY"
      assert config[:profiles]["production"][:private_key] == "test-only-pem"
      assert config[:profiles]["sandbox"][:legacy_bundle_id] == nil
      assert config[:profiles]["production"][:legacy_bundle_id] == "surf.comma.ios"
      assert {:comma_core, :apns, config} in ConfigJson.app_env(json)
    end

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

    test "stays disabled only when the entire section is absent" do
      assert ConfigJson.synchronicity_env(%{}) == []
      assert ConfigJson.synchronicity_env(%{"comma" => %{}}) == []
    end

    test "fails closed for partial, malformed, or typoed integration config" do
      secret = String.duplicate("s", 32)

      invalid_sections = [
        %{},
        %{"base_url" => "https://sync.example.test"},
        %{"provisioning_secret" => secret},
        %{
          "base_url" => "https://sync.example.test",
          "provisioning_secret" => "too-short"
        },
        %{
          "base_url" => "http://sync.example.test",
          "provisioning_secret" => secret
        },
        %{
          "base_url" => "https://sync.example.test/internal",
          "provisioning_secret" => secret
        },
        %{
          "base_url" => "https://sync.example.test:not-a-port",
          "provisioning_secret" => secret
        },
        %{
          "base_url" => "https://sync.example.test",
          "provisioning_secret" => secret,
          "provisioning_secert" => secret
        },
        true,
        []
      ]

      for section <- invalid_sections do
        assert_raise ArgumentError, ~r/comma\.synchronicity/, fn ->
          ConfigJson.synchronicity_env(%{"comma" => %{"synchronicity" => section}})
        end
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

  test "sourced-context background executor is explicit and malformed config fails closed" do
    reconciler = BridgeForTeams.SlackHistoryOnboarding.Reconciler

    refute Enum.any?(
             ConfigJson.app_env(%{}),
             &match?({:bridge_for_teams_core, ^reconciler, _}, &1)
           )

    for enabled <- [true, false] do
      json = %{
        "bridge_for_teams" => %{
          "sourced_context" => %{
            "background_executor" => %{"enabled" => enabled}
          }
        }
      }

      assert {:bridge_for_teams_core, reconciler, [enabled: enabled]} in ConfigJson.app_env(json)

      assert ConfigJson.sourced_context_env(json) == [
               {:bridge_for_teams_core, reconciler, [enabled: enabled]}
             ]
    end

    for malformed <- [
          %{"enabled" => "true"},
          %{"enabled" => true, "interval_ms" => 1},
          %{},
          true,
          []
        ] do
      json = %{
        "bridge_for_teams" => %{
          "sourced_context" => %{"background_executor" => malformed}
        }
      }

      assert {:bridge_for_teams_core, reconciler, [enabled: false]} in ConfigJson.app_env(json)
    end
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

  test "absent values are omitted (defaults apply downstream)" do
    env = ConfigJson.app_env(%{})
    refute Enum.any?(env, fn {_a, k, _v} -> k == :s3_region end)
    refute Enum.any?(env, fn {_a, k, _v} -> k == :s3_endpoint end)
    refute Enum.any?(env, fn {_a, k, _v} -> k == :advertise_port end)
  end

  for {gate, config_key, env_key} <- [
        {"multi-scope registration", "multi_scope_registration_enabled",
         :agent_vmm_multi_scope_registration_enabled},
        {"Environment-scoped binding", "environment_scoped_bindings_enabled",
         :agent_vmm_environment_scoped_bindings_enabled}
      ] do
    test "Agent VMM #{gate} gate is explicit and defaults downstream" do
      for value <- [false, true] do
        assert {:salix_store, unquote(env_key), value} in ConfigJson.app_env(%{
                 "agent_vmm" => %{unquote(config_key) => value}
               })
      end

      refute Enum.any?(ConfigJson.app_env(%{}), fn {_app, key, _value} ->
               key == unquote(env_key)
             end)
    end
  end

  test "Agent VMM install material remains one server-owned catalog object" do
    catalog = %{
      "remote_enrollment" => %{"gateway_endpoint" => "vmm.example.test:7443"}
    }

    assert {:salix_store, :agent_vmm_install_material, catalog} in ConfigJson.app_env(%{
             "agent_vmm" => %{"install_material" => catalog}
           })

    refute Enum.any?(ConfigJson.app_env(%{}), fn {_app, key, _value} ->
             key == :agent_vmm_install_material
           end)
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

  test "Agent VMM managed trust signer configuration fails closed" do
    valid = %{
      "private_key" => Base.encode64(:binary.copy(<<1>>, 32))
    }

    for invalid <- [
          Map.delete(valid, "private_key"),
          Map.put(valid, "private_key", Base.encode64(<<1>>)),
          Map.put(valid, "extra", true)
        ] do
      assert_raise ArgumentError, fn ->
        ConfigJson.app_env(%{"agent_vmm" => %{"managed_trust_signing" => invalid}})
      end
    end
  end

  test "storage.timeouts maps present positive fields and fails closed on invalid values" do
    json = %{
      "storage" => %{
        "timeouts" => %{"fast_recv_ms" => 2_000, "budget_ms" => 9_000}
      }
    }

    env = ConfigJson.app_env(json)

    assert {:salix_store, :s3_timeouts, timeouts} =
             Enum.find(env, fn {app, key, _v} -> app == :salix_store and key == :s3_timeouts end)

    assert Keyword.get(timeouts, :fast_recv_ms) == 2_000
    assert Keyword.get(timeouts, :budget_ms) == 9_000
    refute Keyword.has_key?(timeouts, :bulk_recv_ms)

    # All three fields map through together.
    env =
      ConfigJson.app_env(%{
        "storage" => %{
          "timeouts" => %{"fast_recv_ms" => 1_000, "bulk_recv_ms" => 15_000, "budget_ms" => 8_000}
        }
      })

    assert {:salix_store, :s3_timeouts, timeouts} =
             Enum.find(env, fn {app, key, _v} -> app == :salix_store and key == :s3_timeouts end)

    assert Keyword.get(timeouts, :fast_recv_ms) == 1_000
    assert Keyword.get(timeouts, :bulk_recv_ms) == 15_000
    assert Keyword.get(timeouts, :budget_ms) == 8_000

    # Absent section (or an explicitly empty object) → entry omitted
    # entirely (adapter defaults apply).
    env = ConfigJson.app_env(%{"storage" => %{"bucket" => "b"}})
    refute Enum.any?(env, fn {_a, k, _v} -> k == :s3_timeouts end)

    env = ConfigJson.app_env(%{"storage" => %{"timeouts" => %{}}})
    refute Enum.any?(env, fn {_a, k, _v} -> k == :s3_timeouts end)

    # Null, zero, negative, non-integer, and over-ceiling leaves must fail
    # the load for EVERY field, not be silently ignored or accepted: a
    # mistyped incident-mitigation override is worse than a refused boot; a
    # null leaf silently booting with defaults was the original regression
    # this seam review caught; and BEAM timers reject huge integers at call
    # time — an over-ceiling value would crash every store request instead
    # of tuning it.
    for field <- ["fast_recv_ms", "bulk_recv_ms", "budget_ms"],
        invalid <- [nil, 0, -5, "fast", 1.5, 86_400_001, 99_999_999_999] do
      json = %{"storage" => %{"timeouts" => %{field => invalid}}}

      assert_raise ArgumentError, Regex.compile!("storage\\.timeouts\\.#{field}"), fn ->
        ConfigJson.app_env(json)
      end
    end

    # A section that is present but not an object — including an explicit
    # null — must also fail the load, never silently fall back to defaults.
    for malformed <- [nil, "300", 300, true, ["fast_recv_ms"]] do
      json = %{"storage" => %{"timeouts" => malformed}}

      assert_raise ArgumentError, ~r/storage\.timeouts must be an object/, fn ->
        ConfigJson.app_env(json)
      end
    end

    # An unknown field is a typo whose override would otherwise be silently
    # inert — the exact operational gap this seam exists to close.
    assert_raise ArgumentError, ~r/unknown fields \["fastrecv_ms"\]/, fn ->
      ConfigJson.app_env(%{"storage" => %{"timeouts" => %{"fastrecv_ms" => 1_000}}})
    end
  end

  test "native triage runtime is not controlled by config json" do
    legacy_sections = [
      %{},
      %{"im" => %{"native_triage_review" => %{}}},
      %{
        "im" => %{
          "native_triage_review" => %{
            "enabled" => false,
            "namespace" => "legacy-triage",
            "engine" => "review",
            "debounce_ms" => 5_000
          }
        }
      },
      %{"im" => %{"native_triage_review" => "malformed-legacy-value"}},
      %{
        "im" => %{
          "identity_scan_max_concurrency" => 7,
          "native_triage_review" => %{"engine" => "review"}
        }
      }
    ]

    for json <- legacy_sections do
      env = ConfigJson.app_env(json)

      refute Enum.any?(env, &match?({:salix_web, :native_triage_review_runtime, _}, &1))
      refute Enum.any?(env, &match?({:bridge_for_teams_core, :triage_namespace, _}, &1))
    end

    json = %{
      "im" => %{
        "identity_scan_max_concurrency" => 7,
        "native_triage_review" => %{"enabled" => false}
      }
    }

    assert ConfigJson.integer(json, ~w(im identity_scan_max_concurrency)) == 7
  end

  test "boolean is true, false, or nil when the path is absent" do
    assert ConfigJson.boolean(%{"slack_mirror" => %{"enabled" => true}}, ~w(slack_mirror enabled)) ==
             true

    assert ConfigJson.boolean(
             %{"slack_mirror" => %{"enabled" => false}},
             ~w(slack_mirror enabled)
           ) ==
             false

    assert ConfigJson.boolean(
             %{"slack_mirror" => %{"enabled" => "false"}},
             ~w(slack_mirror enabled)
           ) == false

    assert ConfigJson.boolean(%{}, ~w(slack_mirror enabled)) == nil
  end

  test "calendar autojoin is explicitly enabled and malformed bounds fail closed" do
    disabled = put_in(@json, ["meetings", "calendar_autojoin", "enabled"], false)
    missing_flag = update_in(@json, ["meetings", "calendar_autojoin"], &Map.delete(&1, "enabled"))
    missing_section = update_in(@json, ["meetings"], &Map.delete(&1, "calendar_autojoin"))
    missing_meetings = Map.delete(@json, "meetings")

    missing_channels =
      update_in(@json, ["meetings", "calendar_autojoin"], &Map.delete(&1, "channels"))

    missing_calendars =
      update_in(
        @json,
        ["meetings", "calendar_autojoin", "channels", "slack-abc123"],
        &Map.delete(&1, "calendars")
      )

    for json <- [
          disabled,
          missing_flag,
          missing_section,
          missing_meetings,
          missing_channels,
          missing_calendars
        ] do
      env = ConfigJson.app_env(json)
      refute config_entry?(env, :calendar_autojoin)
      refute config_entry?(env, :calendar_autojoin_channels)
    end

    for invalid_section <- [nil, true, "enabled", []] do
      json = put_in(@json, ["meetings", "calendar_autojoin"], invalid_section)
      env = ConfigJson.app_env(json)
      refute config_entry?(env, :calendar_autojoin)
      refute config_entry?(env, :calendar_autojoin_channels)
    end

    for {key, invalid} <- [
          {"scan_interval_ms", 0},
          {"join_interval_ms", -1},
          {"max_groups_per_pass", "many"},
          {"max_events_per_group", 0},
          {"max_concurrency", 1.5},
          {"task_timeout_ms", "forever"}
        ] do
      json = put_in(@json, ["meetings", "calendar_autojoin", key], invalid)
      env = ConfigJson.app_env(json)

      refute config_entry?(env, :calendar_autojoin),
             "expected malformed #{key}=#{inspect(invalid)} to disable calendar autojoin"

      refute config_entry?(env, :calendar_autojoin_channels)
    end
  end

  test "calendar preparation writes require an explicit boolean opt-in for the enrolled Slack target" do
    path = ["meetings", "calendar_autojoin", "channels", "slack-abc123", "calendar_writeback"]
    enabled = ConfigJson.app_env(put_in(@json, path, true))

    {:salix_meet, :calendar_autojoin_channels, entries} =
      Enum.find(enabled, &match?({:salix_meet, :calendar_autojoin_channels, _}, &1))

    assert Enum.find(entries, &(&1["connect_id"] == "slack-abc123"))["calendar_writeback"] == true

    for value <- [false, nil] do
      json = if is_nil(value), do: @json, else: put_in(@json, path, value)

      {:salix_meet, :calendar_autojoin_channels, entries} =
        Enum.find(
          ConfigJson.app_env(json),
          &match?({:salix_meet, :calendar_autojoin_channels, _}, &1)
        )

      refute Map.has_key?(
               Enum.find(entries, &(&1["connect_id"] == "slack-abc123")),
               "calendar_writeback"
             )
    end

    refute config_entry?(
             ConfigJson.app_env(put_in(@json, path, "true")),
             :calendar_autojoin_channels
           )
  end

  test "calendar autojoin accepts bound edges and rejects values outside every cap" do
    for {key, minimum, maximum} <- [
          {"scan_interval_ms", 10_000, 3_600_000},
          {"join_interval_ms", 30_000, 60_000},
          {"max_groups_per_pass", 1, 100},
          {"max_events_per_group", 1, 250},
          {"max_concurrency", 1, 16},
          {"task_timeout_ms", 1_000, 120_000}
        ] do
      for accepted <- [minimum, maximum] do
        env =
          @json
          |> put_in(["meetings", "calendar_autojoin", key], accepted)
          |> ConfigJson.app_env()

        assert config_entry?(env, :calendar_autojoin),
               "expected #{key}=#{accepted} at a bound edge to be accepted"

        assert config_entry?(env, :calendar_autojoin_channels)
      end

      for rejected <- [minimum - 1, maximum + 1] do
        env =
          @json
          |> put_in(["meetings", "calendar_autojoin", key], rejected)
          |> ConfigJson.app_env()

        refute config_entry?(env, :calendar_autojoin),
               "expected #{key}=#{rejected} outside its cap to fail closed"

        refute config_entry?(env, :calendar_autojoin_channels)
      end
    end
  end

  test "calendar autojoin enforces the group cap on channel count" do
    channels =
      for number <- 1..3, into: %{} do
        {"slack-#{number}", %{"channel" => "#chan-#{number}", "calendars" => ["Cal"]}}
      end

    ok_env =
      @json
      |> put_in(["meetings", "calendar_autojoin", "max_groups_per_pass"], 3)
      |> put_in(["meetings", "calendar_autojoin", "channels"], channels)
      |> ConfigJson.app_env()

    assert config_entry?(ok_env, :calendar_autojoin_channels)

    overflow_env =
      @json
      |> put_in(["meetings", "calendar_autojoin", "max_groups_per_pass"], 2)
      |> put_in(["meetings", "calendar_autojoin", "channels"], channels)
      |> ConfigJson.app_env()

    refute config_entry?(overflow_env, :calendar_autojoin)
    refute config_entry?(overflow_env, :calendar_autojoin_channels)
  end

  test "calendar autojoin fails closed above the selected-calendar work bound" do
    calendars = Enum.map(1..11, &"Calendar #{&1}")

    env =
      @json
      |> put_in(
        ["meetings", "calendar_autojoin", "channels"],
        %{"slack-overflow" => %{"channel" => "#botarena", "calendars" => calendars}}
      )
      |> ConfigJson.app_env()

    refute config_entry?(env, :calendar_autojoin)
    refute config_entry?(env, :calendar_autojoin_channels)
  end

  test "calendar service permits dashboard enrollments without deployment channel defaults" do
    env =
      @json |> put_in(["meetings", "calendar_autojoin", "channels"], %{}) |> ConfigJson.app_env()

    assert config_entry?(env, :calendar_autojoin)
    assert {:salix_meet, :calendar_autojoin_channels, []} in env
  end

  test "calendar autojoin fails closed without a configured meeting runtime" do
    no_runtime =
      @json
      |> put_in(["meetings", "runtime_url"], nil)
      |> update_in(["meetings"], &Map.delete(&1, "driver"))

    env = ConfigJson.app_env(no_runtime)
    refute config_entry?(env, :calendar_autojoin)
    refute config_entry?(env, :calendar_autojoin_channels)

    for invalid_url <- [123, "not-a-url", "ftp://meeting-runtime.example.test"] do
      invalid_env =
        no_runtime
        |> put_in(["meetings", "runtime_url"], invalid_url)
        |> ConfigJson.app_env()

      refute config_entry?(invalid_env, :calendar_autojoin)
      refute config_entry?(invalid_env, :calendar_autojoin_channels)
    end

    connector = put_in(no_runtime, ["meetings", "driver"], "connector")
    connector_env = ConfigJson.app_env(connector)
    assert config_entry?(connector_env, :calendar_autojoin)
    assert config_entry?(connector_env, :calendar_autojoin_channels)

    invalid_url_with_connector =
      connector
      |> put_in(["meetings", "runtime_url"], "not-a-url")
      |> ConfigJson.app_env()

    refute config_entry?(invalid_url_with_connector, :calendar_autojoin)
    refute config_entry?(invalid_url_with_connector, :calendar_autojoin_channels)
  end

  test "calendar autojoin rejects a task-wave budget that reaches the lease safety limit" do
    channels =
      for number <- 1..4, into: %{} do
        {"slack-#{number}", %{"channel" => "#chan-#{number}", "calendars" => ["Cal"]}}
      end

    base =
      @json
      |> put_in(["meetings", "calendar_autojoin", "max_groups_per_pass"], 4)
      |> put_in(["meetings", "calendar_autojoin", "max_concurrency"], 2)
      |> put_in(["meetings", "calendar_autojoin", "channels"], channels)

    below_budget =
      base
      |> put_in(["meetings", "calendar_autojoin", "task_timeout_ms"], 89_999)
      |> ConfigJson.app_env()

    assert config_entry?(below_budget, :calendar_autojoin)
    assert config_entry?(below_budget, :calendar_autojoin_channels)

    at_budget =
      base
      |> put_in(["meetings", "calendar_autojoin", "task_timeout_ms"], 90_000)
      |> ConfigJson.app_env()

    refute config_entry?(at_budget, :calendar_autojoin)
    refute config_entry?(at_budget, :calendar_autojoin_channels)
  end

  test "calendar autojoin fails closed when any target entry is malformed" do
    json =
      put_in(@json, ["meetings", "calendar_autojoin", "channels"], %{
        "slack-ok" => %{"channel" => "  #botarena  ", "calendars" => ["Comma Event", "  "]},
        "slack-no-channel" => %{"calendars" => ["Comma Event"]},
        "slack-empty-calendars" => %{"channel" => "#x", "calendars" => []},
        "slack-bad" => "not-a-map"
      })

    env = ConfigJson.app_env(json)

    refute config_entry?(env, :calendar_autojoin)
    refute config_entry?(env, :calendar_autojoin_channels)

    invalid_only =
      put_in(@json, ["meetings", "calendar_autojoin", "channels"], %{
        "slack-no-channel" => %{"calendars" => ["Comma Event"]},
        "slack-bad" => 1
      })

    invalid_env = ConfigJson.app_env(invalid_only)
    refute config_entry?(invalid_env, :calendar_autojoin)
    refute config_entry?(invalid_env, :calendar_autojoin_channels)
  end

  test "calendar autojoin accepts Feishu notify targets and preserves mention policy" do
    json =
      put_in(@json, ["meetings", "calendar_autojoin", "channels"], %{
        "feishu-connect" => %{
          "mode" => "notify",
          "chat_id" => "  oc_team  ",
          "calendars" => ["Comma Event", "Company"],
          "create_calendar" => "Comma Event",
          "mentions" => %{
            "mode" => "users",
            "users" => [
              %{"user_id" => " ou_alice ", "name" => " Alice "},
              %{"user_id" => "ou_bob", "name" => "Bob"}
            ]
          }
        }
      })

    assert {:salix_meet, :calendar_autojoin_channels,
            [
              %{
                "connect_id" => "feishu-connect",
                "mode" => "notify",
                "chat_id" => "oc_team",
                "calendars" => ["Comma Event", "Company"],
                "create_calendar" => "Comma Event",
                "mentions" => %{
                  "mode" => "users",
                  "users" => [
                    %{"user_id" => "ou_alice", "name" => "Alice"},
                    %{"user_id" => "ou_bob", "name" => "Bob"}
                  ]
                }
              }
            ]} in ConfigJson.app_env(json)
  end

  test "calendar autojoin rejects unsafe Feishu notification configuration" do
    base = %{
      "mode" => "notify",
      "chat_id" => "oc_team",
      "calendars" => ["Comma Event"],
      "create_calendar" => "Comma Event",
      "mentions" => %{"mode" => "none", "users" => []}
    }

    invalid = [
      Map.put(base, "mode", "join"),
      Map.put(base, "chat_id", ""),
      Map.put(base, "create_calendar", "Private"),
      Map.put(base, "mentions", %{"mode" => "users", "users" => []}),
      Map.put(base, "mentions", %{"mode" => "everyone"})
    ]

    for spec <- invalid do
      env =
        @json
        |> put_in(["meetings", "calendar_autojoin", "channels"], %{"feishu" => spec})
        |> ConfigJson.app_env()

      refute config_entry?(env, :calendar_autojoin)
      refute config_entry?(env, :calendar_autojoin_channels)
    end

    too_many_users =
      for index <- 1..51,
          do: %{"user_id" => "ou_#{index}", "name" => "User #{index}"}

    overflow = put_in(base, ["mentions"], %{"mode" => "users", "users" => too_many_users})

    overflow_env =
      @json
      |> put_in(["meetings", "calendar_autojoin", "channels"], %{"feishu" => overflow})
      |> ConfigJson.app_env()

    refute config_entry?(overflow_env, :calendar_autojoin)
  end

  test "unknown sections are ignored (forward compatibility)" do
    assert Map.has_key?(@json, "future_section")
    assert ConfigJson.app_env(@json) == ConfigJson.app_env(Map.delete(@json, "future_section"))
  end

  test "load/1: nil path is empty config; bad JSON and non-objects error" do
    assert {:ok, %{}} = ConfigJson.load(nil)

    tmp = Path.join(System.tmp_dir!(), "salix-cfg-#{System.unique_integer([:positive])}.json")
    File.write!(tmp, "[1,2]")
    assert {:error, {:not_an_object, [1, 2]}} = ConfigJson.load(tmp)
    File.write!(tmp, "{nope")
    assert {:error, %Jason.DecodeError{}} = ConfigJson.load(tmp)
    File.write!(tmp, ~s({"web": {"port": 4500}}))
    assert {:ok, %{"web" => %{"port" => 4500}}} = ConfigJson.load(tmp)
    File.rm!(tmp)
    assert {:error, :enoent} = ConfigJson.load(tmp)
  end

  test "resolve_path checks only the supplied/default file locations" do
    previous = System.get_env("SALIX_CONFIG_PATH")
    tmp = Path.join(System.tmp_dir!(), "salix-cfg-#{System.unique_integer([:positive])}.json")
    missing = tmp <> ".missing"

    File.write!(tmp, "{}")
    System.delete_env("SALIX_CONFIG_PATH")

    try do
      assert ConfigJson.resolve_path([missing, tmp]) == tmp
      assert ConfigJson.resolve_path([missing]) == nil
    after
      restore_env("SALIX_CONFIG_PATH", previous)
      File.rm(tmp)
    end
  end

  test "resolve_path honors an explicit SALIX_CONFIG_PATH" do
    previous = System.get_env("SALIX_CONFIG_PATH")

    explicit =
      Path.join(System.tmp_dir!(), "salix-cfg-#{System.unique_integer([:positive])}.json")

    fallback = explicit <> ".fallback"

    File.write!(fallback, "{}")
    System.put_env("SALIX_CONFIG_PATH", explicit)

    on_exit(fn ->
      restore_env("SALIX_CONFIG_PATH", previous)
      File.rm(fallback)
    end)

    assert ConfigJson.resolve_path([fallback]) == explicit
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

  test "trajectory_eval overrides emit only the keys present in config.json" do
    json = %{
      "trajectory_eval" => %{
        "judge_enabled" => true,
        "sample_rate" => 0.25
      }
    }

    env = ConfigJson.app_env(json)

    # A partial override — the missing keys (enabled, judge_clean_sample_rate)
    # are absent so Config's deep-merge keeps their compile-time defaults.
    assert {:salix_agent, :trajectory_eval, kw} =
             Enum.find(env, fn {app, key, _} ->
               app == :salix_agent and key == :trajectory_eval
             end)

    assert Enum.sort(kw) == [judge_enabled: true, sample_rate: 0.25]
    refute Keyword.has_key?(kw, :enabled)
    refute Keyword.has_key?(kw, :judge_clean_sample_rate)
  end

  test "trajectory_eval accepts string-typed numbers and booleans" do
    json = %{
      "trajectory_eval" => %{"judge_enabled" => "true", "judge_clean_sample_rate" => "0.1"}
    }

    env = ConfigJson.app_env(json)

    {:salix_agent, :trajectory_eval, kw} =
      Enum.find(env, fn {app, key, _} -> app == :salix_agent and key == :trajectory_eval end)

    assert kw[:judge_enabled] == true
    assert kw[:judge_clean_sample_rate] == 0.1
  end

  test "no trajectory_eval section emits no entry (compile-time defaults stand)" do
    env = ConfigJson.app_env(%{})
    refute Enum.any?(env, fn {app, key, _} -> app == :salix_agent and key == :trajectory_eval end)

    # An empty section is also a no-op rather than an override that clears keys.
    env2 = ConfigJson.app_env(%{"trajectory_eval" => %{}})

    refute Enum.any?(env2, fn {app, key, _} -> app == :salix_agent and key == :trajectory_eval end)
  end

  test "trajectory_eval judge_provider default and judge_providers allowlist map through" do
    providers = %{
      "luna" => %{
        "label" => "GPT-5.6 Luna",
        "protocol" => "chat_completions",
        "base_url" => "https://gw.example/v1",
        "model" => "luna-x",
        "api_key_env" => "SALIX_JUDGE_LUNA_KEY"
      }
    }

    json = %{
      "trajectory_eval" => %{"judge_provider" => "luna", "judge_providers" => providers}
    }

    env = ConfigJson.app_env(json)

    {:salix_agent, :trajectory_eval, kw} =
      Enum.find(env, fn {app, key, _} -> app == :salix_agent and key == :trajectory_eval end)

    assert kw[:judge_provider] == "luna"

    # The allowlist is a whole-map replace on its own app-env key (not merged
    # into the trajectory_eval keyword list).
    assert {:salix_agent, :trajectory_eval_judge_providers, ^providers} =
             Enum.find(env, fn {app, key, _} ->
               app == :salix_agent and key == :trajectory_eval_judge_providers
             end)
  end

  test "no judge_providers section emits no allowlist entry" do
    env = ConfigJson.app_env(%{"trajectory_eval" => %{"judge_enabled" => true}})

    refute Enum.any?(env, fn {app, key, _} ->
             app == :salix_agent and key == :trajectory_eval_judge_providers
           end)
  end

  # Absent means "not configured here"; an explicit {} means "nothing is
  # selectable". They must not collapse into the same no-op, or ops could never
  # revoke the last remaining judge model — the old allowlist would survive.
  test "an explicit empty judge_providers replaces the allowlist (revocation)" do
    env = ConfigJson.app_env(%{"trajectory_eval" => %{"judge_providers" => %{}}})

    assert {:salix_agent, :trajectory_eval_judge_providers, %{}} in env
  end

  # A present-but-malformed value must fail CLOSED to an empty allowlist.
  # Treating it as absent would preserve the compiled providers — an ops edit
  # that was trying to revoke them would silently leave them selectable.
  test "a malformed judge_providers value replaces the allowlist with empty" do
    for invalid <- [nil, "haiku", 42, ["revoked"]] do
      env = ConfigJson.app_env(%{"trajectory_eval" => %{"judge_providers" => invalid}})

      assert {:salix_agent, :trajectory_eval_judge_providers, %{}} in env,
             "expected malformed judge_providers=#{inspect(invalid)} to fail closed to %{}"
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp config_entry?(env, key) do
    Enum.any?(env, fn {app, env_key, _value} -> app == :salix_meet and env_key == key end)
  end

  test "meeting_join_rpc_timeout_ms stays strictly below every supported task budget" do
    # Default budget keeps the protocol-table ceiling.
    assert ConfigJson.meeting_join_rpc_timeout_ms(30_000) == 20_000
    # Large budgets stay at the ceiling.
    assert ConfigJson.meeting_join_rpc_timeout_ms(120_000) == 20_000
    # The reviewer-reproduced hole: a legal 10s budget must not be outlived.
    assert ConfigJson.meeting_join_rpc_timeout_ms(10_000) == 5_000
    # The smallest supported budget still leaves the RPC strictly inside it.
    assert ConfigJson.meeting_join_rpc_timeout_ms(1_000) == 500

    for budget <- [1_000, 2_500, 6_000, 10_000, 30_000, 120_000] do
      assert ConfigJson.meeting_join_rpc_timeout_ms(budget) < budget
    end
  end
end
