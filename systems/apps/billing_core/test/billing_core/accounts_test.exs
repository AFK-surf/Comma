defmodule BillingCore.AccountsTest do
  use ExUnit.Case, async: false

  setup_all do
    unless Process.whereis(BillingCore.Repo) do
      {:ok, _pid} = BillingCore.Repo.start_link()
    end

    Ecto.Migrator.run(BillingCore.Repo, :up, all: true)
    Ecto.Adapters.SQL.Sandbox.mode(BillingCore.Repo, :manual)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(BillingCore.Repo)
  end

  test "default ensure_account preserves legacy same-surface owner updates" do
    assert :ok =
             BillingCore.Accounts.ensure_account(%{
               repo: BillingCore.Repo,
               billing_account_id: "example-ba-compat_surface_guard",
               surface: "comma",
               required_surface: "comma",
               product_owner_type: "workspace",
               product_owner_id: "wsp_compat_before"
             })

    assert :ok =
             BillingCore.Accounts.ensure_account(%{
               repo: BillingCore.Repo,
               billing_account_id: "example-ba-compat_surface_guard",
               surface: "comma",
               required_surface: "comma",
               product_owner_type: "organization",
               product_owner_id: "org_compat_after"
             })

    assert {:error, :billing_account_surface_mismatch} =
             BillingCore.Accounts.ensure_account(%{
               repo: BillingCore.Repo,
               billing_account_id: "example-ba-compat_surface_guard",
               surface: "bridge",
               required_surface: "bridge",
               product_owner_type: "organization",
               product_owner_id: "org_surface_guard"
             })

    assert ["comma", "organization", "org_compat_after"] ==
             account_row("example-ba-compat_surface_guard")
  end

  test "strict ensure_account preserves the full product-owner identity" do
    attrs = %{
      repo: BillingCore.Repo,
      billing_account_id: "example-ba-wsp_identity_guard",
      surface: "comma",
      required_surface: "comma",
      product_owner_type: "workspace",
      product_owner_id: "wsp_identity_guard",
      enforce_product_owner_identity: true
    }

    assert :ok = BillingCore.Accounts.ensure_account(attrs)

    assert {:error, :billing_account_owner_mismatch} =
             attrs
             |> Map.put(:product_owner_id, "wsp_identity_guard_updated")
             |> BillingCore.Accounts.ensure_account()

    assert {:error, :billing_account_surface_mismatch} =
             attrs
             |> Map.merge(%{
               surface: "bridge",
               required_surface: "bridge",
               product_owner_type: "organization",
               product_owner_id: "org_identity_guard"
             })
             |> BillingCore.Accounts.ensure_account()

    assert :ok =
             attrs
             |> BillingCore.Accounts.verify_account()

    assert {:error, :billing_account_owner_mismatch} =
             attrs
             |> Map.put(:product_owner_id, "wsp_identity_guard_updated")
             |> BillingCore.Accounts.verify_account()

    assert ["comma", "workspace", "wsp_identity_guard"] ==
             account_row("example-ba-wsp_identity_guard")
  end

  defp account_row(account_id) do
    %{rows: [row]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT surface, product_owner_type, product_owner_id
        FROM billing_accounts
        WHERE id = $1
        """,
        [account_id]
      )

    row
  end
end
