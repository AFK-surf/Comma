defmodule CommaWeb.AccountDeletionTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts
  alias Comma.Accounts.{Identity, Repository, User}
  alias Comma.AuthChallengeStore.Redis
  alias Comma.Billing.SignupCredits
  alias Comma.Data.{ExternalOperation, Workspace, WorkspaceMembership}

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)
    previous = SystemsRuntime.fetch_env!(:comma_core, :auth)
    prefix = "deletion-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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

    email = "person-#{prefix}@comma.test"
    {:ok, user} = Accounts.create_user(%{"email" => email, "name" => "Person"})
    {:ok, session} = Accounts.create_session(user["id"])
    workspace = insert_workspace!(user["id"])

    %{user: user, email: email, token: session["token"], workspace: workspace, prefix: prefix}
  end

  test "a user deletes their account with the code mailed to them", ctx do
    {:ok, _identity} =
      Repository.ensure_identity(ctx.user["id"], %{
        provider: "apple",
        issuer: "https://appleid.apple.com",
        subject: "apple-#{ctx.prefix}",
        email_snapshot: ctx.email,
        email_verified: true
      })

    app =
      Repo.insert!(%Comma.MiniApps.App{
        id: "00000000-0000-4000-8000-0000000000a1",
        slug: "acctdel1",
        workspace_id: ctx.workspace.id,
        group_id: ctx.workspace.salix_group_id,
        created_by: ctx.user["id"],
        name: "App",
        repo_owner: "person",
        repo_name: "comma-app-acctdel1",
        visibility: "link"
      })

    link =
      Repo.insert!(%Comma.MiniApps.Link{
        id: "00000000-0000-4000-8000-0000000000b1",
        app_id: app.id,
        token: "link-#{ctx.prefix}",
        created_by: ctx.user["id"]
      })

    challenge = call(:post, "/v1/comma/me/account-deletion/code", %{}, ctx.token) |> json()
    assert is_binary(challenge["code"])

    wrong = if challenge["code"] == "000000", do: "111111", else: "000000"

    assert call(
             :post,
             "/v1/comma/me/account-deletion",
             %{
               "challenge_id" => challenge["challenge_id"],
               "code" => wrong
             },
             ctx.token
           ).status == 400

    assert call(:get, "/v1/comma/auth/session", nil, ctx.token).status == 200

    deleted =
      call(
        :post,
        "/v1/comma/me/account-deletion",
        %{
          "challenge_id" => challenge["challenge_id"],
          "code" => challenge["code"]
        },
        ctx.token
      )

    assert deleted.status == 200
    assert %{"deleted" => true, "deletion_scheduled_at" => scheduled} = json(deleted)
    {:ok, scheduled_at, 0} = DateTime.from_iso8601(scheduled)

    # Every credential of the account stops working at once.
    assert call(:get, "/v1/comma/auth/session", nil, ctx.token).status == 401

    # Nothing is deleted for seven days.
    pending = Repo.get!(User, ctx.user["id"])
    assert pending.status == "active"
    assert pending.email == ctx.email
    assert pending.deletion_scheduled_at == scheduled_at
    Comma.AccountDeletion.delete_due(DateTime.add(scheduled_at, -1))
    assert Repo.get!(User, ctx.user["id"]).status == "active"
    assert Repo.get!(Workspace, ctx.workspace.id).status == "active"

    Comma.AccountDeletion.delete_due(scheduled_at)

    stored = Repo.get!(User, ctx.user["id"])
    assert stored.status == "deleted"
    assert stored.email =~ ~r/^d-[0-9a-f]{24}@deleted\.comma\.invalid$/
    assert is_nil(stored.name)
    assert %DateTime{} = stored.deleted_at
    refute Repo.exists?(from(i in Identity, where: i.user_id == ^ctx.user["id"]))
    assert Repo.get!(Workspace, ctx.workspace.id).status == "deleted"

    # The Workspace's Mini Apps go with it, and their share link stops.
    assert Repo.get!(Comma.MiniApps.App, app.id).status == "deleted"
    assert %DateTime{} = Repo.get!(Comma.MiniApps.Link, link.id).revoked_at

    # The email is free for a new account, which gets no registration credits.
    assert Comma.AccountDeletion.deleted_email?(ctx.email)
    {:ok, again} = Accounts.get_or_create_user_by_email(ctx.email)
    refute again["id"] == ctx.user["id"]
    previous_selfhost = SystemsRuntime.get_env(:comma_core, :selfhost)
    SystemsRuntime.put_env(:comma_core, :selfhost, false)
    on_exit(fn -> SystemsRuntime.put_env(:comma_core, :selfhost, previous_selfhost) end)
    second = insert_workspace!(again["id"])
    :ok = ensure_billing_account(second)
    assert :ok = SignupCredits.ensure(%{"id" => second.id, "owner_user_id" => again["id"]})

    assert [] ==
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT id FROM credit_grants WHERE source_type = 'comma_signup' AND source_id = $1",
               [again["id"]]
             ).rows

    operation =
      Repo.one!(
        from(o in ExternalOperation,
          where: o.operation_type == "account_deletion" and o.owner_id == ^ctx.user["id"]
        )
      )

    assert operation.metadata["workspace_ids"] == [ctx.workspace.id]

    assert {:ok, %ExternalOperation{status: "succeeded"}} =
             Comma.Workers.AccountDeletion.run(operation.operation_id)
  end

  test "signing in again within the seven days takes the deletion back", ctx do
    challenge = call(:post, "/v1/comma/me/account-deletion/code", %{}, ctx.token) |> json()

    scheduled =
      call(
        :post,
        "/v1/comma/me/account-deletion",
        %{"challenge_id" => challenge["challenge_id"], "code" => challenge["code"]},
        ctx.token
      )
      |> json()

    {:ok, scheduled_at, 0} = DateTime.from_iso8601(scheduled["deletion_scheduled_at"])

    # A support session issued by operators does not take it back.
    {:ok, _ops} = Comma.Admin.create_session(ctx.user["id"], %{})
    refute is_nil(Repo.get!(User, ctx.user["id"]).deletion_scheduled_at)

    {:ok, _session} = Accounts.create_session(ctx.user["id"])
    assert is_nil(Repo.get!(User, ctx.user["id"]).deletion_scheduled_at)

    Comma.AccountDeletion.delete_due(DateTime.add(scheduled_at, 1))
    stored = Repo.get!(User, ctx.user["id"])
    assert stored.status == "active"
    assert stored.email == ctx.email
    assert Repo.get!(Workspace, ctx.workspace.id).status == "active"
  end

  test "a subscription that still renews blocks deletion until renewal is cancelled", ctx do
    subscription = subscribe!(ctx.workspace)

    blocked = call(:post, "/v1/comma/me/account-deletion/code", %{}, ctx.token)
    assert blocked.status == 409
    assert json(blocked)["error"] == "subscription_active"

    challenge_blocked =
      call(
        :post,
        "/v1/comma/me/account-deletion",
        %{"challenge_id" => "x", "code" => "123456"},
        ctx.token
      )

    assert challenge_blocked.status == 409

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_subscriptions SET source_metadata = source_metadata || '{\"cancel_at_period_end\": true}'::jsonb WHERE id = $1",
      [subscription]
    )

    challenge = call(:post, "/v1/comma/me/account-deletion/code", %{}, ctx.token) |> json()

    assert call(
             :post,
             "/v1/comma/me/account-deletion",
             %{
               "challenge_id" => challenge["challenge_id"],
               "code" => challenge["code"]
             },
             ctx.token
           ).status == 200

    # The subscription is left to end on its own.
    assert [["active"]] =
             Ecto.Adapters.SQL.query!(
               BillingCore.Repo,
               "SELECT status FROM billing_subscriptions WHERE id = $1",
               [subscription]
             ).rows
  end

  defp ensure_billing_account(workspace) do
    BillingCore.Accounts.ensure_account(%{
      billing_account_id: workspace.billing_owner_id,
      enforce_product_owner_identity: true,
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: workspace.id
    })
  end

  defp subscribe!(workspace) do
    :ok = ensure_billing_account(workspace)

    now = SystemsClock.utc_now()
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    package = "comma_deletion_#{unique}"

    {:ok, _} =
      BillingCommerce.create_package(%{code: package, surface: "comma", name: "Monthly"})

    {:ok, _} =
      BillingCommerce.create_package_version(%{
        package_code: package,
        version: "2026-06",
        surface: "comma",
        kind: "subscription",
        billing_period: "month",
        grant_credits: 700,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 2_000,
        usage_policy: %{},
        effective_at: ~U[2026-06-01 00:00:00Z],
        status: "active"
      })

    {:ok, _} =
      BillingCommerce.Subscriptions.create_subscription(%{
        billing_account_id: workspace.billing_owner_id,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace.id,
        package_code: package,
        package_version: "2026-06",
        source_type: "stripe_subscription",
        source_id: "sub_deletion_#{unique}",
        source_event_id: "in_deletion_#{unique}",
        idempotency_key: "deletion_#{unique}",
        source_metadata: %{},
        periods: [%{cycle_key: "initial", valid_from: now, expires_at: DateTime.add(now, 86_400)}]
      })

    [[id]] =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT id FROM billing_subscriptions WHERE billing_account_id = $1",
        [workspace.billing_owner_id]
      ).rows

    id
  end

  defp insert_workspace!(user_id) do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    id = "wsp_deletion_#{unique}"

    workspace =
      Repo.insert!(
        Workspace.changeset(%Workspace{}, %{
          id: id,
          owner_user_id: user_id,
          salix_tenant_id: "ten_deletion_#{unique}",
          salix_group_id: "grp_deletion_#{unique}",
          group_generation: "generation",
          salix_router_agent_id: "router_deletion_#{unique}",
          salix_worker_agent_id: "worker_deletion_#{unique}",
          billing_owner_id: "comma-ba-#{id}",
          name: "Workspace",
          status: "active"
        })
      )

    Repo.insert!(
      WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
        workspace_id: id,
        user_id: user_id,
        role: "owner",
        status: "active"
      })
    )

    workspace
  end

  defp call(method, path, attrs, token) do
    Plug.Test.conn(method, path, if(attrs, do: Jason.encode!(attrs), else: nil))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("x-comma-session-transport", "bearer")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)
end
