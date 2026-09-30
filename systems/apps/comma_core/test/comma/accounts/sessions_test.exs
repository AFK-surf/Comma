defmodule Comma.Accounts.SessionsTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts.{AuthSession, Sessions, User}

  setup do
    Comma.AuthChallengeStore.Memory.reset!()
    :ok
  end

  test "Email OTP creates one PostgreSQL user and a hash-only revocable session" do
    email = unique_email("otp")

    assert {:ok, %{"challenge_id" => challenge_id, "code" => code}} =
             Comma.AuthChallenges.request_email_login(%{"email" => "  #{String.upcase(email)} "})

    assert {:ok, %{"token" => token, "user" => user}} =
             Comma.AuthChallenges.verify_email_login(%{
               "challenge_id" => challenge_id,
               "code" => code
             })

    assert user["email"] == email
    refute Map.has_key?(user, "admin")
    assert "comma_sess_" <> _ = token

    stored_user = Repo.get!(User, user["id"])

    stored_session =
      Repo.one!(from(session in AuthSession, where: session.user_id == ^user["id"]))

    assert stored_user.email == email
    assert stored_session.auth_method == "email_otp"
    assert stored_session.session_source == "user_login"
    assert byte_size(stored_session.token_hash) == 32
    refute stored_session.token_hash == token
    refute inspect(stored_session) =~ token

    assert {:ok, validated_user, validated_session} = Comma.Accounts.validate_session(token)
    assert validated_user["id"] == user["id"]
    assert validated_session["id"] == stored_session.id
    refute Map.has_key?(validated_session, "consumed_interaction_ids")
    refute Map.has_key?(validated_session, "token")
    refute Map.has_key?(Sessions.public_session(stored_session), "token")
  end

  test "ordinary login derives finite display metadata and ignores free-form labels" do
    email = unique_email("reported-device")
    {challenge_id, code} = request_code(email)

    assert {:ok, issued} =
             Comma.AuthChallenges.verify_email_login(%{
               "challenge_id" => challenge_id,
               "code" => code,
               "client_kind" => "web",
               "client_platform" => "macos",
               "device_label" => "203.0.113.7"
             })

    stored = Repo.get!(AuthSession, issued["session_id"])
    assert stored.client_kind == "web"
    assert stored.device_label == "Web on macOS"
    refute stored.device_label == "203.0.113.7"

    invalid_email = unique_email("invalid-device")
    {invalid_challenge_id, invalid_code} = request_code(invalid_email)

    assert {:ok, invalid_issued} =
             Comma.AuthChallenges.verify_email_login(%{
               "challenge_id" => invalid_challenge_id,
               "code" => invalid_code,
               "client_kind" => "web",
               "client_platform" =>
                 "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/123",
               "device_label" => "installation-fingerprint-0123456789"
             })

    invalid_stored = Repo.get!(AuthSession, invalid_issued["session_id"])
    assert invalid_stored.client_kind == "web"
    assert invalid_stored.device_label == "Web browser"
    refute inspect(invalid_stored) =~ "Mozilla/5.0"
    refute inspect(invalid_stored) =~ "installation-fingerprint"
  end

  test "OTP replay is rejected and repeated login converges on the same user" do
    email = unique_email("replay")
    {challenge_id, code} = request_code(email)

    assert {:ok, first} = verify_code(challenge_id, code)
    assert {:error, :invalid_verification_code} = verify_code(challenge_id, code)

    {second_challenge_id, second_code} = request_code(email)
    assert {:ok, second} = verify_code(second_challenge_id, second_code)

    assert first["user"]["id"] == second["user"]["id"]
    assert Repo.aggregate(from(user in User, where: user.email == ^email), :count) == 1

    assert Repo.aggregate(
             from(session in AuthSession, where: session.user_id == ^first["user"]["id"]),
             :count
           ) == 2
  end

  test "a session issuance failure after OTP consume never restores the code" do
    email = unique_email("post-consume-failure")
    assert {:ok, user} = Comma.Accounts.create_user(%{"email" => email})
    assert {:ok, _disabled} = Comma.Accounts.update_user(user["id"], %{"status" => "disabled"})
    {challenge_id, code} = request_code(email)

    assert {:error, :disabled} = verify_code(challenge_id, code)

    assert Repo.aggregate(
             from(session in AuthSession, where: session.user_id == ^user["id"]),
             :count
           ) == 0

    assert {:error, :invalid_verification_code} = verify_code(challenge_id, code)
  end

  test "revoke, revoke-all, and disable take effect on the next request" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => unique_email("lifecycle")})
    {:ok, first} = Comma.Accounts.create_session(user["id"])

    assert {:ok, _user, _session} = Comma.Accounts.validate_session(first["token"])
    assert :ok = Comma.Accounts.revoke_session(user["id"], first["id"])
    assert {:error, :revoked} = Comma.Accounts.validate_session(first["token"])

    {:ok, second} = Comma.Accounts.create_session(user["id"])
    {:ok, third} = Comma.Accounts.create_session(user["id"])
    assert {:ok, 2} = Comma.Accounts.revoke_all_sessions(user["id"])
    assert {:error, :revoked} = Comma.Accounts.validate_session(second["token"])
    assert {:error, :revoked} = Comma.Accounts.validate_session(third["token"])

    {:ok, fourth} = Comma.Accounts.create_session(user["id"])
    assert {:ok, disabled} = Comma.Accounts.update_user(user["id"], %{"status" => "disabled"})
    assert disabled["status"] == "disabled"
    assert {:error, :revoked} = Comma.Accounts.validate_session(fourth["token"])
    assert {:error, :disabled} = Comma.Accounts.create_session(user["id"])
  end

  test "resolve is side-effect free and last-seen touch is explicit" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => unique_email("resolve")})
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    old_last_seen = DateTime.add(DateTime.utc_now(), -600) |> DateTime.truncate(:microsecond)

    Repo.update_all(
      from(row in AuthSession, where: row.id == ^session["id"]),
      set: [last_seen_at: old_last_seen, updated_at: old_last_seen]
    )

    assert {:ok, _user, resolved} = Comma.Accounts.resolve_session(session["token"])
    assert resolved["last_seen_at"] == DateTime.to_unix(old_last_seen)
    assert Repo.get!(AuthSession, session["id"]).last_seen_at == old_last_seen

    assert :ok = Comma.Accounts.touch_session(resolved)

    assert DateTime.compare(Repo.get!(AuthSession, session["id"]).last_seen_at, old_last_seen) ==
             :gt
  end

  test "ordinary ops updates cannot change the verified login email" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => unique_email("fixed-email")})

    assert {:error, :email_change_not_supported} =
             Comma.Accounts.update_user(user["id"], %{
               "email" => unique_email("replacement"),
               "name" => "Ignored replacement"
             })

    assert {:ok, stored} = Comma.Accounts.get_user(user["id"])
    assert stored["email"] == user["email"]
    assert stored["name"] == user["name"]

    assert {:ok, renamed} = Comma.Accounts.update_user(user["id"], %{"name" => "Allowed name"})
    assert renamed["name"] == "Allowed name"
    assert renamed["email"] == user["email"]
  end

  test "session list is bounded, cursor based, and never returns credentials" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => unique_email("list")})

    for index <- 1..3 do
      {:ok, _session} =
        Comma.Accounts.create_session(user["id"], device_label: "Device #{index}")
    end

    assert {:ok, first_page} = Comma.Accounts.list_sessions(user["id"], limit: 2)
    assert length(first_page["data"]) == 2
    assert first_page["has_more"]
    assert is_binary(first_page["next_cursor"])
    refute Enum.any?(first_page["data"], &Map.has_key?(&1, "token"))
    refute Enum.any?(first_page["data"], &Map.has_key?(&1, "token_hash"))

    assert {:ok, second_page} =
             Comma.Accounts.list_sessions(user["id"],
               limit: 2,
               cursor: first_page["next_cursor"]
             )

    assert length(second_page["data"]) == 1
    refute second_page["has_more"]
    assert {:error, :invalid_cursor} = Comma.Accounts.list_sessions(user["id"], cursor: "bad")
  end

  test "session pagination clamps to 100 and preserves equal-timestamp rows" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => unique_email("page-boundary")})

    for index <- 1..101 do
      assert {:ok, _session} =
               Comma.Accounts.create_session(user["id"], device_label: "Boundary #{index}")
    end

    shared_timestamp = ~U[2026-07-22 00:00:00.000000Z]

    Repo.update_all(
      from(session in AuthSession, where: session.user_id == ^user["id"]),
      set: [created_at: shared_timestamp, updated_at: shared_timestamp]
    )

    assert {:ok, first_page} = Comma.Accounts.list_sessions(user["id"], limit: 1_000)
    assert length(first_page["data"]) == 100
    assert first_page["has_more"]
    assert is_binary(first_page["next_cursor"])

    assert {:ok, second_page} =
             Comma.Accounts.list_sessions(user["id"],
               limit: 1_000,
               cursor: first_page["next_cursor"]
             )

    assert length(second_page["data"]) == 1
    refute second_page["has_more"]

    all_ids = Enum.map(first_page["data"] ++ second_page["data"], & &1["id"])
    assert length(Enum.uniq(all_ids)) == 101
  end

  test "auth epoch mismatch rejects an otherwise active session" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => unique_email("auth-epoch")})
    {:ok, session} = Comma.Accounts.create_session(user["id"])

    Repo.update_all(
      from(row in User, where: row.id == ^user["id"]),
      inc: [auth_epoch: 1]
    )

    assert {:error, :revoked} = Comma.Accounts.validate_session(session["token"])
    assert is_nil(Repo.get!(AuthSession, session["id"]).revoked_at)
  end

  test "ops-issued target session is ordinary, hash-only, and has no admin capability" do
    {:ok, user} =
      Comma.Accounts.create_user(%{"email" => unique_email("ops"), "admin" => true})

    refute Map.has_key?(user, "admin")

    assert {:ok, session} =
             Comma.Accounts.create_session(user["id"], session_source: "ops_api")

    assert session["session_source"] == "ops_api"
    assert session["auth_method"] == nil
    refute Map.has_key?(session, "admin")

    stored = Repo.get!(AuthSession, session["id"])
    assert stored.auth_method == nil
    assert byte_size(stored.token_hash) == 32

    caller_token = "comma_sess_" <> String.duplicate("a", 32)
    assert {:ok, generated} = Comma.Accounts.create_session(user["id"], token: caller_token)
    refute generated["token"] == caller_token
    assert {:error, :not_found} = Comma.Accounts.validate_session(caller_token)
  end

  test "session changesets reject malformed restricted input and contradictory capability shapes" do
    attrs = session_attrs("usr_shape")

    non_boolean =
      AuthSession.changeset(%AuthSession{}, %{
        attrs
        | restricted: "true",
          session_source: "ops_api"
      })

    refute non_boolean.valid?
    assert {"must be a boolean", _metadata} = non_boolean.errors[:restricted]

    unrestricted_scope =
      AuthSession.changeset(
        %AuthSession{},
        Map.merge(attrs, %{
          restricted: false,
          session_source: "ops_api",
          auth_method: nil,
          workspace_id: "wsp_unrestricted"
        })
      )

    refute unrestricted_scope.valid?
    assert {"requires a restricted session", _metadata} = unrestricted_scope.errors[:workspace_id]

    unrestricted_group_scope =
      AuthSession.changeset(
        %AuthSession{},
        Map.merge(attrs, %{
          restricted: false,
          session_source: "ops_api",
          auth_method: nil,
          group_id: "grp_unrestricted"
        })
      )

    refute unrestricted_group_scope.valid?

    assert {"requires a restricted session", _metadata} =
             unrestricted_group_scope.errors[:group_id]

    conversation_without_group =
      AuthSession.changeset(
        %AuthSession{},
        Map.merge(attrs, %{
          restricted: true,
          session_source: "ops_api",
          auth_method: nil,
          workspace_id: "wsp_not_conversation_authority",
          conversation_id: "cnv_requires_group"
        })
      )

    refute conversation_without_group.valid?

    assert {"is required with conversation_id", _metadata} =
             conversation_without_group.errors[:group_id]

    login_restricted =
      AuthSession.changeset(%AuthSession{}, %{
        attrs
        | restricted: true,
          session_source: "user_login",
          auth_method: "email_otp"
      })

    refute login_restricted.valid?
    assert Keyword.has_key?(login_restricted.errors, :session_source)

    panel_without_connection =
      AuthSession.changeset(
        %AuthSession{},
        Map.merge(attrs, %{
          restricted: true,
          session_source: "channel_task_panel",
          auth_method: "telegram_miniapp",
          workspace_id: "wsp_panel",
          group_id: "grp_panel",
          channel_subject: "42001"
        })
      )

    refute panel_without_connection.valid?
    assert Keyword.has_key?(panel_without_connection.errors, :session_source)
  end

  test "database rejects capability shapes that bypass the AuthSession changeset" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => unique_email("db-scope")})

    assert_scope_constraint(fn ->
      insert_session_shape!(user["id"],
        restricted: false,
        session_source: "ops_api",
        auth_method: nil,
        workspace_id: "wsp_unrestricted"
      )
    end)

    assert_scope_constraint(fn ->
      insert_session_shape!(user["id"],
        restricted: true,
        session_source: "user_login",
        auth_method: "email_otp",
        workspace_id: "wsp_restricted"
      )
    end)
  end

  test "restricted budget is durable, idempotent, and cannot be overspent concurrently" do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => unique_email("budget")})

    {:ok, session} =
      Comma.Accounts.create_session(user["id"],
        session_source: "ops_api",
        restricted: true,
        interaction_budget_remaining: 1
      )

    results =
      ["request-a", "request-b"]
      |> Enum.map(fn operation_id ->
        Task.async(fn -> Comma.Accounts.consume_budget(session, operation_id) end)
      end)
      |> Task.await_many()

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :budget_exhausted}, &1)) == 1

    [{:ok, consumed}] = Enum.filter(results, &match?({:ok, _}, &1))
    refute Map.has_key?(consumed, "consumed_interaction_ids")

    stored = Repo.get!(AuthSession, session["id"])
    [operation_id] = Map.keys(stored.consumed_interaction_ids)

    assert {:ok, retry} = Comma.Accounts.consume_budget(session, operation_id)
    assert retry["interaction_budget_remaining"] == 0
    refute Map.has_key?(retry, "consumed_interaction_ids")

    stored = Repo.get!(AuthSession, session["id"])
    assert stored.interaction_budget_remaining == 0
    assert map_size(stored.consumed_interaction_ids) == 1
  end

  defp request_code(email) do
    {:ok, %{"challenge_id" => challenge_id, "code" => code}} =
      Comma.AuthChallenges.request_email_login(%{"email" => email})

    {challenge_id, code}
  end

  defp verify_code(challenge_id, code) do
    Comma.AuthChallenges.verify_email_login(%{"challenge_id" => challenge_id, "code" => code})
  end

  defp session_attrs(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      user_id: user_id,
      token_hash: :crypto.strong_rand_bytes(32),
      auth_method: "email_otp",
      session_source: "user_login",
      authenticated_at: now,
      expires_at: DateTime.add(now, 3600),
      last_seen_at: now,
      user_auth_epoch: 0,
      restricted: false,
      tool_allowlist: [],
      consumed_interaction_ids: %{}
    }
  end

  defp assert_scope_constraint(fun) do
    assert_raise Postgrex.Error, ~r/comma_auth_sessions_scope_valid/, fn ->
      Repo.transaction(fun, mode: :savepoint)
    end
  end

  defp insert_session_shape!(user_id, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO comma_auth_sessions (
        id,
        user_id,
        token_hash,
        auth_method,
        session_source,
        authenticated_at,
        expires_at,
        last_seen_at,
        user_auth_epoch,
        restricted,
        workspace_id,
        tool_allowlist,
        consumed_interaction_ids,
        created_at,
        updated_at
      )
      VALUES (
        $1::uuid,
        $2,
        $3,
        $4,
        $5,
        $6,
        $7,
        $6,
        0,
        $8,
        $9,
        ARRAY[]::text[],
        '{}'::jsonb,
        $6,
        $6
      )
      """,
      [
        Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        user_id,
        :crypto.strong_rand_bytes(32),
        Keyword.fetch!(opts, :auth_method),
        Keyword.fetch!(opts, :session_source),
        now,
        DateTime.add(now, 3600),
        Keyword.fetch!(opts, :restricted),
        Keyword.fetch!(opts, :workspace_id)
      ]
    )
  end

  defp unique_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
