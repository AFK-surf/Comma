defmodule Comma.Accounts.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "production comma_product config fails closed without comma.database.url", %{
    tmp_dir: tmp_dir
  } do
    config_path = Path.join(tmp_dir, "config.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        billing: %{database: %{url: "ecto://unused:unused@localhost/unused"}}
      })
    )

    {output, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "-e",
          ~S|Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)|
        ],
        cd: Path.expand("../../../../..", __DIR__),
        env: [
          {"MIX_ENV", "test"},
          {"COMMA_SUBSYSTEMS", "comma_product"},
          {"REDIS_URL", "redis://127.0.0.1:6379/0"},
          {"SALIX_CONFIG_PATH", config_path}
        ],
        stderr_to_stdout: true
      )

    refute status == 0
    assert output =~ "comma.database.url is required for comma_product"
  end

  @tag :tmp_dir
  test "production and staging trust only their own product and Admin browser origins", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_runtime_config!(tmp_dir)

    {production_output, 0} =
      read_runtime_config(config_path,
        comma_environment: "production",
        expression:
          ~S|config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host); IO.puts("COMMA_ORIGINS=" <> Jason.encode!(get_in(config, [:comma_web, :allowed_origins]))); IO.puts("COMMA_WEB_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :web_cookie_origin])); IO.puts("COMMA_ADMIN_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :admin_cookie_origin]))|
      )

    assert production_output =~
             ~S|COMMA_ORIGINS=["https://app.comma.surf","https://admin.comma.surf"]|

    assert production_output =~ "COMMA_WEB_COOKIE_ORIGIN=https://app.comma.surf"
    assert production_output =~ "COMMA_ADMIN_COOKIE_ORIGIN=https://admin.comma.surf"
    refute production_output =~ "app-staging.comma.surf"
    refute production_output =~ "admin-staging.comma.surf"

    {staging_output, 0} =
      read_runtime_config(config_path,
        comma_environment: "staging",
        expression:
          ~S|config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host); IO.puts("COMMA_ORIGINS=" <> Jason.encode!(get_in(config, [:comma_web, :allowed_origins]))); IO.puts("COMMA_WEB_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :web_cookie_origin])); IO.puts("COMMA_ADMIN_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :admin_cookie_origin]))|
      )

    assert staging_output =~
             ~S|COMMA_ORIGINS=["https://app-staging.comma.surf","https://admin-staging.comma.surf"]|

    assert staging_output =~ "COMMA_WEB_COOKIE_ORIGIN=https://app-staging.comma.surf"
    assert staging_output =~ "COMMA_ADMIN_COOKIE_ORIGIN=https://admin-staging.comma.surf"
    refute staging_output =~ ~S|COMMA_ORIGINS=["https://app.comma.surf"]|
  end

  @tag :tmp_dir
  test "profile avatar uses local S3, staging GCS, and production rejects staging", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_runtime_config!(tmp_dir, %{comma: %{profile_avatar: nil}})

    expression = ~S'''
    avatar = get_in(Config.Reader.read!("config/runtime.exs", env: :prod, target: :host), [:comma_core, :profile_avatar])
    IO.puts("AVATAR_ADAPTER=" <> inspect(avatar[:adapter]))
    IO.puts("AVATAR_BUCKET=" <> inspect(avatar[:bucket]))
    IO.puts("AVATAR_ENDPOINT=" <> inspect(avatar[:endpoint]))
    IO.puts("AVATAR_CREDENTIALS=" <> inspect(is_binary(avatar[:access_key_id]) and is_binary(avatar[:secret_access_key])))
    '''

    {local_output, 0} =
      read_runtime_config(config_path,
        comma_environment: "local",
        expression: expression
      )

    assert local_output =~ "AVATAR_ADAPTER=Comma.ProfileAvatar.Storage.S3"
    assert local_output =~ ~s|AVATAR_BUCKET="comma-user-avatar-dev"|
    assert local_output =~ ~s|AVATAR_ENDPOINT="http://127.0.0.1:19000"|
    assert local_output =~ "AVATAR_CREDENTIALS=true"

    staging_bucket_path =
      write_runtime_config!(tmp_dir, %{
        comma: %{profile_avatar: %{bucket: "example-avatars-staging"}}
      })

    {staging_output, 0} =
      read_runtime_config(staging_bucket_path,
        comma_environment: "staging",
        expression: expression
      )

    assert staging_output =~ ~s|AVATAR_BUCKET="example-avatars-staging"|
    assert staging_output =~ "AVATAR_ADAPTER=Comma.ProfileAvatar.Storage.GCS"

    configured_path =
      write_runtime_config!(tmp_dir, %{comma: %{profile_avatar: %{bucket: "json-bucket"}}})

    {production_output, 0} =
      read_runtime_config(configured_path,
        comma_environment: "production",
        expression: expression,
        extra_env: [{"COMMA_PROFILE_AVATAR_BUCKET", "example-avatars-production"}]
      )

    assert production_output =~ ~s|AVATAR_BUCKET="example-avatars-production"|
    refute production_output =~ "json-bucket"

    {rejected_output, rejected_status} =
      read_runtime_config(staging_bucket_path, comma_environment: "production")

    refute rejected_status == 0
    assert rejected_output =~ "production Comma profile avatars cannot use"

    missing_path = write_runtime_config!(tmp_dir, %{comma: %{profile_avatar: %{bucket: ""}}})

    {missing_output, missing_status} =
      read_runtime_config(missing_path, comma_environment: "staging")

    refute missing_status == 0
    assert missing_output =~ "need comma.profile_avatar.bucket"

    example =
      Path.expand("../../../../../config/config.example.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    refute (get_in(example, ["comma", "profile_avatar", "bucket"]) || "") =~ ~r/staging/
  end

  @tag :tmp_dir
  test "operator identities come from the environment's configuration", %{tmp_dir: tmp_dir} do
    config_path =
      write_runtime_config!(tmp_dir, %{
        comma: %{
          admin: %{email_domain: "example.org"},
          email: %{support: "help@example.org"},
          billing: %{stripe_lookup_key_prefix: "example", account_prefix: "example-ba-"}
        }
      })

    {output, 0} =
      read_runtime_config(config_path,
        comma_environment: "staging",
        expression:
          ~S|config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)[:comma_core]; IO.puts("IDS=" <> Enum.map_join([:admin_email_domain, :support_email, :stripe_lookup_key_prefix, :billing_account_prefix], ",", &config[&1]))|
      )

    assert output =~ "IDS=example.org,help@example.org,example,example-ba-"
  end

  @tag :tmp_dir
  test "Android Google client IDs are trimmed and blank entries fail at boot", %{
    tmp_dir: tmp_dir
  } do
    config_path =
      write_runtime_config!(tmp_dir, %{
        comma: %{google_auth: %{android_client_ids: [" android.apps.example "]}}
      })

    {output, 0} =
      read_runtime_config(config_path,
        comma_environment: "staging",
        expression:
          ~S|ids = get_in(Config.Reader.read!("config/runtime.exs", env: :prod, target: :host), [:comma_core, :google_auth, :android_client_ids]); IO.puts("ANDROID_IDS=" <> inspect(ids))|
      )

    assert output =~ ~s|ANDROID_IDS=["android.apps.example"]|

    blank_path =
      write_runtime_config!(tmp_dir, %{comma: %{google_auth: %{android_client_ids: ["  "]}}})

    {blank_output, blank_status} =
      read_runtime_config(blank_path, comma_environment: "staging")

    refute blank_status == 0
    assert blank_output =~ "android_client_ids must contain nonempty strings"
  end

  @tag :tmp_dir
  test "unknown Comma environment names fail closed instead of inheriting local origins", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_runtime_config!(tmp_dir)
    {output, status} = read_runtime_config(config_path, comma_environment: "prod-eu")

    refute status == 0
    assert output =~ "COMMA_ENVIRONMENT must be one of"
    assert output =~ ~S|got: "prod-eu"|
  end

  @tag :tmp_dir
  test "online meeting replay is enabled only in deployed environments", %{tmp_dir: tmp_dir} do
    config_path = write_runtime_config!(tmp_dir)

    expression = ~S'''
    enabled = get_in(Config.Reader.read!("config/runtime.exs", env: :prod, target: :host), [:salix_web, :meeting_notes_online_replay_enabled])
    IO.puts("MEETING_REPLAY_ENABLED=" <> inspect(enabled))
    '''

    for comma_environment <- ["staging", "production", "prod"] do
      {output, 0} =
        read_runtime_config(config_path,
          comma_environment: comma_environment,
          expression: expression
        )

      assert output =~ "MEETING_REPLAY_ENABLED=true"
    end

    for comma_environment <- ["local", "development", "dev", "test"] do
      {output, 0} =
        read_runtime_config(config_path,
          comma_environment: comma_environment,
          expression: expression
        )

      assert output =~ "MEETING_REPLAY_ENABLED=false"
    end
  end

  @tag :tmp_dir
  test "Slack context onboarding dry run is enabled only in staging", %{tmp_dir: tmp_dir} do
    onboarding_config = %{
      bridge_for_teams: %{
        database: %{url: "ecto://unused:unused@localhost/unused"},
        dashboard: %{
          public_base_url: "https://teams-staging.example.test",
          secret_key_base: String.duplicate("runtime-secret-", 5),
          server: false
        },
        sourced_context: %{background_executor: %{enabled: true}}
      },
      salix: %{database: %{url: "ecto://unused:unused@localhost/unused"}},
      salix_dashboard: %{secret_key_base: String.duplicate("runtime-secret-", 5)},
      web: %{
        api_base_url: "https://salix-staging.example.test",
        api_token: String.duplicate("runtime-api-token-", 3)
      },
      llm: %{
        default_template: %{
          template_id: "comma-test",
          name: "Comma Test",
          model: "gpt-test",
          provider: "openai",
          max_tokens: 4_096,
          provider_config: %{
            protocol: "responses",
            base_url: "https://api.openai.invalid/v1",
            api_key: "test-key"
          }
        }
      },
      storage: %{
        endpoint: "http://127.0.0.1:9000",
        region: "us-east-1",
        bucket: "runtime-test",
        access_key_id: "test-access",
        secret_access_key: "test-secret",
        atomic_operations: "s3",
        conditional_delete: "emulate"
      }
    }

    config_path = write_runtime_config!(tmp_dir, onboarding_config)

    expression = ~S'''
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    features = get_in(config, [:bridge_for_teams_core, :sourced_context_features])
    Enum.each(features, fn {key, enabled?} -> IO.puts("SOURCED_CONTEXT_#{key}=#{enabled?}") end)
    IO.puts("SOURCED_CONTEXT_PROCESSOR=" <> inspect(get_in(config, [:bridge_for_teams_core, :sourced_context_processor])))
    processor_evidence = get_in(config, [:bridge_for_teams_core, :sourced_context_processor_evidence])
    evidence = get_in(config, [:bridge_for_teams_core, BridgeForTeams.SlackHistoryOnboarding.Reconciler, :derivation_evidence])
    executor_enabled = get_in(config, [:bridge_for_teams_core, BridgeForTeams.SlackHistoryOnboarding.Reconciler, :enabled])
    IO.puts("SOURCED_CONTEXT_EVIDENCE=" <> inspect(evidence))
    if evidence, do: IO.puts("SOURCED_CONTEXT_MODEL_REVISION=" <> evidence.model_revision)
    IO.puts("SOURCED_CONTEXT_EVIDENCE_MATCH=" <> inspect(processor_evidence == evidence))
    IO.puts("SOURCED_CONTEXT_EXECUTOR_ENABLED=" <> inspect(executor_enabled))
    '''

    {staging_output, 0} =
      read_runtime_config(config_path,
        comma_environment: "staging",
        subsystems: "salix,bridge_for_teams",
        expression: expression
      )

    for feature <- ~w(onboarding_preview discovery acquisition derivation) do
      assert staging_output =~ "SOURCED_CONTEXT_#{feature}=true"
    end

    for feature <- ~w(commit grounding knowledge_inspection) do
      assert staging_output =~ "SOURCED_CONTEXT_#{feature}=false"
    end

    assert staging_output =~
             "SOURCED_CONTEXT_PROCESSOR=Salix.Bindings.SourcedContextProcessor"

    assert staging_output =~ ~s|model_id: "gpt-test"|
    assert staging_output =~ ~s|prompt_revision: "bft-history-extraction-v1"|
    assert staging_output =~ ~s|processor_config: %{"max_output_tokens" => 4096|
    assert staging_output =~ "SOURCED_CONTEXT_EXECUTOR_ENABLED=true"
    assert staging_output =~ "SOURCED_CONTEXT_EVIDENCE_MATCH=true"

    rotated_config_path =
      onboarding_config
      |> put_in([:llm, :default_template, :provider_config, :api_key], "rotated-test-key")
      |> then(&write_runtime_config!(tmp_dir, &1))

    {rotated_output, 0} =
      read_runtime_config(rotated_config_path,
        comma_environment: "staging",
        subsystems: "salix,bridge_for_teams",
        expression: expression
      )

    assert [_, revision] =
             Regex.run(~r/SOURCED_CONTEXT_MODEL_REVISION=([^\s]+)/, staging_output)

    assert [_, ^revision] =
             Regex.run(~r/SOURCED_CONTEXT_MODEL_REVISION=([^\s]+)/, rotated_output)

    for comma_environment <- ["production", "prod"] do
      {production_output, 0} =
        read_runtime_config(config_path,
          comma_environment: comma_environment,
          subsystems: "salix,bridge_for_teams",
          expression: expression
        )

      for feature <-
            ~w(onboarding_preview discovery acquisition derivation commit grounding knowledge_inspection) do
        assert production_output =~ "SOURCED_CONTEXT_#{feature}=false"
      end

      assert production_output =~ "SOURCED_CONTEXT_PROCESSOR=nil"
      assert production_output =~ "SOURCED_CONTEXT_EVIDENCE=nil"
      assert production_output =~ "SOURCED_CONTEXT_EVIDENCE_MATCH=true"
    end
  end

  @tag :tmp_dir
  test "runtime browser security overrides fail closed", %{tmp_dir: tmp_dir} do
    invalid_origins_path =
      write_runtime_config!(tmp_dir, %{
        comma: %{web: %{allowed_origins: ["https://app.comma.surf/path"]}}
      })

    {origin_output, origin_status} =
      read_runtime_config(invalid_origins_path, comma_environment: "production")

    refute origin_status == 0
    assert origin_output =~ "comma.web.allowed_origins contains an invalid origin"

    secure_config_path = write_runtime_config!(tmp_dir)

    {cookie_output, cookie_status} =
      read_runtime_config(secure_config_path,
        comma_environment: "production",
        session_cookie_secure: "false"
      )

    refute cookie_status == 0

    assert cookie_output =~
             "COMMA_SESSION_COOKIE_SECURE=false is only allowed in an explicit local/dev/test environment"
  end

  @tag :tmp_dir
  test "runtime config requires distinct allowed product and Admin Cookie origins", %{
    tmp_dir: tmp_dir
  } do
    broader_allowlist_path =
      write_runtime_config!(tmp_dir, %{
        comma: %{
          web: %{
            allowed_origins: [
              "https://app.comma.surf",
              "https://preview.comma.surf",
              "https://admin.comma.surf"
            ],
            web_cookie_origin: "https://preview.comma.surf"
          }
        }
      })

    {broader_output, 0} =
      read_runtime_config(broader_allowlist_path,
        comma_environment: "production",
        expression:
          ~S|config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host); IO.puts("COMMA_ORIGINS=" <> Jason.encode!(get_in(config, [:comma_web, :allowed_origins]))); IO.puts("COMMA_WEB_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :web_cookie_origin])); IO.puts("COMMA_ADMIN_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :admin_cookie_origin]))|
      )

    assert broader_output =~
             ~S|COMMA_ORIGINS=["https://app.comma.surf","https://preview.comma.surf","https://admin.comma.surf"]|

    assert broader_output =~ "COMMA_WEB_COOKIE_ORIGIN=https://preview.comma.surf"
    assert broader_output =~ "COMMA_ADMIN_COOKIE_ORIGIN=https://admin.comma.surf"

    invalid_values = [
      {%{comma: %{web: %{web_cookie_origin: ["https://app.comma.surf"]}}},
       "comma.web.web_cookie_origin must be exactly one origin string"},
      {%{comma: %{web: %{web_cookie_origin: "https://preview.comma.surf"}}},
       "comma.web.web_cookie_origin must appear exactly once in comma.web.allowed_origins"},
      {%{comma: %{web: %{web_cookie_origin: "https://app.comma.surf/path"}}},
       "comma.web.web_cookie_origin contains an invalid origin"},
      {%{comma: %{web: %{admin_cookie_origin: ["https://admin.comma.surf"]}}},
       "comma.web.admin_cookie_origin must be exactly one origin string"},
      {%{comma: %{web: %{admin_cookie_origin: "https://preview.comma.surf"}}},
       "comma.web.admin_cookie_origin must appear exactly once in comma.web.allowed_origins"},
      {%{comma: %{web: %{admin_cookie_origin: "https://admin.comma.surf/path"}}},
       "comma.web.admin_cookie_origin contains an invalid origin"},
      {%{comma: %{web: %{admin_cookie_origin: "https://app.comma.surf"}}},
       "comma.web.admin_cookie_origin must differ from comma.web.web_cookie_origin"}
    ]

    for {override, expected_error} <- invalid_values do
      config_path = write_runtime_config!(tmp_dir, override)
      {output, status} = read_runtime_config(config_path, comma_environment: "production")

      refute status == 0
      assert output =~ expected_error
    end

    local_path = write_runtime_config!(tmp_dir)

    {local_output, 0} =
      read_runtime_config(local_path,
        comma_environment: "local",
        expression:
          ~S|config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host); IO.puts("COMMA_WEB_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :web_cookie_origin])); IO.puts("COMMA_ADMIN_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :admin_cookie_origin]))|
      )

    assert local_output =~ "COMMA_WEB_COOKIE_ORIGIN=http://127.0.0.1:5174"
    assert local_output =~ "COMMA_ADMIN_COOKIE_ORIGIN=http://127.0.0.1:4175"
  end

  @tag :tmp_dir
  test "production email auth requires every secret and provider dependency", %{tmp_dir: tmp_dir} do
    missing_values = [
      {%{comma: %{auth: %{secret: nil}}}, "comma.auth.secret"},
      {%{comma: %{auth: %{rate_limit_secret: nil}}}, "comma.auth.rate_limit_secret"},
      {%{comma: %{auth: %{redis_url: nil}}}, "comma.auth.redis_url"},
      {%{comma: %{email: %{from: nil}}}, "comma.email.from"},
      {%{email: %{postmark_server_token: nil}}, "email.postmark_server_token"}
    ]

    for {override, expected_path} <- missing_values do
      config_path = write_runtime_config!(tmp_dir, override)
      {output, status} = read_runtime_config(config_path, comma_environment: "production")

      refute status == 0
      assert output =~ "#{expected_path} is required for production Comma email authentication"
    end
  end

  @tag :tmp_dir
  test "production email auth forces Redis and Postmark without code exposure", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_runtime_config!(tmp_dir)

    expression = ~S'''
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    auth = get_in(config, [:comma_core, :auth])
    mail = get_in(config, [:comma_core, :mail])
    IO.puts("AUTH_STORE=" <> inspect(auth[:challenge_store]))
    IO.puts("AUTH_DELIVERY=" <> inspect(auth[:email_delivery]))
    IO.puts("AUTH_EXPOSE=" <> inspect(auth[:expose_codes]))
    IO.puts("AUTH_SECRETS_DISTINCT=" <> inspect(auth[:secret] != auth[:rate_limit_secret]))
    IO.puts("MAIL_FROM=" <> mail[:from])
    IO.puts("POSTMARK_CONFIGURED=" <> inspect(is_binary(get_in(config, [:salix_store, :postmark_server_token]))))
    '''

    {output, 0} =
      read_runtime_config(config_path,
        comma_environment: "production",
        expression: expression
      )

    assert output =~ "AUTH_STORE=Comma.AuthChallengeStore.Redis"
    assert output =~ "AUTH_DELIVERY=Comma.EmailDelivery.Postmark"
    assert output =~ "AUTH_EXPOSE=false"
    assert output =~ "AUTH_SECRETS_DISTINCT=true"
    assert output =~ "MAIL_FROM=login@comma.test"
    assert output =~ "POSTMARK_CONFIGURED=true"
    refute output =~ "runtime-otp-secret"
    refute output =~ "runtime-rate-limit-secret"
    refute output =~ "runtime-postmark-token"
  end

  test "local release uses Redis and Mailpit SMTP without exposing codes" do
    config_path =
      Path.expand(
        "../../../../../config/compose-dev.json",
        __DIR__
      )

    expression = ~S'''
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    auth = get_in(config, [:comma_core, :auth])
    IO.puts("AUTH_STORE=" <> inspect(auth[:challenge_store]))
    IO.puts("AUTH_DELIVERY=" <> inspect(auth[:email_delivery]))
    IO.puts("AUTH_EXPOSE=" <> inspect(auth[:expose_codes]))
    IO.puts("AUTH_SECRETS_DISTINCT=" <> inspect(auth[:secret] != auth[:rate_limit_secret]))
    postmark_configured = is_binary(get_in(config, [:salix_store, :postmark_server_token]))
    IO.puts("POSTMARK_CONFIGURED=" <> inspect(postmark_configured))
    '''

    {output, 0} =
      read_runtime_config(config_path, comma_environment: "local", expression: expression)

    assert output =~ "AUTH_STORE=Comma.AuthChallengeStore.Redis"
    assert output =~ "AUTH_DELIVERY=Comma.EmailDelivery.SMTP"
    assert output =~ "AUTH_EXPOSE=false"
    assert output =~ "AUTH_SECRETS_DISTINCT=true"
    assert output =~ "POSTMARK_CONFIGURED=false"
    refute output =~ "comma-local-auth-secret"
    refute output =~ "comma-local-rate-limit-secret"
  end

  @tag :tmp_dir
  test "test runtime preserves the test-only auth adapters", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.json")
    File.write!(config_path, "{}")

    expression = ~S'''
    auth = Application.fetch_env!(:comma_core, :auth)
    IO.puts("AUTH_STORE=" <> inspect(auth[:challenge_store]))
    IO.puts("AUTH_DELIVERY=" <> inspect(auth[:email_delivery]))
    IO.puts("AUTH_EXPOSE=" <> inspect(auth[:expose_codes]))
    '''

    {output, 0} =
      read_runtime_config(config_path, comma_environment: "test", expression: expression)

    assert output =~ "AUTH_STORE=Comma.AuthChallengeStore.Memory"
    assert output =~ "AUTH_DELIVERY=Comma.EmailDelivery.Logger"
    assert output =~ "AUTH_EXPOSE=true"
  end

  @tag :tmp_dir
  test "production rejects weak, reused, or malformed auth configuration", %{tmp_dir: tmp_dir} do
    shared_secret = String.duplicate("s", 32)

    invalid_values = [
      {%{comma: %{auth: %{secret: " \t\n "}}},
       "comma.auth.secret is required for production Comma email authentication"},
      {%{comma: %{auth: %{secret: "too-short"}}},
       "comma.auth secrets must each contain at least 32 bytes"},
      {%{comma: %{auth: %{secret: "  " <> String.duplicate("s", 30) <> "  "}}},
       "comma.auth secrets must each contain at least 32 bytes"},
      {%{comma: %{auth: %{secret: shared_secret, rate_limit_secret: shared_secret}}},
       "comma.auth.secret and comma.auth.rate_limit_secret must be different"},
      {%{
         comma: %{
           auth: %{
             secret: " #{shared_secret}",
             rate_limit_secret: "#{shared_secret}\t"
           }
         }
       }, "comma.auth.secret and comma.auth.rate_limit_secret must be different"},
      {%{comma: %{auth: %{redis_url: "https://redis.example.com"}}},
       "comma.auth.redis_url must be an absolute redis:// or rediss:// URL"}
    ]

    for {override, expected_error} <- invalid_values do
      config_path = write_runtime_config!(tmp_dir, override)
      {output, status} = read_runtime_config(config_path, comma_environment: "production")

      refute status == 0
      assert output =~ expected_error
    end
  end

  @tag :tmp_dir
  test "production trims auth secrets before storing them", %{tmp_dir: tmp_dir} do
    secret = String.duplicate("s", 32)
    rate_limit_secret = String.duplicate("r", 32)

    config_path =
      write_runtime_config!(tmp_dir, %{
        comma: %{
          auth: %{
            secret: " \t#{secret}\n",
            rate_limit_secret: "\n#{rate_limit_secret} "
          }
        }
      })

    expression = ~S'''
    auth = get_in(Config.Reader.read!("config/runtime.exs", env: :prod, target: :host), [:comma_core, :auth])
    IO.puts("AUTH_SECRET_TRIMMED=" <> inspect(auth[:secret] == String.duplicate("s", 32)))
    IO.puts("AUTH_RATE_LIMIT_SECRET_TRIMMED=" <> inspect(auth[:rate_limit_secret] == String.duplicate("r", 32)))
    '''

    {output, 0} =
      read_runtime_config(config_path,
        comma_environment: "production",
        expression: expression
      )

    assert output =~ "AUTH_SECRET_TRIMMED=true"
    assert output =~ "AUTH_RATE_LIMIT_SECRET_TRIMMED=true"
  end

  @tag :tmp_dir
  test "enabling the OAuth IdP rejects non-production-safe issuers at boot", %{tmp_dir: tmp_dir} do
    config_path = write_runtime_config!(tmp_dir)

    probe = fn comma_environment, issuer ->
      read_runtime_config(config_path,
        comma_environment: comma_environment,
        extra_env: [
          {"COMMA_OAUTH_IDP_ENABLED", "true"},
          {"COMMA_OAUTH_IDP_ISSUER", issuer}
        ]
      )
    end

    # OIDC Discovery §3: the issuer (and every URL derived from it) must
    # be HTTPS outside explicit local/dev/test environments.
    {http_output, http_status} = probe.("production", "http://idp.example.com")
    refute http_status == 0
    assert http_output =~ "must be a bare https origin"

    # URI userinfo is rejected in every environment.
    {userinfo_output, userinfo_status} =
      probe.("production", "https://alice:secret@idp.example.com")

    refute userinfo_status == 0
    assert userinfo_output =~ "without credentials"

    # A bare https origin boots; http stays available for local dev.
    assert {_output, 0} = probe.("production", "https://idp.example.com")
    assert {_output, 0} = probe.("dev", "http://127.0.0.1:4200")
  end

  @tag :tmp_dir
  test "Comma Telegram is explicit, validates its public origin, and makes OIDC optional", %{
    tmp_dir: tmp_dir
  } do
    config_path = write_runtime_config!(tmp_dir)

    expression = ~S'''
    telegram = get_in(Config.Reader.read!("config/runtime.exs", env: :prod, target: :host), [:comma_web, :telegram])
    IO.puts("TELEGRAM_ENABLED=" <> inspect(telegram[:enabled]))
    IO.puts("TELEGRAM_BOT=" <> inspect(telegram[:bot_username]))
    IO.puts("TELEGRAM_OIDC=" <> inspect(telegram[:oidc_enabled]))
    IO.puts("TELEGRAM_API_BASE=" <> inspect(telegram[:api_base_url]))
    IO.puts("SALIX_TELEGRAM_API_BASE=" <> inspect(Application.get_env(:salix_im, :telegram_api_base_url)))
    '''

    required = [
      {"COMMA_TELEGRAM_ENABLED", "true"},
      {"COMMA_TELEGRAM_BOT_TOKEN", "bot-token"},
      {"COMMA_TELEGRAM_BOT_USERNAME", "@CommaProductBot"},
      {"COMMA_TELEGRAM_PUBLIC_BASE_URL", "https://api.comma.test"},
      {"COMMA_TELEGRAM_WEBHOOK_SECRET", String.duplicate("s", 32)},
      {"COMMA_TELEGRAM_API_BASE_URL", nil}
    ]

    {fallback_output, 0} =
      read_runtime_config(config_path,
        comma_environment: "production",
        expression: expression,
        extra_env:
          required ++
            [{"COMMA_TELEGRAM_CLIENT_ID", nil}, {"COMMA_TELEGRAM_CLIENT_SECRET", nil}]
      )

    assert fallback_output =~ "TELEGRAM_ENABLED=true"
    assert fallback_output =~ ~s|TELEGRAM_BOT="CommaProductBot"|
    assert fallback_output =~ "TELEGRAM_OIDC=false"
    assert fallback_output =~ ~s|TELEGRAM_API_BASE="https://api.telegram.org"|
    assert fallback_output =~ ~s|SALIX_TELEGRAM_API_BASE="https://api.telegram.org"|

    {oidc_output, 0} =
      read_runtime_config(config_path,
        comma_environment: "production",
        expression: expression,
        extra_env:
          required ++
            [
              {"COMMA_TELEGRAM_CLIENT_ID", "telegram-client"},
              {"COMMA_TELEGRAM_CLIENT_SECRET", "telegram-secret"}
            ]
      )

    assert oidc_output =~ "TELEGRAM_OIDC=true"

    {http_output, http_status} =
      read_runtime_config(config_path,
        comma_environment: "production",
        extra_env:
          Enum.map(required, fn
            {"COMMA_TELEGRAM_PUBLIC_BASE_URL", _value} ->
              {"COMMA_TELEGRAM_PUBLIC_BASE_URL", "http://api.comma.test"}

            entry ->
              entry
          end) ++ [{"COMMA_TELEGRAM_CLIENT_ID", nil}, {"COMMA_TELEGRAM_CLIENT_SECRET", nil}]
      )

    refute http_status == 0
    assert http_output =~ "COMMA_TELEGRAM_PUBLIC_BASE_URL must be a bare https origin"

    local_required =
      Enum.map(required, fn
        {"COMMA_TELEGRAM_PUBLIC_BASE_URL", _value} ->
          {"COMMA_TELEGRAM_PUBLIC_BASE_URL", "http://127.0.0.1:4200"}

        {"COMMA_TELEGRAM_API_BASE_URL", _value} ->
          {"COMMA_TELEGRAM_API_BASE_URL", "http://telegram-mock:43124"}

        entry ->
          entry
      end)

    {local_output, 0} =
      read_runtime_config(config_path,
        comma_environment: "local",
        expression: expression,
        extra_env:
          local_required ++
            [{"COMMA_TELEGRAM_CLIENT_ID", nil}, {"COMMA_TELEGRAM_CLIENT_SECRET", nil}]
      )

    assert local_output =~ ~s|TELEGRAM_API_BASE="http://telegram-mock:43124"|
    assert local_output =~ ~s|SALIX_TELEGRAM_API_BASE="http://telegram-mock:43124"|

    {remote_override_output, remote_override_status} =
      read_runtime_config(config_path,
        comma_environment: "production",
        extra_env:
          Enum.map(required, fn
            {"COMMA_TELEGRAM_API_BASE_URL", _value} ->
              {"COMMA_TELEGRAM_API_BASE_URL", "https://telegram-proxy.example.test"}

            entry ->
              entry
          end) ++ [{"COMMA_TELEGRAM_CLIENT_ID", nil}, {"COMMA_TELEGRAM_CLIENT_SECRET", nil}]
      )

    refute remote_override_status == 0

    assert remote_override_output =~
             "COMMA_TELEGRAM_API_BASE_URL is only supported in local environments"

    {invalid_local_output, invalid_local_status} =
      read_runtime_config(config_path,
        comma_environment: "local",
        extra_env:
          Enum.map(local_required, fn
            {"COMMA_TELEGRAM_API_BASE_URL", _value} ->
              {"COMMA_TELEGRAM_API_BASE_URL", "http://telegram-mock:43124/bot"}

            entry ->
              entry
          end) ++ [{"COMMA_TELEGRAM_CLIENT_ID", nil}, {"COMMA_TELEGRAM_CLIENT_SECRET", nil}]
      )

    refute invalid_local_status == 0

    assert invalid_local_output =~
             "COMMA_TELEGRAM_API_BASE_URL must be a bare http/https origin in local environments"
  end

  @tag :tmp_dir
  test "Synchronicity provisioning reads config.json and ignores the removed SYNC env vars", %{
    tmp_dir: tmp_dir
  } do
    secret = String.duplicate("json-secret-", 4)

    configured_path =
      write_runtime_config!(tmp_dir, %{
        comma: %{
          synchronicity: %{
            base_url: "https://sync.example.test/",
            provisioning_secret: secret
          }
        }
      })

    expression = ~S'''
    sync = get_in(Config.Reader.read!("config/runtime.exs", env: :prod, target: :host), [:comma_core, :synchronicity])
    IO.puts("SYNCHRONICITY=" <> inspect(sync))
    '''

    legacy_env = [
      {"SYNC_BASE_URL", "https://ignored.example.test"},
      {"SYNC_PROVISIONING_SECRET", String.duplicate("ignored-secret-", 3)}
    ]

    {configured_output, 0} =
      read_runtime_config(configured_path,
        comma_environment: "dev",
        expression: expression,
        extra_env: legacy_env
      )

    assert configured_output =~ ~s|base_url: "https://sync.example.test"|
    assert configured_output =~ ~s|provisioning_secret: "#{secret}"|
    refute configured_output =~ "ignored.example.test"

    absent_path = write_runtime_config!(tmp_dir)

    {absent_output, 0} =
      read_runtime_config(absent_path,
        comma_environment: "dev",
        expression: expression,
        extra_env: legacy_env
      )

    assert absent_output =~ "SYNCHRONICITY=nil"
  end

  @tag :tmp_dir
  test "semantic search follows the deployment environment rather than a JSON switch", %{
    tmp_dir: tmp_dir
  } do
    base = %{
      salix: %{database: %{url: "ecto://unused:unused@localhost/unused"}},
      storage: %{
        endpoint: "http://localhost:9000",
        bucket: "test",
        access_key_id: "test",
        secret_access_key: "test"
      },
      web: %{api_token: "test"},
      salix_dashboard: %{secret_key_base: String.duplicate("test", 16)},
      clickhouse: %{url: "http://localhost:8123", table: "test.events"}
    }

    expression = ~S'''
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    semantic = get_in(config, [:salix_analytics, :slack_semantic_search])
    Application.put_env(:salix_analytics, :slack_semantic_search, semantic)
    IO.puts("SEMANTIC_CHILDREN=" <> to_string(SalixAnalytics.SlackSemanticIndex.children() != []))
    IO.puts("MANUAL_SWITCH=" <> to_string(Keyword.has_key?(semantic, :enabled)))
    '''

    for {environment, legacy, starts?} <- [
          {"staging", nil, true},
          {"staging", %{enabled: false}, true},
          {"local", %{}, true},
          {"development", %{}, true},
          {"dev", %{}, true},
          {"test", %{}, true},
          {"prod", %{enabled: true}, false},
          {"production", %{enabled: true}, false}
        ] do
      input = if is_nil(legacy), do: base, else: Map.put(base, :slack_semantic_search, legacy)
      path = write_runtime_config!(tmp_dir, input)

      {output, 0} =
        read_runtime_config(path,
          comma_environment: environment,
          subsystems: "salix",
          expression: expression
        )

      assert output =~ "SEMANTIC_CHILDREN=#{starts?}"
      assert output =~ "MANUAL_SWITCH=false"
    end
  end

  @tag :tmp_dir
  test "production SMTP works without Postmark and retains cookie and code protections", %{
    tmp_dir: tmp_dir
  } do
    path =
      write_runtime_config!(tmp_dir, %{
        email: %{postmark_server_token: nil},
        comma: %{
          email: %{provider: "smtp", smtp: %{host: "smtp.example.com", port: 587, tls: "always"}}
        }
      })

    {output, status} =
      read_runtime_config(path,
        comma_environment: "production",
        expression:
          ~S|config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host); auth = get_in(config, [:comma_core, :auth]); IO.inspect({auth[:email_delivery], auth[:expose_codes], get_in(config, [:comma_core, :mail])[:tls]})|
      )

    assert status == 0, output
    assert output =~ "{Comma.EmailDelivery.SMTP, false, :always}"
  end

  @tag :tmp_dir
  test "selfhost HTTP cookies reject non-loopback origins", %{tmp_dir: tmp_dir} do
    path = write_runtime_config!(tmp_dir)

    {output, status} =
      read_runtime_config(path,
        comma_environment: "selfhost",
        session_cookie_secure: "false",
        extra_env: [{"COMMA_PUBLIC_URL", "http://public.example.com"}]
      )

    refute status == 0
    assert output =~ "Use HTTPS for remote access"
  end

  defp write_runtime_config!(tmp_dir, extra \\ %{}) do
    path = Path.join(tmp_dir, "config-#{System.unique_integer([:positive])}.json")

    base = %{
      billing: %{database: %{url: "ecto://unused:unused@localhost/unused"}},
      email: %{postmark_server_token: "runtime-postmark-token"},
      comma: %{
        database: %{url: "ecto://unused:unused@localhost/unused"},
        auth: %{
          secret: "runtime-otp-secret-0000000000000000",
          rate_limit_secret: "runtime-rate-limit-secret-0000000000",
          redis_url: "redis://127.0.0.1:6379/0"
        },
        email: %{from: "login@comma.test"},
        profile_avatar: %{bucket: "example-avatars-test"}
      }
    }

    File.write!(path, Jason.encode!(deep_merge(base, extra)))
    path
  end

  defp read_runtime_config(config_path, opts) do
    expression =
      Keyword.get(
        opts,
        :expression,
        ~S|Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)|
      )

    env =
      Keyword.get(opts, :extra_env, []) ++
        [
          {"MIX_ENV", "test"},
          {"COMMA_SUBSYSTEMS", Keyword.get(opts, :subsystems, "comma_product")},
          {"COMMA_ENVIRONMENT", Keyword.fetch!(opts, :comma_environment)},
          {"REDIS_URL", "redis://127.0.0.1:6379/0"},
          {"SALIX_CONFIG_PATH", config_path}
        ]

    env =
      case Keyword.get(opts, :session_cookie_secure) do
        nil -> env
        value -> [{"COMMA_SESSION_COOKIE_SECURE", value} | env]
      end

    System.cmd(
      "mix",
      ["run", "--no-start", "-e", expression],
      cd: Path.expand("../../../../..", __DIR__),
      env: env,
      stderr_to_stdout: true
    )
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
  end
end
