defmodule Comma.AuthChallengesHardeningTest do
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma"]

  import ExUnit.CaptureLog

  alias Comma.AuthChallenges

  setup do
    previous_auth = SystemsRuntime.get_env(:comma_core, :auth)
    previous_delivery_pid = SystemsRuntime.get_env(:comma_core, :email_delivery_test_pid)
    previous_delivery_result = SystemsRuntime.get_env(:comma_core, :email_delivery_test_result)

    SystemsRuntime.put_env(:comma_core, :auth,
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

    SystemsRuntime.put_env(:comma_core, :email_delivery_test_pid, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:comma_core, :email_delivery_test_result, :ok)
    Comma.AuthChallengeStore.Memory.reset!()

    on_exit(fn ->
      restore_env(:comma_core, :auth, previous_auth)
      restore_env(:comma_core, :email_delivery_test_pid, previous_delivery_pid)
      restore_env(:comma_core, :email_delivery_test_result, previous_delivery_result)
      Comma.AuthChallengeStore.Memory.reset!()
    end)

    :ok
  end

  test "missing dedicated secrets fail without falling back to the admin credential" do
    current = SystemsRuntime.fetch_env!(:comma_core, :auth)

    SystemsRuntime.put_env(:comma_core, :auth, Keyword.put(current, :secret, nil))

    assert {:error, :auth_not_configured} =
             AuthChallenges.request_email_login(%{"email" => "missing-secret@example.com"})

    SystemsRuntime.put_env(
      :comma_core,
      :auth,
      current |> Keyword.put(:secret, "dedicated-secret") |> Keyword.put(:rate_limit_secret, nil)
    )

    assert {:error, :auth_not_configured} =
             AuthChallenges.request_email_login(%{"email" => "missing-rate-secret@example.com"})

    settle_refute_receive({:login_code_delivery, _email, _code, _challenge_id, _purpose})
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

  test "fixed review login also works with the local memory store without email delivery" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "review-memory@example.test"})
    {:ok, _} = Comma.Admin.set_admin_access(user["id"], "deny", :ops, "Demo account")
    assert {:ok, _} = Comma.Admin.update_user(user["id"], %{"review_login_code" => "037291"})

    for _ <- 1..2 do
      assert {:ok, challenge} = AuthChallenges.request_email_login(%{"email" => user["email"]})

      assert {:ok, session} =
               AuthChallenges.verify_email_login(Map.put(challenge, "code", "037291"))

      assert session["user"]["id"] == user["id"]
    end

    settle_refute_receive({:login_code_delivery, _email, _code, _challenge_id, _purpose})
  end

  defmodule RecordingDelivery do
    @behaviour Comma.EmailDelivery

    @impl true
    def send_login_code(email, code, opts) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:comma_core, :email_delivery_test_pid),
        {:login_code_delivery, email, code, opts[:challenge_id], opts[:purpose]}
      )

      SystemsRuntime.fetch_env!(:comma_core, :email_delivery_test_result)
    end
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    SystemsRuntime.Proc.send(pid, {:auth_telemetry, event, measurements, metadata})
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
