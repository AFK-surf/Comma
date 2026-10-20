defmodule CommaWeb.ReviewLoginTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts
  alias Comma.Accounts.{AuthSession, User}
  alias Comma.AuthChallengeStore.Redis

  setup do
    previous = SystemsRuntime.fetch_env!(:comma_core, :auth)
    prefix = "review-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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

    start_supervised!({Redix, {url, [name: Redis.connection_name(), sync_connect: true]}})
    on_exit(fn -> SystemsRuntime.put_env(:comma_core, :auth, previous) end)

    {:ok, actor} = Accounts.create_user(%{"email" => "operator-#{prefix}@comma.surf"})
    {:ok, session} = Accounts.create_session(actor["id"])
    {:ok, target} = Accounts.create_user(%{"email" => "review-#{prefix}@comma.surf"})
    %{target: target, admin: session["token"], prefix: prefix}
  end

  test "administrator configures a private reusable code and native login consumes each challenge",
       ctx do
    deny(ctx)
    response = configure(ctx, "037291")
    assert response.status == 200
    assert json(response)["review_login_configured"]
    refute response.resp_body =~ "037291"
    refute response.resp_body =~ "review_login_code_hash"
    stored = Repo.get!(User, ctx.target["id"])
    refute stored.review_login_code_hash == "037291"
    refute inspect(stored) =~ stored.review_login_code_hash

    for _ <- 1..2 do
      challenge = login(ctx)
      refute Map.has_key?(challenge, "code")
      result = verify(challenge, "037291")
      assert result.status == 200
      session = json(result)
      assert session["user"]["id"] == ctx.target["id"]
      assert Repo.get!(AuthSession, session["session_id"]).auth_method == "review_code"
      assert call(:get, "/v1/comma/auth/session", nil, session["token"]).status == 200
      assert verify(challenge, "037291").status == 401
      assert call(:get, "/v1/comma/admin/users", nil, session["token"]).status == 403
    end

    expired = login(ctx)

    assert {:ok, 1} =
             Redix.command(Redis.connection_name(), [
               "EXPIRE",
               "#{ctx.prefix}:challenge:#{expired["challenge_id"]}",
               "0"
             ])

    assert verify(expired, "037291").status == 401
    assert ctx |> login() |> verify("037291") |> Map.fetch!(:status) == 200

    audit =
      Repo.one!(
        from(e in Comma.Admin.AuditEvent,
          where: e.target_id == ^ctx.target["id"] and e.action == "update_user"
        )
      )

    assert audit.outcome == "succeeded"
    refute inspect(audit) =~ "037291"
  end

  test "replacement and removal invalidate pending logins but preserve existing sessions", ctx do
    deny(ctx)
    assert configure(ctx, "037291").status == 200
    session = ctx |> login() |> verify("037291") |> json()
    stale = login(ctx)
    assert configure(ctx, "482693").status == 200
    assert verify(stale, "037291").status == 401
    current = login(ctx)
    assert verify(current, "037291").status == 401
    assert verify(current, "482693").status == 200
    pending = login(ctx)
    assert configure(ctx, nil).status == 200
    assert verify(pending, "482693").status == 401
    assert call(:get, "/v1/comma/auth/session", nil, session["token"]).status == 200
    assert Repo.get!(Comma.Admin.AccessOverride, ctx.target["id"]).decision == "deny"
    ordinary = login(ctx)
    assert is_binary(ordinary["code"])
    assert verify(ordinary, ordinary["code"]).status == 200
    assert verify(ordinary, ordinary["code"]).status == 401
  end

  test "configuration requires admin authority and explicit denial; review proof cannot link identities",
       ctx do
    assert configure(ctx, "037291").status == 400
    deny(ctx)
    assert configure(ctx, "12").status == 400
    assert configure(ctx, "037291").status == 200
    assert access(ctx, "allow").status == 400
    session = ctx |> login() |> verify("037291") |> json()
    assert configure(%{ctx | admin: session["token"]}, "482693").status == 403

    assert call(:patch, "/v1/comma/admin/users/#{ctx.target["id"]}", %{
             "review_login_code" => "482693"
           }).status == 401

    challenge = login(ctx)

    assert call(:post, "/v1/comma/auth/apple/link/verify", %{
             "challenge_id" => challenge["challenge_id"],
             "code" => "037291"
           }).status == 401

    assert verify(challenge, "037291").status == 200

    assert {:ok, enrollment} =
             Comma.AuthChallenges.request_ssh_enrollment(
               %{"email" => ctx.target["email"]},
               "test-binding"
             )

    assert {:error, :invalid_verification_code} =
             Comma.AuthChallenges.verify_ssh_enrollment(
               enrollment["challenge_id"],
               "037291",
               "test-binding"
             )

    assert {:ok, _} =
             Comma.AuthChallenges.verify_ssh_enrollment(
               enrollment["challenge_id"],
               enrollment["code"],
               "test-binding"
             )

    assert Comma.Admin.update_user(ctx.target["id"], %{"status" => "disabled"}) |> elem(0) == :ok
    assert ctx |> login() |> verify("037291") |> Map.fetch!(:status) == 403
  end

  test "review login ignores mail outages but retains cross-challenge failure limits", ctx do
    deny(ctx)
    assert configure(ctx, "037291").status == 200

    opts = %{
      provider_failure_threshold: 1,
      provider_failure_window_seconds: 60,
      provider_circuit_open_seconds: 60
    }

    assert {:ok, :circuit_open} = Redis.record_delivery(:error, opts)

    assert call(:post, "/v1/comma/auth/email/login", %{
             "email" => "ordinary-#{ctx.prefix}@example.test"
           }).status == 503

    one = login(ctx)
    two = login(ctx)
    for _ <- 1..5, do: assert(verify(one, "999999").status == 401)
    for _ <- 1..4, do: assert(verify(two, "999999").status == 401)
    assert verify(two, "999999").status == 429
    assert ctx |> login() |> verify("037291") |> Map.fetch!(:status) == 429
  end

  defp configure(ctx, code) do
    call(
      :patch,
      "/v1/comma/admin/users/#{ctx.target["id"]}",
      metadata(ctx, "update-user", %{"review_login_code" => code}),
      ctx.admin
    )
  end

  defp deny(ctx), do: assert(access(ctx, "deny").status == 200)

  defp access(ctx, decision) do
    call(
      :put,
      "/v1/comma/admin/users/#{ctx.target["id"]}/admin-access",
      metadata(ctx, "admin-access", %{"decision" => decision}, ":#{decision}"),
      ctx.admin
    )
  end

  defp metadata(ctx, action, attrs, suffix \\ "") do
    Map.merge(attrs, %{
      "confirmation" => "#{action}:#{ctx.target["id"]}#{suffix}",
      "reason" => "Prepare app review",
      "idempotency_key" => "review-test-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    })
  end

  defp login(ctx) do
    response = call(:post, "/v1/comma/auth/email/login", %{"email" => ctx.target["email"]})
    assert response.status == 200
    json(response)
  end

  defp verify(challenge, code),
    do:
      call(:post, "/v1/comma/auth/email/verify", %{
        "challenge_id" => challenge["challenge_id"],
        "code" => code,
        "client_kind" => "ios",
        "client_platform" => "ios"
      })

  defp call(method, path, attrs, token \\ nil) do
    conn =
      Plug.Test.conn(method, path, if(attrs, do: Jason.encode!(attrs), else: nil))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-comma-session-transport", "bearer")

    conn =
      cond do
        token && String.starts_with?(path, "/v1/comma/admin/") ->
          {:ok, _user, session} = Accounts.resolve_session(token)

          conn
          |> Plug.Conn.put_req_header(
            "origin",
            SystemsRuntime.fetch_env!(:comma_web, :admin_cookie_origin)
          )
          |> Plug.Conn.put_req_header("x-comma-session-transport", "cookie")
          |> Plug.Conn.put_req_header("x-comma-session-lifecycle-version", "1")
          |> Plug.Conn.put_req_header("x-comma-expected-auth-session-id", session["id"])
          |> Plug.Conn.put_req_header("cookie", "comma_session=" <> token)

        token ->
          Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)

        true ->
          conn
      end

    CommaWeb.Router.call(conn, CommaWeb.Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
end
