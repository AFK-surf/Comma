defmodule Comma.Accounts.RuntimeConfigTest do
  # Every case reads config/runtime.exs as production would. Booting `mix run`
  # costs seconds, so setup_all evaluates all cases in one child VM, applying
  # each case's environment in turn, and the tests assert on its results.
  use SystemsClock.Case, async: false

  @read_config ~S|config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)|

  @origins_expression @read_config <>
                        ~S|; IO.puts("COMMA_ORIGINS=" <> Jason.encode!(get_in(config, [:comma_web, :allowed_origins]))); IO.puts("COMMA_WEB_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :web_cookie_origin])); IO.puts("COMMA_ADMIN_COOKIE_ORIGIN=" <> get_in(config, [:comma_web, :admin_cookie_origin]))|

  @avatar_expression ~S'''
  avatar = get_in(Config.Reader.read!("config/runtime.exs", env: :prod, target: :host), [:comma_core, :profile_avatar])
  IO.puts("AVATAR_BUCKET=" <> inspect(avatar[:bucket]))
  '''

  @email_expression ~S'''
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

  @trim_expression ~S'''
  auth = get_in(Config.Reader.read!("config/runtime.exs", env: :prod, target: :host), [:comma_core, :auth])
  IO.puts("AUTH_SECRET_TRIMMED=" <> inspect(auth[:secret] == String.duplicate("s", 32)))
  IO.puts("AUTH_RATE_LIMIT_SECRET_TRIMMED=" <> inspect(auth[:rate_limit_secret] == String.duplicate("r", 32)))
  '''

  @telegram_expression ~S'''
  telegram = get_in(Config.Reader.read!("config/runtime.exs", env: :prod, target: :host), [:comma_web, :telegram])
  IO.puts("TELEGRAM_ENABLED=" <> inspect(telegram[:enabled]))
  IO.puts("TELEGRAM_BOT=" <> inspect(telegram[:bot_username]))
  IO.puts("TELEGRAM_OIDC=" <> inspect(telegram[:oidc_enabled]))
  IO.puts("TELEGRAM_API_BASE=" <> inspect(telegram[:api_base_url]))
  '''

  @telegram_env [
    {"COMMA_TELEGRAM_ENABLED", "true"},
    {"COMMA_TELEGRAM_BOT_TOKEN", "bot-token"},
    {"COMMA_TELEGRAM_BOT_USERNAME", "@CommaProductBot"},
    {"COMMA_TELEGRAM_PUBLIC_BASE_URL", "https://api.comma.test"},
    {"COMMA_TELEGRAM_WEBHOOK_SECRET", String.duplicate("s", 32)},
    {"COMMA_TELEGRAM_API_BASE_URL", nil},
    {"COMMA_TELEGRAM_CLIENT_ID", nil},
    {"COMMA_TELEGRAM_CLIENT_SECRET", nil}
  ]

  @invalid_cookie_origins [
    {%{comma: %{web: %{web_cookie_origin: ["https://app.comma.surf"]}}},
     "comma.web.web_cookie_origin must be exactly one origin string"},
    {%{comma: %{web: %{web_cookie_origin: "https://preview.comma.surf"}}},
     "comma.web.web_cookie_origin must appear exactly once in comma.web.allowed_origins"},
    {%{comma: %{web: %{admin_cookie_origin: "https://admin.comma.surf/path"}}},
     "comma.web.admin_cookie_origin contains an invalid origin"},
    {%{comma: %{web: %{admin_cookie_origin: "https://app.comma.surf"}}},
     "comma.web.admin_cookie_origin must differ from comma.web.web_cookie_origin"}
  ]

  @missing_email_auth [
    {%{comma: %{auth: %{secret: nil}}}, "comma.auth.secret"},
    {%{email: %{postmark_server_token: nil}}, "email.postmark_server_token"}
  ]

  @weak_auth [
    {%{comma: %{auth: %{secret: "  " <> String.duplicate("s", 30) <> "  "}}},
     "comma.auth secrets must each contain at least 32 bytes"},
    {%{
       comma: %{
         auth: %{
           secret: " #{String.duplicate("s", 32)}",
           rate_limit_secret: "#{String.duplicate("s", 32)}\t"
         }
       }
     }, "comma.auth.secret and comma.auth.rate_limit_secret must be different"},
    {%{comma: %{auth: %{redis_url: "https://redis.example.com"}}},
     "comma.auth.redis_url must be an absolute redis:// or rediss:// URL"}
  ]

  setup_all do
    dir =
      Path.join(
        System.tmp_dir!(),
        "comma-runtime-config-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{results: read_runtime_configs(dir, cases(dir))}
  end

  test "production and staging trust only their own product and Admin browser origins", %{
    results: results
  } do
    {production_output, 0} = results.production_origins

    assert production_output =~
             ~S|COMMA_ORIGINS=["https://app.comma.surf","https://admin.comma.surf"]|

    assert production_output =~ "COMMA_WEB_COOKIE_ORIGIN=https://app.comma.surf"
    assert production_output =~ "COMMA_ADMIN_COOKIE_ORIGIN=https://admin.comma.surf"
    refute production_output =~ "app-staging.comma.surf"
    refute production_output =~ "admin-staging.comma.surf"

    {staging_output, 0} = results.staging_origins

    assert staging_output =~
             ~S|COMMA_ORIGINS=["https://app-staging.comma.surf","https://admin-staging.comma.surf"]|

    assert staging_output =~ "COMMA_WEB_COOKIE_ORIGIN=https://app-staging.comma.surf"
    assert staging_output =~ "COMMA_ADMIN_COOKIE_ORIGIN=https://admin-staging.comma.surf"
  end

  test "production email auth forces Redis and Postmark without code exposure", %{
    results: results
  } do
    {output, 0} = results.production_email

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

  test "production rejects weak, reused, or malformed auth configuration", %{results: results} do
    for {{_override, expected_error}, index} <- Enum.with_index(@weak_auth) do
      {output, status} = Map.fetch!(results, {:weak_auth, index})
      refute status == 0
      assert output =~ expected_error
    end
  end

  test "selfhost HTTP cookies reject non-loopback origins", %{results: results} do
    {output, status} = results.selfhost_http
    refute status == 0
    assert output =~ "Use HTTPS for remote access"
  end

  defp cases(dir) do
    base = write_runtime_config!(dir)

    staging_avatar =
      write_runtime_config!(dir, %{comma: %{profile_avatar: %{bucket: "example-avatars-staging"}}})

    missing_database = Path.join(dir, "missing-database.json")

    File.write!(
      missing_database,
      Jason.encode!(%{billing: %{database: %{url: "ecto://unused:unused@localhost/unused"}}})
    )

    telegram = fn overrides, environment ->
      {base,
       comma_environment: environment,
       expression: @telegram_expression,
       extra_env:
         Enum.map(@telegram_env, fn {key, value} -> {key, Map.get(overrides, key, value)} end)}
    end

    idp = fn environment, issuer ->
      {base,
       comma_environment: environment,
       extra_env: [{"COMMA_OAUTH_IDP_ENABLED", "true"}, {"COMMA_OAUTH_IDP_ISSUER", issuer}]}
    end

    fixed = %{
      missing_database: {missing_database, comma_environment: nil},
      production_origins:
        {base, comma_environment: "production", expression: @origins_expression},
      staging_origins: {base, comma_environment: "staging", expression: @origins_expression},
      production_avatar:
        {write_runtime_config!(dir, %{comma: %{profile_avatar: %{bucket: "json-bucket"}}}),
         comma_environment: "production",
         expression: @avatar_expression,
         extra_env: [{"COMMA_PROFILE_AVATAR_BUCKET", "example-avatars-production"}]},
      production_staging_avatar: {staging_avatar, comma_environment: "production"},
      missing_avatar:
        {write_runtime_config!(dir, %{comma: %{profile_avatar: %{bucket: ""}}}),
         comma_environment: "staging"},
      unknown_environment: {base, comma_environment: "prod-eu"},
      invalid_allowed_origin:
        {write_runtime_config!(dir, %{
           comma: %{web: %{allowed_origins: ["https://app.comma.surf/path"]}}
         }), comma_environment: "production"},
      insecure_production_cookie:
        {base, comma_environment: "production", session_cookie_secure: "false"},
      broader_allowlist:
        {write_runtime_config!(dir, %{
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
         }), comma_environment: "production", expression: @origins_expression},
      production_email: {base, comma_environment: "production", expression: @email_expression},
      trimmed_auth:
        {write_runtime_config!(dir, %{
           comma: %{
             auth: %{
               secret: " \t#{String.duplicate("s", 32)}\n",
               rate_limit_secret: "\n#{String.duplicate("r", 32)} "
             }
           }
         }), comma_environment: "production", expression: @trim_expression},
      idp_http_production: idp.("production", "http://idp.example.com"),
      idp_userinfo: idp.("production", "https://alice:secret@idp.example.com"),
      idp_https_production: idp.("production", "https://idp.example.com"),
      idp_http_dev: idp.("dev", "http://127.0.0.1:4200"),
      telegram_production: telegram.(%{}, "production"),
      telegram_http_origin:
        telegram.(%{"COMMA_TELEGRAM_PUBLIC_BASE_URL" => "http://api.comma.test"}, "production"),
      telegram_remote_override:
        telegram.(
          %{"COMMA_TELEGRAM_API_BASE_URL" => "https://telegram-proxy.example.test"},
          "production"
        ),
      production_smtp:
        {write_runtime_config!(dir, %{
           email: %{postmark_server_token: nil},
           comma: %{
             email: %{
               provider: "smtp",
               smtp: %{host: "smtp.example.com", port: 587, tls: "always"}
             }
           }
         }),
         comma_environment: "production",
         expression:
           @read_config <>
             ~S|; auth = get_in(config, [:comma_core, :auth]); IO.inspect({auth[:email_delivery], auth[:expose_codes], get_in(config, [:comma_core, :mail])[:tls]})|},
      selfhost_http:
        {base,
         comma_environment: "selfhost",
         session_cookie_secure: "false",
         extra_env: [{"COMMA_PUBLIC_URL", "http://public.example.com"}]}
    }

    [
      {:invalid_cookie_origin, @invalid_cookie_origins},
      {:missing_email_auth, @missing_email_auth},
      {:weak_auth, @weak_auth}
    ]
    |> Enum.flat_map(fn {name, overrides} ->
      overrides
      |> Enum.with_index()
      |> Enum.map(fn {{override, _expected}, index} ->
        {{name, index}, {write_runtime_config!(dir, override), comma_environment: "production"}}
      end)
    end)
    |> Map.new()
    |> Map.merge(fixed)
  end

  defp write_runtime_config!(dir, extra \\ %{}) do
    path = Path.join(dir, "config-#{SystemsRuntime.Proc.unique_integer([:positive])}.json")

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

  defp case_env(config_path, opts) do
    env =
      Keyword.get(opts, :extra_env, []) ++
        [
          {"COMMA_SUBSYSTEMS", "comma_product"},
          {"COMMA_ENVIRONMENT", Keyword.fetch!(opts, :comma_environment)},
          {"COMMA_SESSION_COOKIE_SECURE", Keyword.get(opts, :session_cookie_secure)},
          {"SALIX_CONFIG_PATH", config_path}
        ]

    Enum.uniq_by(env, &elem(&1, 0))
  end

  # Evaluates every case in one child VM. Each case sets its environment
  # (nil unsets a variable), evaluates its expression with captured output and
  # restores the environment; a raise is reported as status 1 with its message.
  defp read_runtime_configs(dir, cases) do
    names = Map.keys(cases)

    payload =
      Enum.map(names, fn name ->
        {config_path, opts} = Map.fetch!(cases, name)
        {case_env(config_path, opts), Keyword.get(opts, :expression, @read_config)}
      end)

    input = Path.join(dir, "cases.bin")
    output = Path.join(dir, "results.bin")
    File.write!(input, :erlang.term_to_binary(payload))

    script = """
    set_env = fn env ->
      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end

    results =
      #{inspect(input)}
      |> File.read!()
      |> :erlang.binary_to_term()
      |> Enum.map(fn {env, expression} ->
        previous = Enum.map(env, fn {key, _value} -> {key, System.get_env(key)} end)
        set_env.(env)
        {:ok, device} = StringIO.open("")
        leader = Process.group_leader()
        Process.group_leader(self(), device)

        status =
          try do
            Code.eval_string(expression)
            0
          rescue
            error ->
              IO.puts(Exception.format(:error, error, __STACKTRACE__))
              1
          catch
            kind, reason ->
              IO.puts(Exception.format(kind, reason, __STACKTRACE__))
              1
          end

        Process.group_leader(self(), leader)
        {:ok, {_input, captured}} = StringIO.close(device)
        set_env.(previous)
        {captured, status}
      end)

    File.write!(#{inspect(output)}, :erlang.term_to_binary(results))
    """

    {log, status} =
      System.cmd("mix", ["run", "--no-start", "--no-compile", "--no-deps-check", "-e", script],
        cd: Path.expand("../../../../..", __DIR__),
        # Boot with an ordinary production case; each case then applies its own.
        env:
          [{"MIX_ENV", "test"}, {"REDIS_URL", "redis://127.0.0.1:6379/0"}] ++
            Enum.reject(
              apply(&case_env/2, Tuple.to_list(Map.fetch!(cases, :production_origins))),
              &is_nil(elem(&1, 1))
            ),
        stderr_to_stdout: true
      )

    assert status == 0, log

    results = output |> File.read!() |> :erlang.binary_to_term()
    names |> Enum.zip(results) |> Map.new()
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
  end
end
