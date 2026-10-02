defmodule Comma.GoogleAuthTest do
  use Comma.DataCase, async: false

  @moduletag database_isolation: "SERIALIZABLE"
  @serializable_statement "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
  @desktop_code_verifier String.duplicate("v", 43)
  @desktop_redirect_uri "http://127.0.0.1:43123/oauth2/callback"
  @android_client_id "comma-android-test.apps.googleusercontent.com"

  alias Comma.Accounts.{AuthSession, Identity, Repository, User}
  alias Comma.Auth.GoogleClaims
  alias Comma.{Accounts, AuthChallenges, GoogleAuth}

  setup do
    previous_credentials = Application.get_env(:comma_core, :google_adapter_fake_credentials)
    Comma.AuthChallengeStore.Memory.reset!()

    on_exit(fn ->
      restore_env(:comma_core, :google_adapter_fake_credentials, previous_credentials)
      Comma.AuthChallengeStore.Memory.reset!()
    end)

    :ok
  end

  @tag sandbox: false
  test "concurrent first OTP and Google authentication converge on one account" do
    email = "auth-race-#{System.unique_integer([:positive])}@gmail.com"
    subject = "concurrent-google-subject"

    on_exit(fn -> with_unboxed_repo(fn -> delete_account_by_email(email) end) end)

    assert {:ok, %{"challenge_id" => challenge_id, "code" => code}} =
             AuthChallenges.request_email_login(%{"email" => email})

    assert {:ok, attempt} = GoogleAuth.start_attempt(%{"platform" => "web"})
    credential = "concurrent-google-credential"

    put_credentials(%{
      credential => claims(subject, email, true, nil, attempt)
    })

    parent = self()
    telemetry_handler_id = "google-auth-serialization-query-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_handler_id,
        [:comma, :repo, :query],
        &__MODULE__.capture_serializable_query/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(telemetry_handler_id) end)

    otp_task =
      Task.async(fn ->
        with_unboxed_repo(fn ->
          [[backend_pid]] = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows

          Repo.transaction(fn ->
            result =
              AuthChallenges.verify_email_login(%{
                "challenge_id" => challenge_id,
                "code" => code
              })

            send(parent, {:otp_pending_commit, self(), backend_pid, result})

            receive do
              :commit_otp -> result
            after
              10_000 -> raise "timed out waiting to commit the OTP authentication"
            end
          end)
        end)
      end)

    on_exit(fn ->
      send(otp_task.pid, :commit_otp)

      if Process.alive?(otp_task.pid) do
        Process.exit(otp_task.pid, :kill)
      end
    end)

    assert_receive {:otp_pending_commit, otp_owner, otp_backend_pid, {:ok, _session}}, 5_000

    google_task =
      Task.async(fn ->
        with_unboxed_repo(fn ->
          [[backend_pid]] = Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows
          send(parent, {:google_backend_pid, backend_pid})
          GoogleAuth.complete(complete_attrs(attempt, credential))
        end)
      end)

    on_exit(fn ->
      if Process.alive?(google_task.pid) do
        Process.exit(google_task.pid, :kill)
      end
    end)

    assert_receive {:google_backend_pid, google_backend_pid}, 5_000
    assert_google_blocked_after_identity_lock!(google_backend_pid, otp_backend_pid)

    send(otp_owner, :commit_otp)
    assert {:ok, otp_result} = Task.await(otp_task, 5_000)
    google_result = Task.await(google_task, 10_000)

    assert {:ok, otp_session} = otp_result
    assert {:ok, google_session} = google_result
    assert otp_session["user"]["id"] == google_session["user"]["id"]

    assert_receive :google_serializable_transaction_started, 1_000
    assert_receive {:google_serialization_failure, failed_query}, 1_000
    assert failed_query =~ ~s(INSERT INTO "comma_users")
    assert_receive :google_serializable_transaction_started, 1_000
    refute_receive :google_serializable_transaction_started, 100
    refute_receive {:google_serialization_failure, _query}, 100

    assert {:error, :invalid_google_attempt} =
             GoogleAuth.complete(complete_attrs(attempt, credential))

    with_unboxed_repo(fn ->
      user_id = otp_session["user"]["id"]

      assert Repo.aggregate(from(user in User, where: user.email == ^email), :count) == 1

      assert Repo.aggregate(
               from(identity in Identity, where: identity.user_id == ^user_id),
               :count
             ) == 1

      assert Repo.aggregate(
               from(session in AuthSession, where: session.user_id == ^user_id),
               :count
             ) == 2

      assert %Identity{subject: ^subject} =
               Repo.one!(from(identity in Identity, where: identity.user_id == ^user_id))
    end)
  end

  test "new Google login creates one user and stable subject survives an email change" do
    assert {:ok, first_session} =
             google_login("new-subject", "first@example.com", true, "example.com")

    assert first_session["user"]["email"] == "first@example.com"
    assert "comma_sess_" <> _ = first_session["token"]
    user_id = first_session["user"]["id"]

    assert {:ok, second_session} =
             google_login("new-subject", "renamed@example.com", true, "example.com")

    assert second_session["user"]["id"] == user_id
    assert second_session["user"]["email"] == "first@example.com"

    assert Repo.aggregate(
             from(user in User,
               where: user.email in ["first@example.com", "renamed@example.com"]
             ),
             :count
           ) == 1

    identity = Repo.one!(from(identity in Identity, where: identity.user_id == ^user_id))
    assert identity.subject == "new-subject"
    assert identity.email_snapshot == "renamed@example.com"
  end

  test "optional Google display names share the User 200-character boundary without blocking signup" do
    accepted_name = String.duplicate("名", 200)
    ignored_name = String.duplicate("名", 201)

    assert {:ok, accepted} =
             google_login_with_name(
               "accepted-name-subject",
               "accepted-name@example.com",
               accepted_name
             )

    assert accepted["user"]["name"] == accepted_name

    assert {:ok, ignored} =
             google_login_with_name(
               "ignored-name-subject",
               "ignored-name@example.com",
               ignored_name
             )

    assert ignored["user"]["name"] == nil
    assert Repo.get!(User, ignored["user"]["id"]).name == nil
  end

  test "exact verified Gmail and Workspace claims auto-link an existing OTP user" do
    for {email, subject, hosted_domain} <- [
          {"same@gmail.com", "gmail-subject", nil},
          {"same@workspace.example", "workspace-subject", "workspace.example"}
        ] do
      assert {:ok, existing} = Repository.ensure_user_by_email(email)

      assert {:ok, session} = google_login(subject, email, true, hosted_domain)
      assert session["user"]["id"] == existing.id

      assert %Identity{user_id: user_id, subject: ^subject} =
               Repo.get_by!(Identity, provider: "google", subject: subject)

      assert user_id == existing.id
    end
  end

  test "third-party exact email requires one bound OTP before linking" do
    email = "third-party@example.com"
    assert {:ok, existing} = Repository.ensure_user_by_email(email)

    assert {:ok, pending} = google_login("third-party-subject", email, true, nil)
    assert pending["status"] == "otp_required"
    assert is_binary(pending["challenge_id"])
    assert is_binary(pending["code"])
    assert Repo.aggregate(Identity, :count) == 0

    assert {:error, :invalid_verification_code} =
             AuthChallenges.verify_email_login(%{
               "challenge_id" => pending["challenge_id"],
               "code" => pending["code"]
             })

    assert {:error, :invalid_verification_code} =
             GoogleAuth.verify_link(%{
               "challenge_id" => pending["challenge_id"],
               "code" => wrong_code(pending["code"])
             })

    assert {:ok, session} =
             GoogleAuth.verify_link(%{
               "challenge_id" => pending["challenge_id"],
               "code" => pending["code"]
             })

    assert session["user"]["id"] == existing.id
    assert %Identity{user_id: user_id, subject: "third-party-subject"} = Repo.one!(Identity)
    assert user_id == existing.id

    assert {:error, :invalid_verification_code} =
             GoogleAuth.verify_link(%{
               "challenge_id" => pending["challenge_id"],
               "code" => pending["code"]
             })
  end

  test "OTP link state does not retain the unused Google display name" do
    assert {:ok, claims} =
             GoogleClaims.from_verified(%{
               "iss" => "https://accounts.google.com",
               "sub" => "link-state-subject",
               "email" => "link-state@example.com",
               "email_verified" => true,
               "name" => "Transient Google Name"
             })

    state = GoogleClaims.link_state(claims, "usr_link_state")
    refute Map.has_key?(state, "name")

    assert {:ok, restored} = GoogleClaims.from_link_state(state)
    assert restored.name == nil
  end

  test "false or malformed email_verified never creates a new account" do
    rejected = [{"false-verified", false}, {"bad-verified", "true"}]

    for {subject, verified} <- rejected do
      assert {:error, :invalid_google_identity} =
               google_login(subject, "untrusted-#{subject}@example.com", verified, nil)
    end

    rejected_emails =
      Enum.map(rejected, fn {subject, _verified} -> "untrusted-#{subject}@example.com" end)

    rejected_subjects = Enum.map(rejected, &elem(&1, 0))

    assert Repo.aggregate(from(user in User, where: user.email in ^rejected_emails), :count) == 0

    assert Repo.aggregate(
             from(identity in Identity, where: identity.subject in ^rejected_subjects),
             :count
           ) == 0
  end

  test "web and Electron audience, nonce, and attempt replay fail closed" do
    for {platform, expected_client_id} <- [
          {"web", "comma-web-test.apps.googleusercontent.com"},
          {"electron", "comma-electron-test.apps.googleusercontent.com"}
        ] do
      assert {:ok, attempt} = GoogleAuth.start_attempt(%{"platform" => platform})
      assert attempt["platform"] == platform
      assert attempt["client_id"] == expected_client_id

      claims =
        claims("replay-#{platform}", "replay-#{platform}@example.com", true, nil, attempt)

      put_credentials(%{"bad-audience" => Map.put(claims, "aud", "other-client")})

      assert {:error, :invalid_google_credential} =
               GoogleAuth.complete(complete_attrs(attempt, "bad-audience"))

      put_credentials(%{"valid-after-consume" => claims})

      assert {:error, :invalid_google_attempt} =
               GoogleAuth.complete(complete_attrs(attempt, "valid-after-consume"))

      assert {:ok, nonce_attempt} = GoogleAuth.start_attempt(%{"platform" => platform})

      nonce_claims =
        claims(
          "nonce-#{platform}",
          "nonce-#{platform}@example.com",
          true,
          nil,
          nonce_attempt
        )
        |> Map.put("nonce", "wrong-nonce")

      put_credentials(%{"bad-nonce" => nonce_claims})

      assert {:error, :invalid_google_credential} =
               GoogleAuth.complete(complete_attrs(nonce_attempt, "bad-nonce"))
    end
  end

  test "Android ID tokens use the web audience and require an authorized Android party" do
    assert {:ok, attempt} = GoogleAuth.start_attempt(%{"platform" => "android"})
    assert attempt["platform"] == "android"
    assert "gla_android_" <> _ = attempt["attempt_id"]
    assert attempt["client_id"] == "comma-web-test.apps.googleusercontent.com"

    android_claims = fn subject, email, attempt ->
      subject
      |> claims(email, true, nil, attempt)
      |> Map.put("azp", @android_client_id)
    end

    put_credentials(%{
      "android-unauthorized-party" =>
        android_claims.("android-subject", "android@gmail.com", attempt)
        |> Map.put("azp", "comma-web-test.apps.googleusercontent.com")
    })

    assert {:error, :invalid_google_credential} =
             GoogleAuth.complete(complete_attrs(attempt, "android-unauthorized-party"))

    assert {:ok, attempt} = GoogleAuth.start_attempt(%{"platform" => "android"})

    put_credentials(%{
      "android-missing-party" =>
        android_claims.("android-subject", "android@gmail.com", attempt) |> Map.delete("azp")
    })

    assert {:error, :invalid_google_credential} =
             GoogleAuth.complete(complete_attrs(attempt, "android-missing-party"))

    assert {:ok, attempt} = GoogleAuth.start_attempt(%{"platform" => "android"})

    put_credentials(%{
      "android-credential" => android_claims.("android-subject", "android@gmail.com", attempt)
    })

    assert {:ok, session} =
             GoogleAuth.complete(
               attempt
               |> complete_attrs("android-credential")
               |> Map.merge(%{"client_kind" => "android", "client_platform" => "android"})
             )

    assert session["user"]["email"] == "android@gmail.com"
    stored_session = Repo.get!(AuthSession, session["session_id"])
    assert stored_session.auth_method == "google"
    assert stored_session.client_kind == "android"
    assert stored_session.client_platform == "android"
    assert stored_session.device_label == "Comma Android app"
  end

  test "Android Google login is unavailable until an Android client is configured" do
    previous = Application.get_env(:comma_core, :google_auth)
    on_exit(fn -> Application.put_env(:comma_core, :google_auth, previous) end)

    Application.put_env(
      :comma_core,
      :google_auth,
      Keyword.put(previous, :android_client_ids, [])
    )

    assert {:error, :google_not_configured} =
             GoogleAuth.start_attempt(%{"platform" => "android"})

    assert {:ok, _attempt} = GoogleAuth.start_attempt(%{"platform" => "web"})
  end

  test "Electron completion rejects a web credential without consuming its attempt" do
    assert {:ok, attempt} = GoogleAuth.start_attempt(%{"platform" => "electron"})
    authorization_code = "electron-shape-bound-code"

    put_credentials(%{
      authorization_code =>
        claims(
          "electron-shape-bound-subject",
          "electron-shape-bound@example.com",
          true,
          nil,
          attempt
        )
    })

    assert {:error, :invalid_google_attempt} =
             GoogleAuth.complete(%{
               "attempt_id" => attempt["attempt_id"],
               "nonce" => attempt["nonce"],
               "credential" => authorization_code
             })

    assert {:ok, session} = GoogleAuth.complete(complete_attrs(attempt, authorization_code))
    assert session["user"]["email"] == "electron-shape-bound@example.com"
  end

  test "Google sessions are revocable ordinary sessions without admin capability" do
    assert {:ok, session} = google_login("session-subject", "session@gmail.com", true, nil)
    refute Map.has_key?(session["user"], "admin")

    assert {:ok, user, stored_session} = Accounts.validate_session(session["token"])
    refute Map.has_key?(user, "admin")
    assert stored_session["auth_method"] == "google"
    assert stored_session["session_source"] == "user_login"

    assert :ok = Accounts.revoke_session_token(session["token"])
    assert {:error, :revoked} = Accounts.validate_session(session["token"])
  end

  test "direct and OTP-linked Google Sessions retain only coarse reported client metadata" do
    assert {:ok, direct_attempt} = GoogleAuth.start_attempt(%{"platform" => "web"})
    direct_credential = "direct-device-credential"

    put_credentials(%{
      direct_credential =>
        claims(
          "direct-device-subject",
          "direct-device@gmail.com",
          true,
          nil,
          direct_attempt
        )
    })

    assert {:ok, direct} =
             GoogleAuth.complete(
               direct_attempt
               |> complete_attrs(direct_credential)
               |> Map.merge(%{
                 "client_kind" => "web",
                 "client_platform" => "windows"
               })
             )

    direct_session = Repo.get!(AuthSession, direct["session_id"])
    assert direct_session.client_kind == "web"
    assert direct_session.device_label == "Web on Windows"

    linked_email = "linked-device@example.com"
    assert {:ok, linked_user} = Repository.ensure_user_by_email(linked_email)
    assert {:ok, link_attempt} = GoogleAuth.start_attempt(%{"platform" => "electron"})
    link_credential = "linked-device-credential"

    put_credentials(%{
      link_credential =>
        claims(
          "linked-device-subject",
          linked_email,
          true,
          nil,
          link_attempt
        )
    })

    assert {:ok, pending} =
             GoogleAuth.complete(
               link_attempt
               |> complete_attrs(link_credential)
               |> Map.merge(%{
                 "client_kind" => "electron",
                 "client_platform" => "macos"
               })
             )

    assert pending["status"] == "otp_required"

    assert {:ok, linked} =
             GoogleAuth.verify_link(%{
               "challenge_id" => pending["challenge_id"],
               "code" => pending["code"]
             })

    assert linked["user"]["id"] == linked_user.id
    linked_session = Repo.get!(AuthSession, linked["session_id"])
    assert linked_session.client_kind == "electron"
    assert linked_session.device_label == "Comma Desktop on macOS"
  end

  defp google_login(subject, email, email_verified, hosted_domain) do
    credential = "credential-#{System.unique_integer([:positive])}"
    assert {:ok, attempt} = GoogleAuth.start_attempt(%{"platform" => "web"})

    put_credentials(%{
      credential => claims(subject, email, email_verified, hosted_domain, attempt)
    })

    GoogleAuth.complete(complete_attrs(attempt, credential))
  end

  defp google_login_with_name(subject, email, name) do
    credential = "credential-#{System.unique_integer([:positive])}"
    assert {:ok, attempt} = GoogleAuth.start_attempt(%{"platform" => "web"})

    put_credentials(%{
      credential =>
        claims(subject, email, true, nil, attempt)
        |> Map.put("name", name)
    })

    GoogleAuth.complete(complete_attrs(attempt, credential))
  end

  defp claims(subject, email, email_verified, hosted_domain, attempt) do
    %{
      "iss" => "https://accounts.google.com",
      "sub" => subject,
      "aud" => attempt["client_id"],
      "nonce" => attempt["nonce"],
      "email" => email,
      "email_verified" => email_verified,
      "hd" => hosted_domain,
      "name" => "Google User"
    }
  end

  defp complete_attrs(%{"platform" => "electron"} = attempt, authorization_code) do
    %{
      "attempt_id" => attempt["attempt_id"],
      "nonce" => attempt["nonce"],
      "authorization_code" => authorization_code,
      "code_verifier" => @desktop_code_verifier,
      "redirect_uri" => @desktop_redirect_uri
    }
  end

  defp complete_attrs(attempt, credential) do
    %{
      "attempt_id" => attempt["attempt_id"],
      "nonce" => attempt["nonce"],
      "credential" => credential
    }
  end

  defp put_credentials(credentials) do
    Application.put_env(:comma_core, :google_adapter_fake_credentials, credentials)
  end

  defp wrong_code("000000"), do: "000001"
  defp wrong_code(_code), do: "000000"

  defp with_unboxed_repo(fun) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end
  end

  defp assert_google_blocked_after_identity_lock!(
         google_backend_pid,
         otp_backend_pid,
         attempts \\ 100
       )

  defp assert_google_blocked_after_identity_lock!(_google_backend_pid, _otp_backend_pid, 0) do
    flunk("Google authentication did not reach the controlled post-snapshot conflict")
  end

  defp assert_google_blocked_after_identity_lock!(google_backend_pid, otp_backend_pid, attempts) do
    blocked? =
      with_unboxed_repo(fn ->
        [[blocked?]] =
          Ecto.Adapters.SQL.query!(
            Repo,
            """
            SELECT
              $1::integer = ANY(pg_blocking_pids($2::integer))
              AND EXISTS (
                SELECT 1
                FROM pg_locks
                WHERE pid = $2::integer AND locktype = 'advisory' AND granted
              )
            """,
            [otp_backend_pid, google_backend_pid]
          ).rows

        blocked?
      end)

    if blocked? do
      :ok
    else
      Process.sleep(10)

      assert_google_blocked_after_identity_lock!(
        google_backend_pid,
        otp_backend_pid,
        attempts - 1
      )
    end
  end

  defp delete_account_by_email(email) do
    user_ids = Repo.all(from(user in User, where: user.email == ^email, select: user.id))
    Repo.delete_all(from(session in AuthSession, where: session.user_id in ^user_ids))
    Repo.delete_all(from(identity in Identity, where: identity.user_id in ^user_ids))
    Repo.delete_all(from(user in User, where: user.id in ^user_ids))
    :ok
  end

  def capture_serializable_query(_event, _measurements, metadata, test_pid) do
    case metadata do
      %{query: @serializable_statement} ->
        send(test_pid, :google_serializable_transaction_started)

      %{
        query: query,
        result: {:error, %Postgrex.Error{postgres: %{code: :serialization_failure}}}
      } ->
        send(test_pid, {:google_serialization_failure, query})

      _other ->
        :ok
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
