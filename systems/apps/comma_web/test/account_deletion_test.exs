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

  test "account deletion records and retires hosted collaboration isolated Salix groups", ctx do
    collab_group_id = "grp_collab_#{ctx.prefix}"
    now = SystemsClock.utc_now()

    Repo.insert!(%Comma.Data.TaskCollaborator{
      id: "tcb_del_#{ctx.prefix}",
      workspace_id: ctx.workspace.id,
      group_id: collab_group_id,
      conversation_id: "cnv_del_#{ctx.prefix}",
      title: "Shared Task",
      host_user_id: ctx.user["id"],
      invited_email: "guest@example.com",
      status: "active",
      inserted_at: now,
      updated_at: now
    })

    Repo.insert!(%Comma.Data.CollaborationGuestSession{
      id: "cgs_del_#{ctx.prefix}",
      collaborator_id: "tcb_del_#{ctx.prefix}",
      workspace_id: ctx.workspace.id,
      group_id: collab_group_id,
      conversation_id: "cnv_del_#{ctx.prefix}",
      email: "guest@example.com",
      token_hash: "hash_#{ctx.prefix}",
      expires_at: DateTime.add(now, 86_400, :second),
      inserted_at: now,
      updated_at: now
    })

    challenge = call(:post, "/v1/comma/me/account-deletion/code", %{}, ctx.token) |> json()

    deleted =
      call(
        :post,
        "/v1/comma/me/account-deletion",
        %{"challenge_id" => challenge["challenge_id"], "code" => challenge["code"]},
        ctx.token
      )

    assert deleted.status == 200
    {:ok, scheduled_at, 0} = DateTime.from_iso8601(json(deleted)["deletion_scheduled_at"])

    Comma.AccountDeletion.delete_due(scheduled_at)

    # Collaborator rows and guest sessions are cascade-deleted, and the isolated
    # collaboration group is recorded in the operation metadata for async retirement.
    refute Repo.get(Comma.Data.TaskCollaborator, "tcb_del_#{ctx.prefix}")
    refute Repo.get(Comma.Data.CollaborationGuestSession, "cgs_del_#{ctx.prefix}")

    op = Repo.get!(ExternalOperation, "op_account_deletion_" <> ctx.user["id"])

    assert op.metadata["collaboration_groups"] == [
             %{
               "group_id" => collab_group_id,
               "salix_tenant_id" => ctx.workspace.salix_tenant_id
             }
           ]
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

  test "AccountDeletion succeeds across multiple workspaces when first tenant has an unassign_unconfirmed Colab lease without resetting its 7-day TTL",
       ctx do
    prev_salix_client = SystemsRuntime.get_env(:comma_core, :salix_client)
    prev_colab_oauth = SystemsRuntime.get_env(:salix_agent, :colab_oauth)
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)

    SystemsRuntime.put_env(:salix_agent, :colab_oauth,
      client_id: "test-colab-client-id",
      client_secret: "test-secret",
      redirect_uri: "https://sdk.cloud.google.com/applicationdefaultauthcode.html",
      auth_uri: "https://accounts.google.com/o/oauth2/auth",
      token_uri: "https://oauth2.googleapis.com/token",
      userinfo_uri: "https://www.googleapis.com/oauth2/v2/userinfo",
      colab_base_url: "https://colab.research.google.com",
      req_options: [
        plug: fn conn ->
          now = SystemsClock.system_time(:second)

          case conn.request_path do
            "/token" ->
              header =
                Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}),
                  padding: false
                )

              payload =
                Base.url_encode64(
                  Jason.encode!(%{
                    "iss" => "https://accounts.google.com",
                    "aud" => "test-colab-client-id",
                    "sub" => "sub-acct-del-unconfirmed",
                    "email" => "acctdel@gmail.com",
                    "exp" => now + 3600
                  }),
                  padding: false
                )

              Plug.Conn.send_resp(
                conn |> Plug.Conn.put_resp_content_type("application/json"),
                200,
                Jason.encode!(%{
                  "access_token" => "ya29.acctdel",
                  "refresh_token" => "1//refresh-acctdel",
                  "expires_in" => 3600,
                  "token_type" => "Bearer",
                  "scope" =>
                    "openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/colaboratory",
                  "id_token" => "#{header}.#{payload}.sig"
                })
              )

            "/tun/m/ccu-info" ->
              Plug.Conn.send_resp(
                conn |> Plug.Conn.put_resp_content_type("application/json"),
                200,
                ")]}\'\n" <>
                  Jason.encode!(%{"currentBalance" => 100.0, "consumptionRateHourly" => 1.0})
              )

            _ ->
              Plug.Conn.send_resp(conn, 404, "not found")
          end
        end
      ]
    )

    on_exit(fn ->
      if is_nil(prev_salix_client),
        do: SystemsRuntime.delete_env(:comma_core, :salix_client),
        else: SystemsRuntime.put_env(:comma_core, :salix_client, prev_salix_client)

      if is_nil(prev_colab_oauth),
        do: SystemsRuntime.delete_env(:salix_agent, :colab_oauth),
        else: SystemsRuntime.put_env(:salix_agent, :colab_oauth, prev_colab_oauth)
    end)

    ws1 = ctx.workspace
    ws2 = insert_workspace!(ctx.user["id"])

    # Create a Colab account in ws1's (tenant_id, group_id) via single-authority Postgres flow,
    # insert a lease, mark unassign_unconfirmed, then delete account.
    {:ok, attempt} =
      SalixAgent.Colab.Account.start_oauth_attempt(
        ws1.salix_tenant_id,
        ws1.salix_group_id,
        ctx.user["id"],
        operation: :install
      )

    state = URI.decode_query(URI.parse(attempt.authorize_url).query)["state"]

    {:ok, %{binding_id: binding_id}} =
      SalixAgent.Colab.Account.complete_oauth_attempt(
        ws1.salix_tenant_id,
        ws1.salix_group_id,
        ctx.user["id"],
        attempt.attempt_id,
        "https://sdk.cloud.google.com/applicationdefaultauthcode.html?code=4/del-code&state=#{state}",
        operation: :install
      )

    spec = %{variant: "GPU", accelerator: "G4", high_mem: false}

    {:ok, lease, _} =
      SalixAgent.Colab.Leases.insert_assigning(
        ws1.salix_tenant_id,
        ws1.salix_group_id,
        "session:ag:del",
        nil,
        binding_id,
        spec
      )

    {:ok, active} =
      SalixAgent.Colab.Leases.promote_active(
        lease.vm_id,
        1,
        "m-s-acct-del-1",
        "https://abc.prod.colab.dev"
      )

    {:ok, unconfirmed} =
      SalixAgent.Colab.Leases.mark_unassign_unconfirmed(
        active.vm_id,
        active.generation,
        "authorization_revoked"
      )

    orig_reap_after = unconfirmed.reap_after

    on_exit(fn ->
      for table <- [
            "colab_vm_leases",
            "colab_accounts",
            "colab_group_install_states",
            "colab_oauth_attempts"
          ] do
        _ =
          SalixStore.Repo.query(
            "DELETE FROM #{table} WHERE tenant_id IN ($1, $2)",
            [ws1.salix_tenant_id, ws2.salix_tenant_id]
          )
      end

      _ =
        SalixStore.Repo.query(
          "DELETE FROM colab_retired_scopes WHERE scope_key IN ($1, $2)",
          ["tenant:" <> ws1.salix_tenant_id, "tenant:" <> ws2.salix_tenant_id]
        )
    end)

    # Mark both workspaces deleted and create the AccountDeletion external operation
    for ws <- [ws1, ws2] do
      Repo.update!(Ecto.Changeset.change(ws, status: "deleted"))
    end

    op_id = "acct-del-colab-#{ctx.prefix}"

    Repo.insert!(
      ExternalOperation.changeset(%ExternalOperation{}, %{
        operation_id: op_id,
        operation_type: "account_deletion",
        owner_type: "user",
        owner_id: ctx.user["id"],
        external_idempotency_key: op_id,
        generation: 1,
        status: "pending",
        metadata: %{"workspace_ids" => Enum.sort([ws1.id, ws2.id])}
      })
    )

    # Run AccountDeletion with final_attempt?: true -> MUST succeed across BOTH workspaces!
    assert {:ok,
            %ExternalOperation{
              status: "succeeded",
              metadata: %{"terminal_evidence" => %{"workspaces" => 2}}
            }} =
             Comma.Workers.AccountDeletion.run(op_id, final_attempt?: true)

    # unassign_unconfirmed lease row MUST remain untouched with its 7-day reap_after preserved
    assert {:ok, after_retire} = SalixAgent.Colab.Leases.get_by_id(unconfirmed.vm_id)
    assert after_retire.state == "unassign_unconfirmed"
    assert after_retire.reap_after == orig_reap_after

    # Tenant retirement fence MUST block late first-connects
    assert {:error, :scope_retired} =
             SalixAgent.Colab.Account.start_oauth_attempt(
               ws1.salix_tenant_id,
               ws1.salix_group_id,
               ctx.user["id"],
               operation: :install
             )
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
