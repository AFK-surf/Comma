defmodule Comma.SignupCreditsTest do
  require SystemsRuntime.Proc
  use Comma.DataCase, async: false
  setup {Comma.AuthAbuseTestSupport, :setup}
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.Comma", "Elixir.BillingCore"]
  alias Comma.Billing.SignupCredits
  alias Comma.Accounts.{Repository, User}
  alias Comma.AuthChallenges

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, {:shared, SystemsRuntime.Proc.self()})
    previous_cap = SystemsRuntime.get_env(:comma_core, :signup_credit_daily_cap_usd)
    previous_domains = SystemsRuntime.get_env(:comma_core, :signup_credit_excluded_domains)

    on_exit(fn ->
      if previous_domains,
        do:
          SystemsRuntime.put_env(:comma_core, :signup_credit_excluded_domains, previous_domains),
        else: SystemsRuntime.delete_env(:comma_core, :signup_credit_excluded_domains)
    end)

    on_exit(fn ->
      if previous_cap,
        do: SystemsRuntime.put_env(:comma_core, :signup_credit_daily_cap_usd, previous_cap),
        else: SystemsRuntime.delete_env(:comma_core, :signup_credit_daily_cap_usd)
    end)

    previous = SystemsRuntime.get_env(:comma_core, :selfhost)
    SystemsRuntime.put_env(:comma_core, :selfhost, false)
    on_exit(fn -> SystemsRuntime.put_env(:comma_core, :selfhost, previous) end)
    :ok
  end

  test "registered Comma users receive twenty dollars once before their default Workspace is ready" do
    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "signup-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      )

    workspace = create_ready_workspace!(user["id"])
    [[20_000_000, 20_000_000, nil, "comma_signup", owner]] = grants(user["id"])
    assert owner == workspace["billing_account_id"]
    assert {:ok, _} = Comma.WorkspaceBootstrap.ensure_default(user["id"])
    assert :ok = SignupCredits.ensure(workspace)
    assert length(grants(user["id"])) == 1

    {:ok, other} = Comma.Workspaces.create_for_user(user["id"])
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
    SystemsRuntime.put_env(:comma_core, :signup_credit_daily_cap_usd, 20)

    {:ok, first} =
      Comma.Accounts.get_or_create_user_by_email(
        "budget-first-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
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
        "budget-denied-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      )

    workspace = create_ready_workspace!(denied["id"])
    assert grants(denied["id"]) == []
    SystemsRuntime.put_env(:comma_core, :signup_credit_daily_cap_usd, 2_000)
    assert :ok = SignupCredits.ensure(workspace)
    assert grants(denied["id"]) == []

    {:ok, yesterday} =
      Comma.Accounts.get_or_create_user_by_email(
        "yesterday-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      )

    Repo.get!(Comma.Accounts.User, yesterday["id"])
    |> Ecto.Changeset.change(created_at: DateTime.add(SystemsClock.utc_now(), -86_400))
    |> Repo.update!()

    create_ready_workspace!(yesterday["id"])
    assert grants(yesterday["id"]) == []
  end

  test "aliases, relays and multiple-address providers skip gifts without merging login identities" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])

    for email <- [
          "alias+#{unique}@comma.test",
          "alias+#{unique}@gmail.com",
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

    # Domains on Cloudflare Email Routing, as read at registration; the
    # Gmail one takes the canonical Gmail path.
    Comma.TestSupport.MxRecords.put(%{
      "catchall.test" => ["route1.mx.cloudflare.net"],
      "gmail.com" => ["route2.mx.cloudflare.net"]
    })

    for email <- ["routed#{unique}@catchall.test", "routed#{unique}@gmail.com"] do
      {:ok, user} =
        Comma.Accounts.get_or_create_user_by_email(email, %{}, %{email_verified: true})

      create_ready_workspace!(user["id"])
      assert grants(user["id"]) == []
      refute Repo.get!(Comma.Accounts.User, user["id"]).signup_credit_eligible
    end

    Comma.TestSupport.MxRecords.put(%{})

    for domain <- ["gmail.com", "notmozmail.com", "sub.outlook.com", "comma.test"] do
      {:ok, user} =
        Comma.Accounts.get_or_create_user_by_email("primary#{unique}@#{domain}", %{}, %{
          email_verified: true
        })

      create_ready_workspace!(user["id"])
      assert length(grants(user["id"])) == 1
    end
  end

  test "verified dotted Gmail registration receives one gift without merging later aliases" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    first = otp_signup!("new.person#{unique}@gmail.com")
    create_ready_workspace!(first["id"])
    assert length(grants(first["id"])) == 1

    later = otp_signup!("newperson#{unique}@gmail.com")
    refute first["id"] == later["id"]
    assert first["email"] == "new.person#{unique}@gmail.com"
    create_ready_workspace!(later["id"])
    assert grants(later["id"]) == []
  end

  test "prior registered Gmail users consume eligibility without receiving a gift" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])

    for {prefix, attrs} <- [{"admin", %{}}, {"disabled", %{status: "disabled"}}, {"plus", %{}}] do
      local = "#{prefix}#{unique}"
      original = if prefix == "plus", do: local <> "+tag", else: local
      {:ok, prior} = Comma.Accounts.create_user(Map.put(attrs, :email, original <> "@gmail.com"))
      forget_gmail_history!(prior["email"])
      # Simulate a prechange row whose clear email is the only canonical history.
      Repo.get!(User, prior["id"])
      |> Ecto.Changeset.change(signup_credit_gmail_claimed: false)
      |> Repo.update!()

      alias_user = otp_signup!("#{prefix}.#{unique}@gmail.com")
      create_ready_workspace!(alias_user["id"])
      assert grants(alias_user["id"]) == []
    end
  end

  test "unverified Gmail and historical pending dotted users receive no new gift" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])

    {:ok, unverified} =
      Comma.Accounts.get_or_create_user_by_email("unverified.#{unique}@gmail.com")

    refute Repo.get!(User, unverified["id"]).signup_credit_eligible
    create_ready_workspace!(unverified["id"])
    assert grants(unverified["id"]) == []

    {:ok, historical} = Comma.Accounts.create_user(%{email: "historical.#{unique}@gmail.com"})

    Repo.get!(User, historical["id"])
    |> Ecto.Changeset.change(signup_credit_eligible: true, signup_credit_gmail_claimed: false)
    |> Repo.update!()

    create_ready_workspace!(historical["id"])
    assert grants(historical["id"]) == []
  end

  test "deletion retains Gmail history and a duplicate claim cannot block deletion" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    first = otp_signup!("delete.person#{unique}@gmail.com")
    second = otp_signup!("deleteperson#{unique}@gmail.com")

    for user <- [first, second] do
      delete_account!(user["id"])
    end

    later = otp_signup!("d.eleteperson#{unique}@gmail.com")
    create_ready_workspace!(later["id"])
    assert grants(later["id"]) == []
  end

  test "deleting a prechange Gmail user preserves canonical history" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, prior} = Comma.Accounts.create_user(%{email: "old.person#{unique}@gmail.com"})

    Repo.get!(User, prior["id"])
    |> Ecto.Changeset.change(signup_credit_gmail_claimed: false)
    |> Repo.update!()

    forget_gmail_history!(prior["email"])
    delete_account!(prior["id"])
    later = otp_signup!("oldperson#{unique}@gmail.com")
    create_ready_workspace!(later["id"])
    assert grants(later["id"]) == []
  end

  test "historical undotted deleted-email hashes still block a new dotted Gmail gift" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, prior} = Comma.Accounts.create_user(%{email: "olddeleted#{unique}@gmail.com"})
    delete_account!(prior["id"])

    Repo.get!(User, prior["id"])
    |> Ecto.Changeset.change(signup_credit_gmail_claimed: false)
    |> Repo.update!()

    forget_gmail_history!(prior["email"])
    later = otp_signup!("old.deleted#{unique}@gmail.com")
    create_ready_workspace!(later["id"])
    assert grants(later["id"]) == []
  end

  test "email change and final deletion preserve old and current Gmail occupancy" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, prior} = Comma.Accounts.create_user(%{email: "first.person#{unique}@gmail.com"})
    forget_gmail_history!(prior["email"])
    destination = "second.person#{unique}@gmail.com"
    assert {:ok, _} = Comma.EmailChange.change(prior["id"], destination)
    first_alias = otp_signup!("firstperson#{unique}@gmail.com")
    create_ready_workspace!(first_alias["id"])
    assert grants(first_alias["id"]) == []

    # An old change may have only exact history. Final deletion records its current mailbox.
    forget_gmail_history!(destination)
    delete_account!(prior["id"])
    second_alias = otp_signup!("secondperson#{unique}@gmail.com")
    create_ready_workspace!(second_alias["id"])
    assert grants(second_alias["id"]) == []
  end

  test "a missing Gmail claim key skips the gift without blocking account creation or returning login" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    verified = otp_signup!("returning.#{unique}@gmail.com")
    auth = SystemsRuntime.get_env(:comma_core, :auth)
    SystemsRuntime.put_env(:comma_core, :auth, Keyword.delete(auth, :secret))
    on_exit(fn -> SystemsRuntime.put_env(:comma_core, :auth, auth) end)
    assert {:ok, returning, :existing} = Repository.ensure_user_by_email(verified["email"])
    assert returning.id == verified["id"]

    assert {:ok, new, :created} =
             Repository.ensure_user_by_email("missing.#{unique}@gmail.com", %{
               email_verified: true
             })

    refute new.signup_credit_eligible
    assert not new.signup_credit_gmail_claimed
  end

  test "existing and admin-created accounts retain their credits without a registration gift" do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "existing-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
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
        "retry-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      )

    {:ok, workspace} =
      Comma.Workspaces.create_for_user(user["id"])

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
      Comma.Workspaces.create_for_user(user["id"])

    :ok = BillingCore.Accounts.ensure_account(account(replacement))
    assert :ok = SignupCredits.ensure(replacement)
    assert [[20_000_000, 20_000_000, nil, "comma_signup", old_account]] = grants(user["id"])
    assert old_account == workspace["billing_account_id"]
  end

  test "selfhost stays unlimited and foreign Billing Account ownership cannot receive the gift" do
    {:ok, user} =
      Comma.Accounts.get_or_create_user_by_email(
        "scope-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      )

    SystemsRuntime.put_env(:comma_core, :selfhost, true)
    workspace = create_ready_workspace!(user["id"])
    assert grants(user["id"]) == []
    SystemsRuntime.put_env(:comma_core, :selfhost, false)

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_accounts SET surface='bridge_for_teams' WHERE id=$1",
      [workspace["billing_account_id"]]
    )

    assert {:error, :billing_account_surface_mismatch} = SignupCredits.ensure(workspace)
    assert grants(user["id"]) == []
  end

  @tag sandbox: false
  test "concurrent verified Gmail aliases reserve only one gift before Workspace creation" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    emails = ["race.person#{unique}@gmail.com", "r.aceperson#{unique}@gmail.com"]
    canonical = "raceperson#{unique}"
    parent = SystemsRuntime.Proc.self()
    handler = "gmail-claim-#{unique}"

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:comma, :repo, :query],
        &__MODULE__.pause_canonical_read/4,
        {parent, canonical}
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    on_exit(fn -> cleanup_committed_signups!(emails) end)

    tasks =
      for email <- emails do
        SystemsRuntime.Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> otp_signup!(email) end)
        end)
      end

    settle_receive({:canonical_read, first})
    settle_receive({:canonical_read, second})
    SystemsRuntime.Proc.send(first, :insert_claim)
    SystemsRuntime.Proc.send(second, :insert_claim)
    users = Enum.map(tasks, &settled_await/1)
    SystemsRuntime.Telemetry.detach(handler)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      stored = Enum.map(users, &Repo.get!(User, &1["id"]))
      assert Enum.count(stored, & &1.signup_credit_eligible) == 1
      assert Enum.count(stored, & &1.signup_credit_gmail_claimed) == 1
      assert Enum.sort(Enum.map(stored, & &1.email)) == Enum.sort(emails)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(BillingCore.Repo, fn ->
        Enum.each(users, &create_ready_workspace!(&1["id"]))
        assert length(Enum.flat_map(users, &grants(&1["id"]))) == 1
      end)
    end)
  end

  @tag sandbox: false
  test "email change reserves its destination before a concurrent alias can receive a gift" do
    unique = SystemsRuntime.Proc.unique_integer([:positive])
    source = "moving-#{unique}@comma.test"
    destination = "move.person#{unique}@gmail.com"
    alias_email = "moveperson#{unique}@gmail.com"
    parent = SystemsRuntime.Proc.self()
    handler = "gmail-move-#{unique}"
    on_exit(fn -> cleanup_committed_signups!([source, destination, alias_email]) end)

    :ok =
      SystemsRuntime.Telemetry.attach(
        handler,
        [:comma, :repo, :query],
        &__MODULE__.pause_canonical_read/4,
        {parent, "moveperson#{unique}"}
      )

    on_exit(fn -> SystemsRuntime.Telemetry.detach(handler) end)

    moving =
      SystemsRuntime.Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          {:ok, user} = Comma.Accounts.create_user(%{email: source})

          Repo.transaction(fn ->
            assert {:ok, _} = Comma.EmailChange.change(user["id"], destination)
            SystemsRuntime.Proc.send(parent, {:destination_reserved, SystemsRuntime.Proc.self()})

            SystemsRuntime.Proc.receive do
              :commit_move -> :ok
            end
          end)
        end)
      end)

    settle_receive({:destination_reserved, mover})

    registering =
      SystemsRuntime.Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> otp_signup!(alias_email) end)
      end)

    settle_receive({:canonical_read, signup})
    # The registration has already read a snapshot without the new destination.
    SystemsRuntime.Proc.send(mover, :commit_move)
    assert {:ok, :ok} = settled_await(moving)
    SystemsRuntime.Proc.send(signup, :insert_claim)
    user = settled_await(registering)
    SystemsRuntime.Telemetry.detach(handler)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(BillingCore.Repo, fn ->
        create_ready_workspace!(user["id"])
        assert grants(user["id"]) == []
      end)
    end)
  end

  def pause_canonical_read(_event, _measurements, metadata, {parent, canonical}) do
    if String.contains?(metadata.query, "replace(split_part") and canonical in metadata.params do
      SystemsRuntime.Proc.send(parent, {:canonical_read, SystemsRuntime.Proc.self()})

      SystemsRuntime.Proc.receive do
        :insert_claim -> :ok
      end
    end
  end

  @tag sandbox: false
  test "concurrent users share the last daily gift without duplicate fulfillment" do
    unboxed = fn fun ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(BillingCore.Repo, fun)
      end)
    end

    SystemsRuntime.put_env(:comma_core, :signup_credit_daily_cap_usd, 20)

    fixtures =
      for _ <- 1..2 do
        unboxed.(fn ->
          {:ok, user} =
            Comma.Accounts.get_or_create_user_by_email(
              "concurrent-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
            )

          {:ok, workspace} =
            Comma.Workspaces.create_for_user(user["id"])

          :ok = BillingCore.Accounts.ensure_account(account(workspace))
          {user, workspace}
        end)
      end

    try do
      tasks =
        for {_, workspace} <- fixtures, _ <- 1..2 do
          SystemsRuntime.Task.async(fn -> unboxed.(fn -> SignupCredits.ensure(workspace) end) end)
        end

      assert Enum.map(tasks, &settled_await/1) == [:ok, :ok, :ok, :ok]

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

  defp delete_account!(user_id) do
    {:ok, code} = Comma.AccountDeletion.request_code(user_id, %{})
    {:ok, scheduled_at} = Comma.AccountDeletion.schedule(user_id, code)
    Comma.AccountDeletion.delete_due(scheduled_at)
    assert Repo.get!(User, user_id).status == "deleted"
  end

  defp forget_gmail_history!(email) do
    {:ok, hash} = SignupCredits.gmail_registration_hash(email)
    Repo.delete_all(from(r in "comma_released_emails", where: r.email_hash == ^hash))
  end

  defp cleanup_committed_signups!(emails) do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(BillingCore.Repo, fn ->
        for email <- emails, user <- Repo.all(from(u in User, where: u.email == ^email)) do
          accounts =
            Repo.all(
              from(w in Comma.Data.Workspace,
                where: w.owner_user_id == ^user.id,
                select: w.billing_owner_id
              )
            )

          for account <- accounts,
              table <- ~w(credit_grant_events credit_grants credit_balances billing_accounts) do
            column = if table == "billing_accounts", do: "id", else: "billing_account_id"

            Ecto.Adapters.SQL.query!(
              BillingCore.Repo,
              "DELETE FROM #{table} WHERE #{column}=$1",
              [account]
            )
          end

          Repo.delete_all(from(s in Comma.Accounts.AuthSession, where: s.user_id == ^user.id))
          cleanup_committed_user!(SystemsRuntime.Proc.whereis(Repo), user.id)
        end

        for email <- emails do
          {:ok, hash} = Comma.AccountDeletion.email_hash(email)
          Repo.delete_all(from(r in "comma_released_emails", where: r.email_hash == ^hash))
          if String.ends_with?(email, "@gmail.com"), do: forget_gmail_history!(email)
        end
      end)
    end)
  end

  defp otp_signup!(email) do
    assert {:ok, challenge} = Comma.AuthAbuseTestSupport.request_email_login(%{"email" => email})
    assert {:ok, session} = AuthChallenges.verify_email_login(challenge)
    session["user"]
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
