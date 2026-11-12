defmodule CommaWeb.AuthAbuseHTTPTest do
  use Comma.DataCase, async: false
  import Plug.Conn
  alias Comma.Accounts.{AuthSession, User}
  alias Comma.AuthAbuseTestSupport, as: Evidence
  import ExUnit.CaptureLog
  @moduletag database_isolation: "SERIALIZABLE"
  setup {Evidence, :setup}

  defmodule Delivery do
    @behaviour Comma.EmailDelivery
    def send_login_code(email, code, _opts) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:delivered, email, code})
      :ok
    end
  end

  defmodule ObservationStore do
    alias Comma.AuthChallengeStore.Memory

    def reserve_attempt(%{"purpose" => purpose} = challenge, ttl, opts) do
      case SystemsRuntime.get_env(:comma_core, :observation_store_failure) do
        {^purpose, :raise} -> raise "fixture store unavailable"
        {^purpose, error} -> error
        _ -> Memory.reserve_attempt(challenge, ttl, opts)
      end
    end

    defdelegate reserve(challenge, ttl, opts), to: Memory
    defdelegate verify(id, code, attempts), to: Memory
    defdelegate verify(id, code, attempts, opts), to: Memory
    defdelegate record_delivery(result, opts), to: Memory
    defdelegate delete(id), to: Memory
  end

  setup do
    SystemsRuntime.Test.put_env(:comma_core, :selfhost, false)
    Comma.AuthChallengeStore.Memory.reset!()
    auth = SystemsRuntime.fetch_env!(:comma_core, :auth)

    SystemsRuntime.Test.put_env(
      :comma_core,
      :auth,
      Keyword.merge(auth, email_delivery: Delivery, expose_codes: false)
    )

    :ok
  end

  test "email login sends its code without abuse configuration by default" do
    SystemsRuntime.Test.delete_env(:comma_core, :auth_abuse)
    email = "default-email@example.test"
    response = post("/v1/comma/auth/email/login", %{"email" => email})
    assert response.status == 200
    refute Map.has_key?(body(response), "challenge")
    assert_received {:delivered, ^email, _}
  end

  test "disabled abuse checks leave a configured email login unchanged" do
    config = SystemsRuntime.fetch_env!(:comma_core, :auth_abuse)
    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, Keyword.put(config, :enabled, false))
    email = "disabled-email@example.test"
    response = post("/v1/comma/auth/email/login", %{"email" => email, "platform" => "android"})
    assert response.status == 200
    refute Map.has_key?(body(response), "challenge")
    assert_received {:delivered, ^email, _}
  end

  test "disabled abuse checks create a new Google session without a continuation" do
    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, enabled: false)
    {:ok, attempt} = Comma.GoogleAuth.start_attempt(%{"platform" => "web"})
    credential = "disabled-google-credential"
    email = "disabled-google@example.test"

    SystemsRuntime.Test.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => %{
        "iss" => "https://accounts.google.com",
        "sub" => "disabled-google-subject",
        "email" => email,
        "email_verified" => true,
        "aud" => attempt["client_id"],
        "nonce" => attempt["nonce"]
      }
    })

    response = post("/v1/comma/auth/google", Map.put(attempt, "credential", credential))
    assert response.status == 200
    response = body(response)
    refute Map.has_key?(response, "registration_continuation")
    assert {:ok, user, _session} = Comma.Accounts.validate_session(response["token"])
    assert user["email"] == email
    refute_received {:delivered, _, _}
  end

  test "disabled abuse checks create a new Apple session without a continuation" do
    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, enabled: false)
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    public = Map.merge(public, %{"kid" => "toggle-apple", "alg" => "RS256", "use" => "sig"})

    SystemsRuntime.Test.put_env(:comma_core, :apple_auth,
      client_id: "surf.comma.ios.test",
      request_options: [plug: {Req.Test, __MODULE__}]
    )

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"keys" => [public]}) end)
    keys = start_supervised!(Comma.Auth.AppleKeys)
    Req.Test.allow(__MODULE__, SystemsRuntime.Proc.self(), keys)
    {:ok, attempt} = Comma.AppleAuth.start_attempt()
    email = "disabled-apple@example.test"
    now = SystemsClock.system_time(:second)

    token =
      JOSE.JWT.sign(key, %{"alg" => "RS256", "kid" => "toggle-apple"}, %{
        "iss" => "https://appleid.apple.com",
        "sub" => "disabled-apple-subject",
        "aud" => attempt["client_id"],
        "nonce" => attempt["nonce"],
        "iat" => now,
        "exp" => now + 300,
        "email" => email,
        "email_verified" => "true"
      })
      |> JOSE.JWS.compact()
      |> elem(1)

    response =
      post("/v1/comma/auth/apple", %{
        "attempt_id" => attempt["attempt_id"],
        "identity_token" => token,
        "client_kind" => "ios",
        "client_platform" => "ios"
      })

    assert response.status == 200
    response = body(response)
    refute Map.has_key?(response, "registration_continuation")
    assert {:ok, user, _session} = Comma.Accounts.validate_session(response["token"])
    assert user["email"] == email
    refute_received {:delivered, _, _}
  end

  test "opted-in native observation collects once without configuration and never requires CAPTCHA" do
    SystemsRuntime.Test.delete_env(:comma_core, :auth_abuse)

    for platform <- ["ios", "android"] do
      email = "observe-#{platform}@example.test"
      attrs = %{"email" => email, "platform" => platform, "native_proof" => true}
      initial = post("/v1/comma/auth/email/login", attrs)
      assert initial.status == 428
      assert body(initial)["error"] == "native_proof_required"
      challenge = body(initial)["challenge"]
      assert challenge["enforce"] == false
      refute Map.has_key?(challenge, "captcha_url")
      refute Map.has_key?(challenge, "apple_environment")
      refute Map.has_key?(challenge, "google_cloud_project_number")
      refute_received {:delivered, _, _}

      {response, log} =
        with_log(fn ->
          post(
            "/v1/comma/auth/email/login",
            Map.put(attrs, "abuse", Evidence.evidence(challenge))
          )
        end)

      assert response.status == 200
      refute Map.has_key?(body(response), "challenge")
      assert log =~ "mode=observe verdict=rejected"
      assert log =~ "pow=rejected proof=unavailable"
      refute log =~ email
      refute log =~ challenge["id"]
      refute log =~ challenge["secret"]
      assert_received {:delivered, ^email, code}
      bad_code = if code == "000000", do: "111111", else: "000000"
      # Observation admits sending, never mailbox authentication.
      assert post("/v1/comma/auth/email/verify", %{
               "challenge_id" => body(response)["challenge_id"],
               "code" => bad_code
             }).status == 401
    end
  end

  test "malformed supplied observation evidence admits the original email request without another challenge" do
    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, enabled: false)

    log =
      capture_log(fn ->
        response =
          post("/v1/comma/auth/email/login", %{
            "email" => "malformed-observation@example.test",
            "platform" => "ios",
            "native_proof" => true,
            "abuse" => "malformed"
          })

        assert response.status == 200
        refute Map.has_key?(body(response), "challenge")
      end)

    assert log =~ "mode=observe verdict=invalid_context"
    assert_received {:delivered, "malformed-observation@example.test", _}
  end

  test "supplied native proof without repeated intent is verified once and observed before email delivery" do
    play = [
      decoder_service_account: "decoder@example-project.iam.gserviceaccount.com",
      project_number: "123",
      package_name: "surf.comma.android",
      certificate_digests: ["release-certificate"]
    ]

    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, enabled: false, play: play)
    email = "observed-accepted@example.test"
    attrs = %{"email" => email, "platform" => "android", "native_proof" => true}
    initial = post("/v1/comma/auth/email/login", attrs)
    assert initial.status == 428
    challenge = body(initial)["challenge"]
    bytes = Comma.Auth.Abuse.proof_input(challenge["id"], challenge["secret"])

    payload = %{
      "tokenPayloadExternal" => %{
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
    }

    adapter = fn request ->
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:observed_play_request, request.url.host}
      )

      reply =
        case request.url.host do
          "metadata.google.internal" ->
            assert request.method == :get

            assert request.url.path ==
                     "/computeMetadata/v1/instance/service-accounts/default/token"

            assert Req.Request.get_header(request, "metadata-flavor") == ["Google"]
            assert Req.Request.get_header(request, "authorization") == []

            %{
              "access_token" => "private-bootstrap",
              "expires_in" => 3600,
              "token_type" => "Bearer"
            }

          "iamcredentials.googleapis.com" ->
            assert request.method == :post
            assert request.url.scheme == "https"

            assert request.url.path ==
                     "/v1/projects/-/serviceAccounts/decoder%40example-project.iam.gserviceaccount.com:generateAccessToken"

            assert Req.Request.get_header(request, "authorization") == [
                     "Bearer private-bootstrap"
                   ]

            assert Jason.decode!(request.body) == %{
                     "scope" => ["https://www.googleapis.com/auth/playintegrity"]
                   }

            %{"accessToken" => "private-play-access", "expireTime" => "2035-01-01T00:00:00Z"}

          "playintegrity.googleapis.com" ->
            assert request.method == :post

            assert Req.Request.get_header(request, "authorization") == [
                     "Bearer private-play-access"
                   ]

            assert Jason.decode!(request.body) == %{"integrity_token" => "private-provider-token"}
            payload
        end

      {request, %Req.Response{status: 200, body: Jason.encode!(reply)}}
    end

    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse,
      enabled: false,
      play: Keyword.put(play, :request_options, adapter: adapter)
    )

    proof = %{
      "challenge_id" => challenge["id"],
      "challenge_secret" => challenge["secret"],
      "provider" => "play",
      "play_token" => "private-provider-token",
      "pow_nonce" => Comma.Auth.AbuseFixtures.solve(challenge)
    }

    log =
      capture_log(fn ->
        response =
          post(
            "/v1/comma/auth/email/login",
            attrs |> Map.delete("native_proof") |> Map.put("abuse", proof)
          )

        assert response.status == 200
      end)

    assert log =~
             "action=email_login platform=android provider=play mode=observe verdict=accepted"

    assert log =~ "pow=accepted proof=accepted"

    for private <- [
          email,
          challenge["id"],
          challenge["secret"],
          proof["play_token"],
          "private-bootstrap",
          "private-play-access",
          "127.0.0.1"
        ] do
      refute log =~ private
    end

    hosts =
      for _ <- 1..3 do
        assert_received {:observed_play_request, host}
        host
      end

    assert hosts == [
             "metadata.google.internal",
             "iamcredentials.googleapis.com",
             "playintegrity.googleapis.com"
           ]

    refute_received {:observed_play_request, _}
    assert_received {:delivered, ^email, _}
  end

  test "IAM failure stops decoding and preserves observation admission and enforced CAPTCHA" do
    config = SystemsRuntime.fetch_env!(:comma_core, :auth_abuse)

    adapter = fn request ->
      SystemsRuntime.Proc.send(
        SystemsRuntime.Proc.self(),
        {:failed_play_request, request.url.host}
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
          {request, %Req.Response{status: 403, body: "{}"}}

        "playintegrity.googleapis.com" ->
          flunk("IAM failure must not reach the decoder")
      end
    end

    play = [
      decoder_service_account: "decoder@example-project.iam.gserviceaccount.com",
      project_number: "123",
      package_name: "surf.comma.android",
      certificate_digests: ["release-certificate"],
      request_options: [adapter: adapter]
    ]

    for enabled <- [false, true] do
      SystemsRuntime.Test.put_env(
        :comma_core,
        :auth_abuse,
        config |> Keyword.put(:enabled, enabled) |> Keyword.put(:play, play)
      )

      email = "iam-failure-#{enabled}@example.test"
      attrs = %{"email" => email, "platform" => "android", "native_proof" => true}
      initial = post("/v1/comma/auth/email/login", attrs)
      assert initial.status == 428
      challenge = body(initial)["challenge"]

      proof = %{
        "challenge_id" => challenge["id"],
        "challenge_secret" => challenge["secret"],
        "provider" => "play",
        "play_token" => "token",
        "pow_nonce" => Comma.Auth.AbuseFixtures.solve(challenge)
      }

      response = post("/v1/comma/auth/email/login", Map.put(attrs, "abuse", proof))

      if enabled do
        assert response.status == 428
        assert body(response)["error"] == "captcha_required"
        refute_received {:delivered, _, _}
      else
        assert response.status == 200
        assert_received {:delivered, ^email, _}
      end

      assert_received {:failed_play_request, "metadata.google.internal"}
      assert_received {:failed_play_request, "iamcredentials.googleapis.com"}
      refute_received {:failed_play_request, _}
    end
  end

  test "observation storage failure cannot block the original email or verified OAuth registration" do
    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, enabled: false)
    auth = SystemsRuntime.fetch_env!(:comma_core, :auth)

    SystemsRuntime.Test.put_env(
      :comma_core,
      :auth,
      Keyword.put(auth, :challenge_store, ObservationStore)
    )

    SystemsRuntime.Test.put_env(
      :comma_core,
      :observation_store_failure,
      {"abuse", {:error, :rate_limited, 60}}
    )

    response =
      post("/v1/comma/auth/email/login", %{
        "email" => "observe-store@example.test",
        "platform" => "ios",
        "native_proof" => true
      })

    assert response.status == 200
    assert_received {:delivered, "observe-store@example.test", _}

    SystemsRuntime.Test.put_env(
      :comma_core,
      :observation_store_failure,
      {"app_registration", :raise}
    )

    {:ok, attempt} = Comma.GoogleAuth.start_attempt(%{"platform" => "ios"})
    credential = "observe-fallback-google"
    email = "observe-fallback@example.test"

    SystemsRuntime.Test.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => %{
        "iss" => "https://accounts.google.com",
        "sub" => "observe-fallback-subject",
        "email" => email,
        "email_verified" => true,
        "aud" => attempt["client_id"],
        "nonce" => attempt["nonce"]
      }
    })

    response =
      post(
        "/v1/comma/auth/google",
        Map.merge(attempt, %{
          "credential" => credential,
          "native_proof" => true,
          "client_kind" => "ios",
          "client_platform" => "ios"
        })
      )

    assert response.status == 200
    assert {:ok, user, _session} = Comma.Accounts.validate_session(body(response)["token"])
    assert user["email"] == email
    assert Repo.get!(AuthSession, body(response)["session_id"]).client_kind == "ios"
    refute_received {:delivered, _, _}
  end

  test "native OAuth observation completes once and retains independent continuation authentication" do
    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, enabled: false)
    {:ok, attempt} = Comma.GoogleAuth.start_attempt(%{"platform" => "ios"})
    credential = "observe-google"
    email = "observe-google@example.test"

    SystemsRuntime.Test.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => %{
        "iss" => "https://accounts.google.com",
        "sub" => "observe-google-subject",
        "email" => email,
        "email_verified" => true,
        "aud" => attempt["client_id"],
        "nonce" => attempt["nonce"]
      }
    })

    initial =
      post(
        "/v1/comma/auth/google",
        Map.merge(attempt, %{
          "credential" => credential,
          "native_proof" => true,
          "client_kind" => "ios",
          "client_platform" => "ios"
        })
      )

    assert initial.status == 428
    initial = body(initial)
    assert initial["challenge"]["enforce"] == false

    attrs = %{
      "registration_continuation" => initial["registration_continuation"],
      "native_proof" => true,
      "abuse" => Evidence.evidence(initial["challenge"])
    }

    response = post("/v1/comma/auth/registration/complete", attrs)
    assert response.status == 200
    assert {:ok, user, _session} = Comma.Accounts.validate_session(body(response)["token"])
    assert user["email"] == email
    assert Repo.get!(AuthSession, body(response)["session_id"]).client_kind == "ios"
    assert post("/v1/comma/auth/registration/complete", attrs).status == 401
    refute_received {:delivered, _, _}
  end

  test "email evidence is single-use and target-bound, and OTP completion needs no second proof" do
    email = "protected-email@example.test"
    first = post("/v1/comma/auth/email/login", %{"email" => email})
    assert first.status == 428
    first = body(first)
    assert first["challenge"]["enforce"] == true
    refute_received {:delivered, _, _}
    assert {:error, :not_found} = Comma.Accounts.Repository.get_user_by_email(email)
    proof = Evidence.evidence(first["challenge"])

    assert post("/v1/comma/auth/email/login", %{"email" => "other@example.test", "abuse" => proof}).status ==
             401

    assert post("/v1/comma/auth/email/login", %{"email" => email, "abuse" => proof}).status == 401
    refute_received {:delivered, _, _}

    challenge =
      post("/v1/comma/auth/email/login", %{"email" => email}) |> body() |> Map.fetch!("challenge")

    proof = Evidence.evidence(challenge)
    sent = post("/v1/comma/auth/email/login", %{"email" => email, "abuse" => proof})
    assert sent.status == 200
    sent = body(sent)
    refute Map.has_key?(sent, "code")
    assert_received {:delivered, ^email, code}
    assert post("/v1/comma/auth/email/login", %{"email" => email, "abuse" => proof}).status == 401

    session =
      post("/v1/comma/auth/email/verify", %{
        "challenge_id" => sent["challenge_id"],
        "code" => code
      })

    assert session.status == 200
    assert %User{signup_credit_eligible: true} = Repo.get!(User, body(session)["user"]["id"])
  end

  test "missing hosted dependency fails only protected actions and self-hosted keeps its existing login" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "kept-session@example.test"})
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    SystemsRuntime.Test.put_env(:comma_core, :auth_abuse, enabled: true)
    response = post("/v1/comma/auth/email/login", %{"email" => "missing-dependency@example.test"})
    assert response.status == 503
    assert body(response)["error"] == "auth_abuse_unavailable"
    assert get("/v1/comma/auth/session", session["token"]).status == 200
    refute_received {:delivered, _, _}
    SystemsRuntime.Test.put_env(:comma_core, :selfhost, true)
    assert post("/v1/comma/auth/email/login", %{"email" => "selfhost@example.test"}).status == 200
    assert_received {:delivered, "selfhost@example.test", _}
  end

  test "a new Google user keeps verified claims through failed native evidence and CAPTCHA, while returning login stays independent" do
    email = "protected-google@gmail.com"
    {:ok, attempt} = Comma.GoogleAuth.start_attempt(%{"platform" => "ios"})
    credential = "local-google-credential"

    claims = %{
      "iss" => "https://accounts.google.com",
      "sub" => "protected-google-subject",
      "email" => email,
      "email_verified" => true,
      "aud" => attempt["client_id"],
      "nonce" => attempt["nonce"]
    }

    SystemsRuntime.Test.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => claims
    })

    config = SystemsRuntime.fetch_env!(:comma_core, :auth_abuse)

    SystemsRuntime.Test.put_env(
      :comma_core,
      :auth_abuse,
      Keyword.put(config, :apple, app_id: "TEAMID.surf.comma.ios", environment: "production")
    )

    initial =
      post(
        "/v1/comma/auth/google",
        Map.merge(attempt, %{
          "credential" => credential,
          "client_kind" => "ios",
          "client_platform" => "ios"
        })
      )

    assert initial.status == 428
    initial = body(initial)
    assert initial["challenge"]["method"] == "native"
    assert {:error, :not_found} = Comma.Accounts.Repository.get_user_by_email(email)

    retry =
      post("/v1/comma/auth/registration/complete", %{
        "registration_continuation" => initial["registration_continuation"],
        "abuse" => Evidence.evidence(initial["challenge"])
      })

    assert retry.status == 428
    retry = body(retry)
    assert retry["registration_continuation"] == initial["registration_continuation"]
    assert retry["challenge"]["method"] == "captcha"
    proof = Evidence.evidence(retry["challenge"])

    assert post("/v1/comma/auth/registration/complete", %{
             "registration_continuation" => "malformed",
             "abuse" => proof
           }).status == 401

    complete =
      post("/v1/comma/auth/registration/complete", %{
        "registration_continuation" => retry["registration_continuation"],
        "abuse" => proof,
        "client_kind" => "electron",
        "client_platform" => "linux"
      })

    assert complete.status == 200
    complete = body(complete)
    assert Repo.get!(AuthSession, complete["session_id"]).client_kind == "ios"

    assert post("/v1/comma/auth/registration/complete", %{
             "registration_continuation" => retry["registration_continuation"],
             "abuse" => proof
           }).status == 401

    refute_received {:delivered, _, _}

    SystemsRuntime.Test.delete_env(:comma_core, :auth_abuse)
    {:ok, next} = Comma.GoogleAuth.start_attempt(%{"platform" => "web"})

    SystemsRuntime.Test.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => Map.merge(claims, %{"nonce" => next["nonce"], "aud" => next["client_id"]})
    })

    returning = post("/v1/comma/auth/google", Map.put(next, "credential", credential))
    assert returning.status == 200
    assert body(returning)["user"]["id"] == complete["user"]["id"]
  end

  test "a peer-created account requires linking under the original OAuth peer limit" do
    email = "concurrent-oauth@example.test"
    {:ok, attempt} = Comma.GoogleAuth.start_attempt(%{"platform" => "web"})
    credential = "concurrent-oauth-credential"

    SystemsRuntime.Test.put_env(:comma_core, :google_adapter_fake_credentials, %{
      credential => %{
        "iss" => "https://accounts.google.com",
        "sub" => "concurrent-oauth-subject",
        "email" => email,
        "email_verified" => true,
        "aud" => attempt["client_id"],
        "nonce" => attempt["nonce"]
      }
    })

    auth = SystemsRuntime.fetch_env!(:comma_core, :auth)
    SystemsRuntime.Test.put_env(:comma_core, :auth, Keyword.put(auth, :ip_request_limit, 1))

    initial =
      post("/v1/comma/auth/google", Map.put(attempt, "credential", credential), {198, 51, 100, 7})

    assert initial.status == 428
    initial = body(initial)
    # The account appeared after verified classification, before CAPTCHA completion.
    {:ok, _} = Comma.Accounts.create_user(%{"email" => email})

    complete =
      post(
        "/v1/comma/auth/registration/complete",
        %{
          "registration_continuation" => initial["registration_continuation"],
          "abuse" => Evidence.evidence(initial["challenge"]),
          "remote_ip" => "client-spoof"
        },
        {198, 51, 100, 8}
      )

    assert complete.status == 200
    assert body(complete)["status"] == "otp_required"
    assert_received {:delivered, ^email, _}
    {:ok, other} = Comma.Accounts.create_user(%{"email" => "other-link@example.test"})

    link = %{
      "user_id" => other["id"],
      "issuer" => "https://accounts.google.com",
      "subject" => "another-subject",
      "email" => other["email"],
      "email_verified" => true
    }

    assert {:error, :rate_limited, _} =
             Comma.AuthChallenges.request_google_link_verification(
               Map.put(link, "remote_ip", "198.51.100.7")
             )

    assert {:ok, _} =
             Comma.AuthChallenges.request_google_link_verification(
               Map.put(link, "remote_ip", "198.51.100.8")
             )
  end

  test "the CAPTCHA page is a public resource without a Session transport or attempt credential" do
    conn =
      Plug.Test.conn(:get, "/v1/comma/auth/captcha?challenge_id=abuse_public&action=email_login")
      |> CommaWeb.Router.call(CommaWeb.Router.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "set-cookie") == []
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute conn.resp_body =~ "challenge_secret"
    refute conn.resp_body =~ "registration_continuation"

    assert Plug.Test.conn(
             :get,
             "/v1/comma/auth/captcha?challenge_id=abuse_public&action=email_login&secret=wrong"
           )
           |> CommaWeb.Router.call(CommaWeb.Router.init([]))
           |> Map.fetch!(:status) == 400
  end

  defp post(path, attrs, peer \\ {127, 0, 0, 1}) do
    Plug.Test.conn(:post, path, Jason.encode!(attrs))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-comma-session-transport", "bearer")
    |> Map.put(:remote_ip, peer)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  defp get(path, token) do
    Plug.Test.conn(:get, path)
    |> put_req_header("x-comma-session-transport", "bearer")
    |> put_req_header("authorization", "Bearer " <> token)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)
end
