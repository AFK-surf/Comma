defmodule Comma.AuthAbuseTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.Comma"], epoch: ~U[2026-01-01 00:00:00Z]
  alias Comma.Auth.{Abuse, OneTimeCredentials}
  alias Comma.Auth.Abuse.{Play, Turnstile}
  alias Comma.Auth.AbuseFixtures, as: Fixture
  import ExUnit.CaptureLog

  defmodule Delivery do
    @behaviour Comma.EmailDelivery

    def send_login_code(email, _code, _opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.get_env(:comma_core, :abuse_request_pid),
        {:login_code_delivery, email}
      )

      :ok
    end
  end

  defmodule Provider do
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      SystemsRuntime.Proc.send(
        SystemsRuntime.get_env(:comma_core, :abuse_request_pid),
        {:provider_request, conn.host, body}
      )

      case SystemsRuntime.get_env(:comma_core, :abuse_provider_reply) do
        {:status, status, value} -> Plug.Conn.send_resp(conn, status, Jason.encode!(value))
        value -> Plug.Conn.send_resp(conn, 200, Jason.encode!(value))
      end
    end
  end

  setup do
    Comma.AuthChallengeStore.Memory.reset!()
    on_exit(fn -> Comma.AuthChallengeStore.Memory.reset!() end)
    SystemsRuntime.Test.put_env(:comma_core, :selfhost, false)
    auth = SystemsRuntime.get_env(:comma_core, :auth, [])

    SystemsRuntime.Test.put_env(
      :comma_core,
      :auth,
      Keyword.put(auth, :challenge_store, Comma.AuthChallengeStore.Memory)
    )

    SystemsRuntime.Test.put_env(:comma_core, :abuse_request_pid, SystemsRuntime.Proc.self())

    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse,
      enabled: true,
      turnstile: [
        site_key: "fixture-site",
        secret: "fixture-secret",
        request_options: [plug: Provider]
      ],
      play: [
        decoder_service_account: "decoder@example-project.iam.gserviceaccount.com",
        project_number: "123",
        package_name: "surf.comma.android",
        certificate_digests: ["release-certificate"],
        token_provider: fn -> {:ok, "fixture-access"} end,
        request_options: [plug: Provider]
      ]
    )

    %{context: %{"api_origin" => "https://api.example.test", "remote_ip" => "127.0.0.1"}}
  end

  test "proof input matches the shared native/server codec vector" do
    input = Abuse.proof_input("abuse_fixture", "secret_fixture")

    assert Base.encode16(:crypto.hash(:sha256, input), case: :lower) ==
             "0ded104f115699dadf2eda7731e6a22e7f3e9def7fe67ab2e890469e4a080ab2"

    assert Base.url_encode64(:crypto.hash(:sha256, input), padding: false) ==
             "De0QTxFWmdrfLtp3MeaiLn8-ne9_5nqy6JBGnkoICrI"

    assert Comma.GuestPow.leading_zero_bits(:crypto.hash(:sha256, input <> ":3442")) >= 12
  end

  test "Siteverify must confirm hostname, action and current cdata, not a client success flag", %{
    context: context
  } do
    {:challenge, :captcha_required, challenge} =
      Abuse.check("email_login", "person@example.test", "web", nil, context)

    reply = captcha_reply(challenge)

    for field <- ["hostname", "action", "cdata"] do
      SystemsRuntime.Test.put_env(
        :comma_core,
        :abuse_provider_reply,
        Map.put(reply, field, "other")
      )

      assert {:error, :captcha_rejected} = Turnstile.verify("token", challenge, context)
    end

    SystemsRuntime.Test.put_env(:comma_core, :abuse_provider_reply, reply)
    assert :ok = Turnstile.verify("token", challenge, context)
    assert_received {:provider_request, "challenges.cloudflare.com", body}
    assert URI.decode_query(body)["secret"] == "fixture-secret"
  end

  test "accepted CAPTCHA consumes one action and rejects cross-target, replay and expired attempts",
       %{context: context} do
    {:challenge, :captcha_required, challenge} =
      Abuse.check("email_login", "person@example.test", "electron", nil, context)

    SystemsRuntime.Test.put_env(:comma_core, :abuse_provider_reply, captcha_reply(challenge))
    proof = captcha_proof(challenge)

    assert {:error, :invalid_abuse_challenge} =
             Abuse.check("email_login", "other@example.test", "electron", proof, context)

    assert {:error, :invalid_abuse_challenge} =
             Abuse.check("email_login", "person@example.test", "electron", proof, context)

    {:challenge, :captcha_required, fresh} =
      Abuse.check("email_login", "person@example.test", "electron", nil, context)

    SystemsRuntime.Test.put_env(:comma_core, :abuse_provider_reply, captcha_reply(fresh))

    assert :ok =
             Abuse.check(
               "email_login",
               "person@example.test",
               "electron",
               captcha_proof(fresh),
               context
             )

    assert {:error, :invalid_abuse_challenge} =
             Abuse.check(
               "email_login",
               "person@example.test",
               "electron",
               captcha_proof(fresh),
               context
             )

    {:challenge, :captcha_required, expired} =
      Abuse.check("email_login", "person@example.test", "web", nil, context)

    SystemsClock.advance(301_000)

    assert {:error, :invalid_abuse_challenge} =
             Abuse.check(
               "email_login",
               "person@example.test",
               "web",
               captcha_proof(expired),
               context
             )
  end

  test "native failure creates a new CAPTCHA-only challenge, and work alone cannot authorize", %{
    context: context
  } do
    {:challenge, :native_proof_required, native} =
      Abuse.check("email_login", "person@example.test", "android", nil, context)

    proof = %{
      "challenge_id" => native["id"],
      "challenge_secret" => native["secret"],
      "provider" => "play",
      "pow_nonce" => Fixture.solve(native)
    }

    {:challenge, :captcha_required, captcha} =
      Abuse.check("email_login", "person@example.test", "android", proof, context)

    refute captcha["id"] == native["id"]
    assert captcha["method"] == "captcha"

    assert URI.decode_query(URI.parse(captcha["captcha_url"]).query) == %{
             "challenge_id" => captcha["id"],
             "action" => "email_login"
           }

    assert {:error, :invalid_abuse_challenge} =
             Abuse.check("email_login", "person@example.test", "android", proof, context)

    attempted_native = %{
      "challenge_id" => captcha["id"],
      "challenge_secret" => captcha["secret"],
      "provider" => "play",
      "pow_nonce" => "3442",
      "play_token" => "token"
    }

    assert {:challenge, :captcha_required, _} =
             Abuse.check(
               "email_login",
               "person@example.test",
               "android",
               attempted_native,
               context
             )
  end

  test "registration proof binds its continuation without consuming it first", %{context: context} do
    {:ok, credential} =
      OneTimeCredentials.issue(
        "registration",
        %{"claims" => %{"email" => "verified@example.test"}},
        300,
        "127.0.0.1",
        Abuse.peer_limits()
      )

    packed = OneTimeCredentials.pack(credential)
    assert {:ok, id, secret} = OneTimeCredentials.unpack(packed)
    context = Map.put(context, "registration_continuation", packed)

    {:challenge, :captcha_required, challenge} =
      Abuse.check("registration", "verified@example.test", "web", nil, context)

    SystemsRuntime.Test.put_env(:comma_core, :abuse_provider_reply, captcha_reply(challenge))
    assert :ok = Abuse.check("registration", nil, nil, captcha_proof(challenge), context)

    assert {:ok, %{"claims" => %{"email" => "verified@example.test"}}} =
             OneTimeCredentials.consume("registration", id, secret)

    assert {:error, :invalid_one_time_credential} =
             OneTimeCredentials.consume("registration", id, secret)
  end

  test "a rejected work stage records an unchecked provider and does not invoke it", %{
    context: context
  } do
    {:challenge, :native_proof_required, native} =
      Abuse.check("email_login", "work-stage@example.test", "android", nil, context)

    proof = %{
      "challenge_id" => native["id"],
      "challenge_secret" => native["secret"],
      "provider" => "play",
      "pow_nonce" => "invalid",
      "play_token" => "private-token"
    }

    log =
      capture_log(fn ->
        assert {:challenge, :captcha_required, _} =
                 Abuse.check("email_login", "work-stage@example.test", "android", proof, context)
      end)

    assert log =~ "verdict=rejected pow=rejected proof=not_checked"
    refute_received {:provider_request, _, _}
  end

  test "a Play transport timeout requires CAPTCHA before email delivery", %{context: context} do
    config = SystemsRuntime.get_env(:comma_core, :auth_abuse)
    caller = SystemsRuntime.Proc.self()

    adapter = fn request ->
      SystemsRuntime.Proc.send(caller, :play_decoder_timeout)
      {request, %Req.TransportError{reason: :timeout}}
    end

    SystemsRuntime.Test.put_env(
      :comma_core,
      :auth_abuse,
      Keyword.update!(config, :play, &Keyword.put(&1, :request_options, adapter: adapter))
    )

    record_delivery()
    attrs = Map.merge(context, %{"email" => "timeout@example.test", "platform" => "android"})

    {:challenge, :native_proof_required, %{"challenge" => native}} =
      Comma.AuthChallenges.request_email_login(attrs)

    proof = %{
      "challenge_id" => native["id"],
      "challenge_secret" => native["secret"],
      "provider" => "play",
      "play_token" => "token",
      "pow_nonce" => Fixture.solve(native)
    }

    assert {:challenge, :captcha_required, %{"challenge" => captcha}} =
             Comma.AuthChallenges.request_email_login(Map.put(attrs, "abuse", proof))

    refute captcha["id"] == native["id"]
    assert_received :play_decoder_timeout
    refute_received :play_decoder_timeout
    refute_received {:login_code_delivery, _}
  end

  test "an oversized otherwise-valid Siteverify response cannot send a login code", %{
    context: context
  } do
    record_delivery()
    attrs = Map.merge(context, %{"email" => "large@example.test", "platform" => "web"})

    {:challenge, :captcha_required, %{"challenge" => challenge}} =
      Comma.AuthChallenges.request_email_login(attrs)

    SystemsRuntime.Test.put_env(
      :comma_core,
      :abuse_provider_reply,
      Map.put(captcha_reply(challenge), "padding", String.duplicate("x", 70_000))
    )

    assert {:challenge, :captcha_required, %{"challenge" => fresh}} =
             Comma.AuthChallenges.request_email_login(
               Map.put(attrs, "abuse", captcha_proof(challenge))
             )

    refute fresh["id"] == challenge["id"]
    assert_received {:provider_request, "challenges.cloudflare.com", _}
    refute_received {:login_code_delivery, _}
  end

  test "Play requires the independent decoder's binding, release certificate, age and device verdict" do
    bytes = "comma-abuse:abuse_fixture:secret_fixture"
    payload = play_payload(bytes)

    SystemsRuntime.Test.put_env(:comma_core, :abuse_provider_reply, %{
      "tokenPayloadExternal" => payload
    })

    assert :ok = Play.verify("token", bytes)
    assert {:error, :native_proof_rejected} = Play.verify("token", bytes <> "-other")

    for changed <- [
          put_in(payload, ["appIntegrity", "certificateSha256Digest"], ["other-release"]),
          put_in(payload, ["appIntegrity", "packageName"], "other.package"),
          put_in(payload, ["deviceIntegrity", "deviceRecognitionVerdict"], []),
          put_in(
            payload,
            ["requestDetails", "timestampMillis"],
            Integer.to_string(SystemsClock.system_time(:millisecond) - 120_001)
          )
        ] do
      SystemsRuntime.Test.put_env(:comma_core, :abuse_provider_reply, %{
        "tokenPayloadExternal" => changed
      })

      assert {:error, :native_proof_rejected} = Play.verify("token", bytes)
    end
  end

  test "native observation admits target, secret and expiry failures without another challenge",
       %{context: context} do
    config = SystemsRuntime.fetch_env!(:comma_core, :auth_abuse)
    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, Keyword.put(config, :enabled, false))
    context = Map.put(context, "native_proof", true)

    for failure <- [:target, :secret, :expired] do
      email = "observe-#{failure}@example.test"

      {:challenge, :native_proof_required, challenge} =
        Abuse.check("email_login", email, "android", nil, context)

      proof = %{
        "challenge_id" => challenge["id"],
        "challenge_secret" => challenge["secret"],
        "provider" => "play",
        "pow_nonce" => Fixture.solve(challenge),
        "play_token" => "token"
      }

      email = if failure == :target, do: "other@example.test", else: email
      proof = if failure == :secret, do: Map.put(proof, "challenge_secret", "wrong"), else: proof
      if failure == :expired, do: SystemsClock.advance(301_000)

      log =
        capture_log(fn ->
          assert :ok = Abuse.check("email_login", email, "android", proof, context)
        end)

      assert log =~ "mode=observe verdict=invalid_context"
      refute_received {:provider_request, _, _}
    end
  end

  test "an IAM redirect cannot forward credentials or add a decoder request" do
    adapter = fn request ->
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:iam_redirect_request, request.url.host}
      )

      case request.url.host do
        "metadata.google.internal" ->
          {request,
           %Req.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "access_token" => "bootstrap",
                 "expires_in" => 3600,
                 "token_type" => "Bearer"
               })
           }}

        "iamcredentials.googleapis.com" ->
          {request,
           %Req.Response{
             status: 302,
             headers: %{"location" => ["https://playintegrity.googleapis.com/redirected"]},
             body: ""
           }}

        _ ->
          {request, %Req.Response{status: 403, body: "{}"}}
      end
    end

    config = SystemsRuntime.fetch_env!(:comma_core, :auth_abuse)

    play =
      config[:play]
      |> Keyword.delete(:token_provider)
      |> Keyword.put(:request_options, adapter: adapter)

    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, Keyword.put(config, :play, play))
    assert {:error, :native_proof_rejected} = Play.verify("token", "proof-bytes")
    assert_received {:iam_redirect_request, "metadata.google.internal"}
    assert_received {:iam_redirect_request, "iamcredentials.googleapis.com"}
    refute_received {:iam_redirect_request, _}
  end

  test "missing hosted configuration is bounded and the existing peer policy remains authoritative",
       %{context: context} do
    assert {:error, :auth_abuse_unavailable} =
             Abuse.check(
               "email_login",
               "person@example.test",
               "web",
               nil,
               Map.delete(context, "api_origin")
             )

    auth = SystemsRuntime.get_env(:comma_core, :auth)
    SystemsRuntime.Test.put_env(:comma_core, :auth, Keyword.put(auth, :ip_request_limit, 2))

    assert {:challenge, :captcha_required, _} =
             Abuse.check("email_login", "one@example.test", "web", nil, context)

    assert {:challenge, :captcha_required, _} =
             Abuse.check("email_login", "two@example.test", "web", nil, context)

    assert {:error, {:rate_limited, _}} =
             Abuse.check("email_login", "three@example.test", "web", nil, context)

    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, enabled: true)

    assert {:error, :auth_abuse_unavailable} =
             Abuse.check("email_login", "person@example.test", "web", nil, context)

    SystemsRuntime.Test.put_env(:comma_core, :selfhost, true)
    assert :ok = Abuse.check("email_login", "person@example.test", "web", nil, context)
  end

  defp record_delivery do
    auth = SystemsRuntime.get_env(:comma_core, :auth)
    SystemsRuntime.Test.put_env(:comma_core, :auth, Keyword.put(auth, :email_delivery, Delivery))
  end

  defp captcha_reply(challenge),
    do: %{
      "success" => true,
      "hostname" => "api.example.test",
      "action" => challenge["action"],
      "cdata" => challenge["id"]
    }

  defp captcha_proof(challenge),
    do: %{
      "challenge_id" => challenge["id"],
      "challenge_secret" => challenge["secret"],
      "provider" => "turnstile",
      "captcha_token" => "token"
    }

  defp play_payload(bytes),
    do: %{
      "requestDetails" => %{
        "requestPackageName" => "surf.comma.android",
        "requestHash" => Base.url_encode64(:crypto.hash(:sha256, bytes), padding: false),
        "timestampMillis" => Integer.to_string(SystemsClock.system_time(:millisecond))
      },
      "appIntegrity" => %{
        "appRecognitionVerdict" => "PLAY_RECOGNIZED",
        "packageName" => "surf.comma.android",
        "certificateSha256Digest" => ["release-certificate"]
      },
      "deviceIntegrity" => %{"deviceRecognitionVerdict" => ["MEETS_DEVICE_INTEGRITY"]}
    }
end
