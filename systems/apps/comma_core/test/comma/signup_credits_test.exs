defmodule Comma.SignupCreditsTest do
  use Comma.DataCase, async: false
  alias Comma.Billing.SignupCredits

  setup_all do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
      Ecto.Migrator.run(BillingCore.Repo, :up, all: true)
    end

    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, {:shared, self()})
    previous_cap = Application.get_env(:comma_core, :signup_credit_daily_cap_usd)
    previous_domains = Application.get_env(:comma_core, :signup_credit_excluded_domains)

    on_exit(fn ->
      if previous_domains,
        do: Application.put_env(:comma_core, :signup_credit_excluded_domains, previous_domains),
        else: Application.delete_env(:comma_core, :signup_credit_excluded_domains)
    end)

    on_exit(fn ->
      if previous_cap,
        do: Application.put_env(:comma_core, :signup_credit_daily_cap_usd, previous_cap),
        else: Application.delete_env(:comma_core, :signup_credit_daily_cap_usd)
    end)

    previous = Application.get_env(:comma_core, :selfhost)
    Application.put_env(:comma_core, :selfhost, false)
    on_exit(fn -> Application.put_env(:comma_core, :selfhost, previous) end)
    :ok
  end

  test "registered Comma users receive twenty dollars once before their default Workspace is ready" do
    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "signup-#{System.unique_integer([:positive])}@comma.test"
      )

    workspace = create_ready_workspace!(user["id"])
    [[20_000_000, 20_000_000, nil, "comma_signup", owner]] = grants(user["id"])
    assert owner == workspace["billing_account_id"]
    assert {:ok, _} = Comma.WorkspaceBootstrap.ensure_default(user["id"])
    assert :ok = SignupCredits.ensure(workspace)
    assert length(grants(user["id"])) == 1

    {:ok, other} = Comma.Workspaces.create_for_user(user["id"], %{"vm" => %{"enabled" => false}})
    :ok = BillingCore.Accounts.ensure_account(account(other))
    assert :ok = SignupCredits.ensure(other)
    assert length(grants(user["id"])) == 1

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE credit_grants SET remaining_credits=0 WHERE source_type='comma_signup' AND source_id=$1",
      [user["id"]]
    )

    assert :ok = SignupCredits.ensure(other)
    assert [[20_000_000, 0, nil, "comma_signup", ^owner]] = grants(user["id"])
  end

  test "the UTC daily budget counts spent gifts and skipped users never regain eligibility" do
    Application.put_env(:comma_core, :signup_credit_daily_cap_usd, 20)

    {:ok, first} =
      Comma.Accounts.get_or_create_user_by_email(
        "budget-first-#{System.unique_integer([:positive])}@comma.test"
      )

    create_ready_workspace!(first["id"])
    assert length(grants(first["id"])) == 1

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE credit_grants SET remaining_credits=0 WHERE id=$1",
      ["grant_comma_signup_" <> first["id"]]
    )

    {:ok, denied} =
      Comma.Accounts.get_or_create_user_by_email(
        "budget-denied-#{System.unique_integer([:positive])}@comma.test"
      )

    workspace = create_ready_workspace!(denied["id"])
    assert grants(denied["id"]) == []
    Application.put_env(:comma_core, :signup_credit_daily_cap_usd, 2_000)
    assert :ok = SignupCredits.ensure(workspace)
    assert grants(denied["id"]) == []

    {:ok, yesterday} =
      Comma.Accounts.get_or_create_user_by_email(
        "yesterday-#{System.unique_integer([:positive])}@comma.test"
      )

    Repo.get!(Comma.Accounts.User, yesterday["id"])
    |> Ecto.Changeset.change(created_at: DateTime.add(DateTime.utc_now(), -86_400))
    |> Repo.update!()

    create_ready_workspace!(yesterday["id"])
    assert grants(yesterday["id"]) == []
  end

  test "aliases, relays and multiple-address providers skip gifts without merging login identities" do
    unique = System.unique_integer([:positive])

    for email <- [
          "alias+#{unique}@comma.test",
          "alias.#{unique}@gmail.com",
          "relay#{unique}@privaterelay.appleid.com",
          "relay#{unique}@sub.mozmail.com",
          "proton#{unique}@PM.ME",
          "primary#{unique}@outlook.com",
          "primary#{unique}@icloud.com",
          "primary#{unique}@fastmail.com",
          "primary#{unique}@engineer.com",
          "temporary#{unique}@mailinator.com",
          "temporary#{unique}@sharklasers.com",
          "temporary#{unique}@yop.kd2.org",
          "temporary#{unique}@team.msdc.co",
          "temporary#{unique}@uberip.com"
        ] do
      {:ok, user} = Comma.Accounts.get_or_create_user_by_email(email)
      create_ready_workspace!(user["id"])
      assert grants(user["id"]) == []
      assert Repo.get!(Comma.Accounts.User, user["id"]).email == String.downcase(email)
      refute Repo.get!(Comma.Accounts.User, user["id"]).signup_credit_eligible
    end

    for domain <- ["gmail.com", "notmozmail.com", "sub.outlook.com", "comma.test"] do
      {:ok, user} = Comma.Accounts.get_or_create_user_by_email("primary#{unique}@#{domain}")
      create_ready_workspace!(user["id"])
      assert length(grants(user["id"])) == 1
    end
  end

  test "configured domain exclusions replace defaults and do not revoke an issued gift" do
    Application.put_env(:comma_core, :signup_credit_excluded_domains, [])

    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "custom#{System.unique_integer([:positive])}@pm.me"
      )

    workspace = create_ready_workspace!(user["id"])
    assert length(grants(user["id"])) == 1

    Application.put_env(:comma_core, :signup_credit_excluded_domains, ["pm.me", ".comma.test"])
    assert :ok = SignupCredits.ensure(workspace)
    assert length(grants(user["id"])) == 1

    {:ok, denied} =
      Comma.Accounts.get_or_create_user_by_email(
        "custom#{System.unique_integer([:positive])}@sub.comma.test"
      )

    create_ready_workspace!(denied["id"])
    assert grants(denied["id"]) == []
  end

  test "existing and admin-created accounts retain their credits without a registration gift" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "existing-#{System.unique_integer([:positive])}@comma.test"
      })

    {:ok, same} = Comma.Accounts.get_or_create_user_by_email(user["email"])
    assert same["id"] == user["id"]
    workspace = create_ready_workspace!(user["id"])
    assert :ok = SignupCredits.ensure(workspace)
    assert grants(user["id"]) == []
  end

  test "a billing commit survives a later product failure and Workspace replacement without another gift" do
    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "retry-#{System.unique_integer([:positive])}@comma.test"
      )

    {:ok, workspace} =
      Comma.Workspaces.create_for_user(user["id"], %{"vm" => %{"enabled" => false}})

    :ok = BillingCore.Accounts.ensure_account(account(workspace))

    assert {:error, :after_billing_commit} =
             Repo.transaction(fn ->
               :ok = SignupCredits.ensure(workspace)
               Repo.rollback(:after_billing_commit)
             end)

    assert length(grants(user["id"])) == 1
    assert :ok = SignupCredits.ensure(workspace)

    Repo.get!(Comma.Data.Workspace, workspace["id"])
    |> Ecto.Changeset.change(status: "deleted")
    |> Repo.update!()

    {:ok, replacement} =
      Comma.Workspaces.create_for_user(user["id"], %{"vm" => %{"enabled" => false}})

    :ok = BillingCore.Accounts.ensure_account(account(replacement))
    assert :ok = SignupCredits.ensure(replacement)
    assert [[20_000_000, 20_000_000, nil, "comma_signup", old_account]] = grants(user["id"])
    assert old_account == workspace["billing_account_id"]
  end

  test "selfhost stays unlimited and foreign Billing Account ownership cannot receive the gift" do
    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "scope-#{System.unique_integer([:positive])}@comma.test"
      )

    Application.put_env(:comma_core, :selfhost, true)
    workspace = create_ready_workspace!(user["id"])
    assert grants(user["id"]) == []
    Application.put_env(:comma_core, :selfhost, false)

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_accounts SET surface='bridge_for_teams' WHERE id=$1",
      [workspace["billing_account_id"]]
    )

    assert {:error, :billing_account_surface_mismatch} = SignupCredits.ensure(workspace)
    assert grants(user["id"]) == []
  end

  @tag sandbox: false
  test "concurrent users share the last daily gift without duplicate fulfillment" do
    unboxed = fn fun ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(BillingCore.Repo, fun)
      end)
    end

    Application.put_env(:comma_core, :signup_credit_daily_cap_usd, 20)

    fixtures =
      for _ <- 1..2 do
        unboxed.(fn ->
          {:ok, user} =
            Comma.Accounts.get_or_create_user_by_email(
              "concurrent-#{System.unique_integer([:positive])}@comma.test"
            )

          {:ok, workspace} =
            Comma.Workspaces.create_for_user(user["id"], %{"vm" => %{"enabled" => false}})

          :ok = BillingCore.Accounts.ensure_account(account(workspace))
          {user, workspace}
        end)
      end

    try do
      tasks =
        for {_, workspace} <- fixtures, _ <- 1..2 do
          Task.async(fn -> unboxed.(fn -> SignupCredits.ensure(workspace) end) end)
        end

      assert Enum.map(tasks, &Task.await(&1, 5_000)) == [:ok, :ok, :ok, :ok]

      issued = unboxed.(fn -> Enum.flat_map(fixtures, fn {user, _} -> grants(user["id"]) end) end)
      assert [[20_000_000, 20_000_000, nil, "comma_signup", _]] = issued
    after
      for {user, workspace} <- fixtures do
        unboxed.(fn ->
          for table <- ~w(credit_grant_events credit_grants credit_balances billing_accounts) do
            column = if table == "billing_accounts", do: "id", else: "billing_account_id"

            Ecto.Adapters.SQL.query!(
              BillingCore.Repo,
              "DELETE FROM #{table} WHERE #{column}=$1",
              [
                workspace["billing_account_id"]
              ]
            )
          end

          # Only this committed fixture is removed; membership rows cascade with the Workspace.
          Ecto.Adapters.SQL.query!(
            Repo,
            "DELETE FROM oban_jobs WHERE args->>'operation_id' IN (SELECT operation_id FROM comma_external_operations WHERE owner_id=$1)",
            [workspace["id"]]
          )

          Ecto.Adapters.SQL.query!(
            Repo,
            "DELETE FROM comma_external_operations WHERE owner_id=$1",
            [workspace["id"]]
          )

          Ecto.Adapters.SQL.query!(Repo, "DELETE FROM comma_workspaces WHERE id=$1", [
            workspace["id"]
          ])

          Ecto.Adapters.SQL.query!(Repo, "DELETE FROM comma_users WHERE id=$1", [user["id"]])
        end)
      end
    end
  end

  test "post-rollout convergence fulfills ready Workspaces completed by an old worker" do
    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "rollout-#{System.unique_integer([:positive])}@comma.test"
      )

    {:ok, workspace} =
      Comma.Workspaces.create_for_user(user["id"], %{"vm" => %{"enabled" => false}})

    :ok = BillingCore.Accounts.ensure_account(account(workspace))
    assert :ok = SignupCredits.converge()
    assert grants(user["id"]) == []

    Repo.get!(Comma.Data.Workspace, workspace["id"])
    |> Ecto.Changeset.change(status: "active")
    |> Repo.update!()

    plan = %{
      manifestDigest: "signup-local-convergence",
      requiredMode: "online",
      pendingSteps: [],
      providerPendingIDs: ["comma-signup-credits"]
    }

    previous_api = Application.get_env(:billing_stripe, :stripe_api)
    previous_required = System.get_env("REQUIRE_PROVIDER")
    Application.put_env(:billing_stripe, :stripe_api, __MODULE__)
    System.put_env("REQUIRE_PROVIDER", "true")

    try do
      # The real release executor must not call Stripe without its authorized step,
      # even when the deployment environment requires provider convergence.
      for _ <- 1..2 do
        Comma.Release.execute_plan_stage(
          "provider",
          plan.manifestDigest,
          plan.providerPendingIDs,
          plan: fn -> plan end
        )
      end
    after
      Application.put_env(:billing_stripe, :stripe_api, previous_api)

      if previous_required,
        do: System.put_env("REQUIRE_PROVIDER", previous_required),
        else: System.delete_env("REQUIRE_PROVIDER")
    end

    assert [[20_000_000, 20_000_000, nil, "comma_signup", _]] = grants(user["id"])
  end

  defp account(workspace),
    do: %{
      billing_account_id: workspace["billing_account_id"],
      surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: workspace["id"],
      enforce_product_owner_identity: true
    }

  defp grants(user) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "SELECT original_credits, remaining_credits, expires_at, source_type, billing_account_id FROM credit_grants WHERE source_type='comma_signup' AND source_id=$1",
      [user]
    ).rows
  end
end
