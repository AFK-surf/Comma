defmodule CommaWeb.AuthAbuseClientChainTest do
  use Comma.DataCase, async: false
  import Plug.Conn
  alias Comma.Auth.AbuseFixtures
  @moduletag database_isolation: "SERIALIZABLE"

  defmodule Mailbox do
    use Agent
    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def deliver(email, code), do: Agent.update(__MODULE__, &Map.put(&1, email, code))
    def code(email), do: Agent.get(__MODULE__, &Map.get(&1, email))
    def decoded_play, do: Agent.get(__MODULE__, &Map.get(&1, :decoded_play, 0))

    def play_decode,
      do: Agent.update(__MODULE__, &Map.update(&1, :decoded_play, 1, fn count -> count + 1 end))
  end

  defmodule Delivery do
    @behaviour Comma.EmailDelivery
    def send_login_code(email, code, _opts), do: Mailbox.deliver(email, code)
  end

  defmodule Providers do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)

      response =
        if conn.host == "playintegrity.googleapis.com" do
          %{"integrity_token" => "local-play:" <> hash} = Jason.decode!(body)
          Mailbox.play_decode()

          %{
            "tokenPayloadExternal" => %{
              "requestDetails" => %{
                "requestPackageName" => "surf.comma.android",
                "requestHash" => hash,
                "timestampMillis" => Integer.to_string(SystemsClock.system_time(:millisecond))
              },
              "appIntegrity" => %{
                "appRecognitionVerdict" => "PLAY_RECOGNIZED",
                "packageName" => "surf.comma.android",
                "certificateSha256Digest" => ["local-play-signing-certificate"]
              },
              "deviceIntegrity" => %{"deviceRecognitionVerdict" => ["MEETS_DEVICE_INTEGRITY"]}
            }
          }
        else
          ["local-captcha", id] =
            URI.decode_query(body)["response"] |> String.split(":", parts: 2)

          %{
            "success" => true,
            "hostname" => "127.0.0.1",
            "action" => "email_login",
            "cdata" => id
          }
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(response))
    end
  end

  defmodule Router do
    @behaviour Plug
    def init(opts), do: opts

    def call(%{request_path: "/_test/auth-abuse/code"} = conn, _opts) do
      conn = fetch_query_params(conn)
      reply(conn, %{"code" => Mailbox.code(conn.query_params["email"])})
    end

    def call(%{method: "POST", request_path: "/_test/auth-abuse/apple-proof"} = conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      challenge = Jason.decode!(body)
      bytes = Comma.Auth.Abuse.proof_input(challenge["id"], challenge["secret"])

      fixture =
        AbuseFixtures.apple(bytes, seed: :erlang.phash2(challenge["email"], 1_000_000) + 3)

      reply(conn, %{
        "provider" => "apple",
        "apple" => %{"key_id" => fixture.key_id, "attestation" => fixture.attestation}
      })
    end

    def call(conn, _opts), do: CommaWeb.Router.call(conn, CommaWeb.Router.init([]))

    defp reply(conn, value),
      do:
        conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(value))
  end

  test "core, Main custody, HTTP, PostgreSQL and Redis protect app email actions" do
    SystemsRuntime.Test.shared()
    start_supervised!(Mailbox)
    fixture = AbuseFixtures.apple("local-root")
    url = System.get_env("COMMA_TEST_REDIS_URL", "redis://127.0.0.1:6379/0")

    prefix =
      "comma:test:auth-chain:#{SystemsRuntime.Proc.unique_integer([:positive, :monotonic])}"

    auth = SystemsRuntime.fetch_env!(:comma_core, :auth)

    SystemsRuntime.Test.put_env(
      :comma_core,
      :auth,
      Keyword.merge(auth,
        challenge_store: Comma.AuthChallengeStore.Redis,
        redis_url: url,
        redis_key_prefix: prefix,
        email_delivery: Delivery,
        expose_codes: false
      )
    )

    start_supervised!(
      {Redix, {url, [name: Comma.AuthChallengeStore.Redis.connection_name(), sync_connect: true]}}
    )

    on_exit(fn -> cleanup_redis(url, prefix) end)

    server =
      start_supervised!({Bandit, plug: Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    origin = "http://127.0.0.1:#{port}"
    SystemsRuntime.Test.put_env(:salix_web, :public_base_url, origin)

    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse,
      enabled: true,
      turnstile: [
        site_key: "local-site",
        secret: "local-secret",
        request_options: [plug: {Providers, []}]
      ],
      apple: [
        app_id: fixture.app_id,
        environment: "production",
        verifier_options: [root: fixture.root]
      ],
      play: [
        decoder_service_account: "decoder@example-project.iam.gserviceaccount.com",
        project_number: "123",
        package_name: "surf.comma.android",
        certificate_digests: ["local-play-signing-certificate"],
        token_provider: fn -> {:ok, "local-runtime-access"} end,
        request_options: [plug: {Providers, []}]
      ]
    )

    clients = Path.expand("../../../../clients", __DIR__)

    for enabled <- [true, false] do
      config = SystemsRuntime.fetch_env!(:comma_core, :auth_abuse)

      SystemsRuntime.Test.put_env(
        :comma_core,
        :auth_abuse,
        Keyword.put(config, :enabled, enabled)
      )

      decodes_before = Mailbox.decoded_play()

      {output, status} =
        System.cmd(
          "pnpm",
          ["exec", "vitest", "run", "--config", "apps/electron/e2e/auth-abuse-chain.config.ts"],
          cd: clients,
          env: [
            {"COMMA_AUTH_CHAIN_API_ORIGIN", origin},
            {"COMMA_AUTH_CHAIN_ENFORCE", to_string(enabled)}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert Mailbox.decoded_play() == decodes_before + 1
      phase = if enabled, do: "", else: "observed-"

      for name <- ~w(electron ios android fallback) do
        email = phase <> name <> "-chain@example.test"
        assert {:ok, user} = Comma.Accounts.Repository.get_user_by_email(email)
        assert user.signup_credit_eligible
        assert Mailbox.code(email) != nil
      end

      # Off admission alone cannot prove Apple evidence was valid. Its actual verifier must enroll this target.
      email = phase <> "ios-chain@example.test"
      expected = AbuseFixtures.apple("key-identity", seed: :erlang.phash2(email, 1_000_000) + 3)
      assert {:ok, target} = Comma.AuthChallenges.email_fingerprint(email)
      assert %{email_fingerprint: ^target} = Repo.get!(Comma.Auth.Abuse.AppleKey, expected.key_id)
    end
  end

  defp cleanup_redis(url, prefix) do
    {:ok, connection} = Redix.start_link(url)

    try do
      cleanup_page(connection, prefix, "0")
    after
      GenServer.stop(connection)
    end
  end

  defp cleanup_page(connection, prefix, cursor) do
    {:ok, [next, keys]} =
      Redix.command(connection, ["SCAN", cursor, "MATCH", prefix <> ":*", "COUNT", "100"])

    if keys != [], do: Redix.command!(connection, ["DEL" | keys])
    if next != "0", do: cleanup_page(connection, prefix, next)
  end
end
