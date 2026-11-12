defmodule CommaWeb.EmailChangeTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts
  alias Comma.Accounts.{Identity, Repository, User}
  alias Comma.AuthChallengeStore.Redis

  @ops_token "email-change-ops-token"

  setup do
    previous = SystemsRuntime.fetch_env!(:comma_core, :auth)
    previous_api_token = SystemsRuntime.get_env(:comma_web, :api_token)
    prefix = "email-change-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    url = System.get_env("COMMA_TEST_REDIS_URL", "redis://127.0.0.1:6379/0")

    SystemsRuntime.put_env(
      :comma_core,
      :auth,
      Keyword.merge(previous,
        challenge_store: Redis,
        redis_url: url,
        redis_key_prefix: prefix,
        email_delivery: Comma.EmailDelivery.Logger,
        expose_codes: true,
        resend_cooldown_seconds: 0,
        email_request_limit: 100,
        ip_request_limit: 100,
        verification_failure_limit: 10,
        challenge_ttl_seconds: 60
      )
    )

    SystemsRuntime.put_env(:comma_web, :api_token, @ops_token)
    start_supervised!({Redix, {url, [name: Redis.connection_name(), sync_connect: true]}})

    on_exit(fn ->
      SystemsRuntime.put_env(:comma_core, :auth, previous)
      SystemsRuntime.put_env(:comma_web, :api_token, previous_api_token)
    end)

    email = "work-#{prefix}@comma.test"
    {:ok, user} = Accounts.create_user(%{"email" => email, "name" => "Person"})
    {:ok, session} = Accounts.create_session(user["id"])

    %{user: user, email: email, token: session["token"], prefix: prefix}
  end

  test "a user moves their account to a new email with a code from each mailbox", ctx do
    {:ok, _identity} =
      Repository.ensure_identity(ctx.user["id"], %{
        provider: "google",
        issuer: "https://accounts.google.com",
        subject: "google-#{ctx.prefix}",
        email_snapshot: ctx.email,
        email_verified: true
      })

    new_email = "personal-#{ctx.prefix}@comma.test"
    current = post("/v1/comma/me/email-change/code", %{}, ctx.token) |> json()

    # A wrong code for the account email sends nothing to the new one.
    assert post(
             "/v1/comma/me/email-change/new-email-code",
             %{
               "email" => new_email,
               "challenge_id" => current["challenge_id"],
               "code" => wrong(current["code"])
             },
             ctx.token
           ).status == 400

    new =
      post(
        "/v1/comma/me/email-change/new-email-code",
        %{
          "email" => new_email,
          "challenge_id" => current["challenge_id"],
          "code" => current["code"]
        },
        ctx.token
      )
      |> json()

    assert is_binary(new["code"])

    assert post(
             "/v1/comma/me/email-change",
             %{"challenge_id" => new["challenge_id"], "code" => wrong(new["code"])},
             ctx.token
           ).status == 400

    assert Repo.get!(User, ctx.user["id"]).email == ctx.email

    changed =
      post(
        "/v1/comma/me/email-change",
        %{"challenge_id" => new["challenge_id"], "code" => new["code"]},
        ctx.token
      )

    assert changed.status == 200
    assert json(changed)["user"]["email"] == new_email
    assert json(changed)["user"]["id"] == ctx.user["id"]

    # Same account: the session stays signed in, the Google login still
    # reaches it, and both emails now name it the new way.
    assert get("/v1/comma/auth/session", ctx.token).status == 200
    assert Repo.exists?(from(i in Identity, where: i.user_id == ^ctx.user["id"]))
    assert {:ok, %{"id" => id}} = Accounts.get_user_by_email(new_email)
    assert id == ctx.user["id"]
    assert {:error, :not_found} = Accounts.get_user_by_email(ctx.email)

    # A new account with the old email gets no registration credits again.
    assert Comma.EmailChange.released_email?(ctx.email)
    refute Comma.EmailChange.released_email?(new_email)

    # The new email's code works once.
    assert post(
             "/v1/comma/me/email-change",
             %{"challenge_id" => new["challenge_id"], "code" => new["code"]},
             ctx.token
           ).status == 400
  end

  test "the new email cannot belong to another account", ctx do
    taken = "taken-#{ctx.prefix}@comma.test"
    {:ok, _other} = Accounts.create_user(%{"email" => taken})
    current = post("/v1/comma/me/email-change/code", %{}, ctx.token) |> json()

    conflict =
      post(
        "/v1/comma/me/email-change/new-email-code",
        %{
          "email" => taken,
          "challenge_id" => current["challenge_id"],
          "code" => current["code"]
        },
        ctx.token
      )

    assert conflict.status == 409
    assert json(conflict)["error"] == "email_taken"
    assert Repo.get!(User, ctx.user["id"]).email == ctx.email
  end

  test "the email of an account waiting for deletion is refused with its deletion time", ctx do
    pending = "pending-#{ctx.prefix}@comma.test"
    {:ok, other} = Accounts.create_user(%{"email" => pending})
    scheduled_at = ~U[2026-11-08 12:00:00.000000Z]

    Repo.update_all(from(u in User, where: u.id == ^other["id"]),
      set: [deletion_scheduled_at: scheduled_at]
    )

    current = post("/v1/comma/me/email-change/code", %{}, ctx.token) |> json()

    conflict =
      post(
        "/v1/comma/me/email-change/new-email-code",
        %{
          "email" => pending,
          "challenge_id" => current["challenge_id"],
          "code" => current["code"]
        },
        ctx.token
      )

    assert conflict.status == 409

    assert json(conflict) == %{
             "error" => "email_pending_deletion",
             "deletion_scheduled_at" => DateTime.to_iso8601(scheduled_at)
           }

    assert {:error, :email_pending_deletion} = Comma.EmailChange.change(ctx.user["id"], pending)
  end

  test "a code from the old mailbox does not start a change after support changed the email",
       ctx do
    current = post("/v1/comma/me/email-change/code", %{}, ctx.token) |> json()
    support = "support-#{ctx.prefix}@comma.test"
    {:ok, _user} = Comma.EmailChange.change(ctx.user["id"], support)

    stale =
      post(
        "/v1/comma/me/email-change/new-email-code",
        %{
          "email" => "other-#{ctx.prefix}@comma.test",
          "challenge_id" => current["challenge_id"],
          "code" => current["code"]
        },
        ctx.token
      )

    assert stale.status == 409
    assert json(stale)["error"] == "email_changed"
    assert Repo.get!(User, ctx.user["id"]).email == support
  end

  test "a change made meanwhile voids the new email's code", ctx do
    current = post("/v1/comma/me/email-change/code", %{}, ctx.token) |> json()

    new =
      post(
        "/v1/comma/me/email-change/new-email-code",
        %{
          "email" => "first-#{ctx.prefix}@comma.test",
          "challenge_id" => current["challenge_id"],
          "code" => current["code"]
        },
        ctx.token
      )
      |> json()

    {:ok, _user} = Comma.EmailChange.change(ctx.user["id"], "support-#{ctx.prefix}@comma.test")

    stale =
      post(
        "/v1/comma/me/email-change",
        %{"challenge_id" => new["challenge_id"], "code" => new["code"]},
        ctx.token
      )

    assert stale.status == 409
    assert Repo.get!(User, ctx.user["id"]).email == "support-#{ctx.prefix}@comma.test"
  end

  test "support changes the email of a person who lost the old mailbox", ctx do
    new_email = "Personal-#{ctx.prefix}@Comma.test"

    changed =
      Plug.Test.conn(
        :put,
        "/v1/comma/admin/users/#{ctx.user["id"]}/email",
        Jason.encode!(%{"email" => new_email})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @ops_token)
      |> CommaWeb.Router.call(CommaWeb.Router.init([]))

    assert changed.status == 200
    assert json(changed)["email"] == String.downcase(new_email)
    assert Repo.get!(User, ctx.user["id"]).email == String.downcase(new_email)
    assert get("/v1/comma/auth/session", ctx.token).status == 200
  end

  test "a human administrator changes the email through the audited command", ctx do
    {:ok, actor} = Accounts.create_user(%{"email" => "operator-#{ctx.prefix}@comma.surf"})
    {:ok, session} = Accounts.create_session(actor["id"])
    new_email = "recovered-#{ctx.prefix}@comma.test"

    changed =
      Plug.Test.conn(
        :put,
        "/v1/comma/admin/users/#{ctx.user["id"]}/email",
        Jason.encode!(%{
          "email" => new_email,
          "confirmation" => "change-email:#{ctx.user["id"]}",
          "reason" => "Old mailbox closed",
          "idempotency_key" => "email-change-#{ctx.prefix}"
        })
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header(
        "origin",
        SystemsRuntime.fetch_env!(:comma_web, :admin_cookie_origin)
      )
      |> Plug.Conn.put_req_header("x-comma-session-transport", "cookie")
      |> Plug.Conn.put_req_header("x-comma-session-lifecycle-version", "1")
      |> Plug.Conn.put_req_header("x-comma-expected-auth-session-id", session["id"])
      |> Plug.Conn.put_req_header("cookie", "comma_session=" <> session["token"])
      |> CommaWeb.Router.call(CommaWeb.Router.init([]))

    assert changed.status == 200
    assert Repo.get!(User, ctx.user["id"]).email == new_email

    assert %{outcome: "succeeded", actor_user_id: actor_id} =
             Repo.get_by!(Comma.Admin.AuditEvent,
               action: "change_user_email",
               target_id: ctx.user["id"]
             )

    assert actor_id == actor["id"]
  end

  defp wrong(code), do: if(code == "000000", do: "111111", else: "000000")

  defp post(path, attrs, token), do: call(:post, path, Jason.encode!(attrs), token)
  defp get(path, token), do: call(:get, path, nil, token)

  defp call(method, path, body, token) do
    Plug.Test.conn(method, path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-comma-session-transport", "bearer")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
end
