defmodule Comma.AuthChallengesHardeningTest do
  use Comma.DataCase, async: false

  import ExUnit.CaptureLog

  alias Comma.Accounts.Email
  alias Comma.Auth.GoogleLoginAttempts
  alias Comma.AuthChallenges

  setup do
    previous_auth = Application.get_env(:comma_core, :auth)
    previous_delivery_pid = Application.get_env(:comma_core, :email_delivery_test_pid)
    previous_delivery_result = Application.get_env(:comma_core, :email_delivery_test_result)

    Application.put_env(:comma_core, :auth,
      challenge_store: Comma.AuthChallengeStore.Memory,
      email_delivery: __MODULE__.RecordingDelivery,
      secret: "comma-hardening-test-secret",
      rate_limit_secret: "comma-hardening-rate-limit-secret",
      challenge_ttl_seconds: 900,
      max_attempts: 5,
      session_ttl_seconds: 3600,
      auto_create_users: true,
      resend_cooldown_seconds: 0,
      email_request_limit: 100,
      ip_request_limit: 100,
      verification_failure_limit: 100,
      provider_failure_threshold: 100,
      expose_codes: false
    )

    Application.put_env(:comma_core, :email_delivery_test_pid, self())
    Application.put_env(:comma_core, :email_delivery_test_result, :ok)
    Comma.AuthChallengeStore.Memory.reset!()

    on_exit(fn ->
      restore_env(:comma_core, :auth, previous_auth)
      restore_env(:comma_core, :email_delivery_test_pid, previous_delivery_pid)
      restore_env(:comma_core, :email_delivery_test_result, previous_delivery_result)
      Comma.AuthChallengeStore.Memory.reset!()
    end)

    :ok
  end

  test "definitive provider rejection deletes the undelivered challenge" do
    Application.put_env(
      :comma_core,
      :email_delivery_test_result,
      {:error, {:postmark, 422, 300}}
    )

    assert {:error, :email_delivery_unavailable} =
             AuthChallenges.request_email_login(%{
               "email" => "rejected@example.com",
               "remote_ip" => "203.0.113.10"
             })

    assert_receive {:login_code_delivery, "rejected@example.com", code, challenge_id,
                    "email_login"}

    assert {:error, :invalid_verification_code} =
             AuthChallenges.verify_email_login(%{
               "challenge_id" => challenge_id,
               "code" => code
             })
  end

  test "missing dedicated secrets fail without falling back to the admin credential" do
    current = Application.fetch_env!(:comma_core, :auth)

    Application.put_env(:comma_core, :auth, Keyword.put(current, :secret, nil))

    assert {:error, :auth_not_configured} =
             AuthChallenges.request_email_login(%{"email" => "missing-secret@example.com"})

    Application.put_env(
      :comma_core,
      :auth,
      current |> Keyword.put(:secret, "dedicated-secret") |> Keyword.put(:rate_limit_secret, nil)
    )

    assert {:error, :auth_not_configured} =
             AuthChallenges.request_email_login(%{"email" => "missing-rate-secret@example.com"})

    refute_receive {:login_code_delivery, _email, _code, _challenge_id, _purpose}
  end

  test "Google attempt reservations atomically enforce the shared peer window" do
    current = Application.fetch_env!(:comma_core, :auth)

    Application.put_env(
      :comma_core,
      :auth,
      current
      |> Keyword.put(:ip_request_limit, 5)
      |> Keyword.put(:ip_request_window_seconds, 60)
    )

    results =
      1..16
      |> Enum.map(fn _index ->
        Task.async(fn ->
          GoogleLoginAttempts.create("web", %{"remote_ip" => "203.0.113.20"})
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, %{"attempt_id" => "gla_" <> _}}, &1)) == 5

    assert Enum.count(results, &match?({:error, :rate_limited, _retry_after}, &1)) ==
             11

    assert {:ok, %{"platform" => "web"}} =
             GoogleLoginAttempts.create("web", %{"remote_ip" => "203.0.113.21"})
  end

  test "Electron Google attempts fail before browser launch when exchange credentials are incomplete" do
    previous_google_auth = Application.fetch_env!(:comma_core, :google_auth)

    on_exit(fn -> Application.put_env(:comma_core, :google_auth, previous_google_auth) end)

    Application.put_env(
      :comma_core,
      :google_auth,
      Keyword.delete(previous_google_auth, :electron_client_secret)
    )

    assert {:error, :google_not_configured} =
             GoogleLoginAttempts.create("electron", %{"remote_ip" => "203.0.113.22"})

    assert {:ok, %{"platform" => "web"}} =
             GoogleLoginAttempts.create("web", %{"remote_ip" => "203.0.113.22"})
  end

  test "email challenges share the bounded account email normalization" do
    overlong_email = String.duplicate("a", 309) <> "@example.com"

    assert byte_size(overlong_email) == 321

    assert {:error, :invalid_email} =
             AuthChallenges.request_email_login(%{"email" => overlong_email})

    refute_receive {:login_code_delivery, _email, _code, _challenge_id, _purpose}
  end

  test "OTP recipient normalization preserves aliases and enforces Postmark mailbox bounds" do
    max_local_part = String.duplicate("a", 64)
    max_domain_label = String.duplicate("b", 63)

    max_recipient_domain =
      Enum.join([max_domain_label, max_domain_label, String.duplicate("c", 61)], ".")

    max_recipient = max_local_part <> "@" <> max_recipient_domain

    overlong_recipient_domain =
      Enum.join([max_domain_label, max_domain_label, String.duplicate("c", 62)], ".")

    overlong_recipient = max_local_part <> "@" <> overlong_recipient_domain

    assert byte_size(max_recipient) == 254
    assert byte_size(overlong_recipient) == 255

    valid_cases = [
      {"plus/dot aliases and a hyphenated domain", " User.Name+tag@Sub-Domain.Example.COM ",
       "user.name+tag@sub-domain.example.com"},
      {"Postmark-supported mailbox punctuation", "o'connor_tag/ops=1@example.com",
       "o'connor_tag/ops=1@example.com"},
      {"maximum recipient length", max_recipient, max_recipient}
    ]

    for {case_name, input, normalized} <- valid_cases do
      assert {:ok, ^normalized} = Email.normalize_recipient(input), case_name
    end

    invalid_cases = [
      {"empty local part", "@example.com"},
      {"leading local dot", ".leading@example.com"},
      {"trailing local dot", "trailing.@example.com"},
      {"consecutive local dots", "double..dot@example.com"},
      {"Postmark-unsupported question mark", "question?mark@example.com"},
      {"quoted local part", "\"quoted\"@example.com"},
      {"non-ASCII local part", "josé@example.com"},
      {"65-byte local part", String.duplicate("a", 65) <> "@example.com"},
      {"255-byte recipient", overlong_recipient},
      {"empty domain label", "user@example..com"},
      {"leading domain-label hyphen", "user@-leading.example.com"},
      {"trailing domain-label hyphen", "user@trailing-.example.com"},
      {"non-host domain character", "user@bad_domain.example.com"},
      {"64-byte domain label", "user@" <> String.duplicate("a", 64) <> ".example.com"}
    ]

    for {case_name, email} <- invalid_cases do
      assert {:error, :invalid_email} = Email.normalize_recipient(email), case_name
    end

    assert {:ok, "josé@example.com"} = Email.normalize(" José@Example.COM ")
  end

  test "both OTP request entry points reject unsupported recipients before delivery" do
    invalid_recipient = "double..dot@example.com"

    assert {:error, :invalid_email} =
             AuthChallenges.request_email_login(%{"email" => invalid_recipient})

    assert {:error, :invalid_email} =
             AuthChallenges.request_google_link_verification(%{
               "email" => invalid_recipient,
               "user_id" => "usr_recipient_validation"
             })

    refute_receive {:login_code_delivery, _email, _code, _challenge_id, _purpose}
  end

  test "login and Google-link challenges pass distinct purposes to delivery" do
    assert {:ok, %{"challenge_id" => login_challenge_id}} =
             AuthChallenges.request_email_login(%{"email" => "login-purpose@example.com"})

    assert_receive {:login_code_delivery, "login-purpose@example.com", _login_code,
                    ^login_challenge_id, "email_login"}

    assert {:ok, %{"challenge_id" => link_challenge_id, "status" => "otp_required"}} =
             AuthChallenges.request_google_link_verification(%{
               "email" => "link-purpose@example.com",
               "user_id" => "usr_link_purpose",
               "issuer" => "https://accounts.google.com",
               "subject" => "link-purpose-subject",
               "email_verified" => true
             })

    assert_receive {:login_code_delivery, "link-purpose@example.com", _link_code,
                    ^link_challenge_id, "google_link"}
  end

  test "ambiguous transport failure is not retried and leaves one bounded challenge usable" do
    Application.put_env(
      :comma_core,
      :email_delivery_test_result,
      {:error, {:transport, :closed}}
    )

    assert {:ok, %{"challenge_id" => challenge_id} = response} =
             AuthChallenges.request_email_login(%{
               "email" => "ambiguous@example.com",
               "remote_ip" => "203.0.113.11"
             })

    refute Map.has_key?(response, "code")

    assert_receive {:login_code_delivery, "ambiguous@example.com", code, ^challenge_id,
                    "email_login"}

    refute_receive {:login_code_delivery, "ambiguous@example.com", _other_code, ^challenge_id,
                    _purpose}

    assert {:ok, %{"user" => %{"email" => "ambiguous@example.com"}}} =
             AuthChallenges.verify_email_login(%{
               "challenge_id" => challenge_id,
               "code" => code
             })
  end

  test "auth dependency telemetry contains only bounded operation metadata" do
    handler_id = "comma-auth-redaction-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:comma_product, :operation, :stop],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    email = "telemetry-secret@example.com"

    assert {:ok, %{"challenge_id" => challenge_id}} =
             AuthChallenges.request_email_login(%{
               "email" => email,
               "remote_ip" => "198.51.100.7"
             })

    assert_receive {:login_code_delivery, ^email, code, ^challenge_id, "email_login"}

    events =
      for _index <- 1..3 do
        assert_receive {:auth_telemetry, [:comma_product, :operation, :stop], measurements,
                        metadata}

        assert is_integer(measurements.duration)
        metadata
      end

    assert Enum.any?(events, &(&1.operation == :email_delivery and &1.provider == "other"))
    assert Enum.count(events, &(&1.operation == :redis_challenge)) == 2

    for metadata <- events do
      assert Enum.sort(Map.keys(metadata)) == [:operation, :outcome, :provider]
      serialized = inspect(metadata)
      refute serialized =~ email
      refute serialized =~ code
      refute serialized =~ challenge_id
    end
  end

  test "development Logger records neither email nor code" do
    log =
      capture_log(fn ->
        assert :ok =
                 Comma.EmailDelivery.Logger.send_login_code(
                   "log-secret@example.com",
                   "123456",
                   %{challenge_id: "comma_auth_safe_id"}
                 )
      end)

    assert log =~ "Comma login verification code generated"
    refute log =~ "log-secret@example.com"
    refute log =~ "123456"
  end

  defmodule RecordingDelivery do
    @behaviour Comma.EmailDelivery

    @impl true
    def send_login_code(email, code, opts) do
      send(
        Application.fetch_env!(:comma_core, :email_delivery_test_pid),
        {:login_code_delivery, email, code, opts[:challenge_id], opts[:purpose]}
      )

      Application.fetch_env!(:comma_core, :email_delivery_test_result)
    end
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:auth_telemetry, event, measurements, metadata})
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
