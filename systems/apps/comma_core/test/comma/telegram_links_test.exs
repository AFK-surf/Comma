defmodule Comma.TelegramLinksTest do
  use ExUnit.Case, async: false

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.TelegramLinks

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "one-time claim links a Telegram DM to the authorized workspace" do
    {user, workspace} = account_with_workspace("claim")

    assert {:ok, ^workspace, claim} = TelegramLinks.create_claim(user, %{}, workspace["id"])
    assert DateTime.compare(claim.expires_at, DateTime.utc_now()) == :gt
    assert {:ok, %{workspace: prepared}} = TelegramLinks.take_claim(claim.code)
    assert prepared["id"] == workspace["id"]

    assert {:ok, %{link: link, displaced: []}} =
             TelegramLinks.put_link(
               user["id"],
               workspace["id"],
               %{"id" => "42001", "username" => "@alice"},
               "imc-managed",
               claim
             )

    assert link.workspace_id == workspace["id"]
    assert link.telegram_user_id == "42001"
    assert link.telegram_username == "alice"
    assert link.connect_id == "imc-managed"
    assert TelegramLinks.get_active_claim(workspace["id"]) == nil
    assert {:error, :invalid_telegram_claim} = TelegramLinks.take_claim(claim.code)
  end

  test "relinking moves one Telegram identity between workspaces without ambiguity" do
    {first_user, first_workspace} = account_with_workspace("first")
    {second_user, second_workspace} = account_with_workspace("second")
    first_claim = consumed_claim(first_user, first_workspace)
    second_claim = consumed_claim(second_user, second_workspace)

    assert {:ok, %{displaced: []}} =
             TelegramLinks.put_link(
               first_user["id"],
               first_workspace["id"],
               %{"id" => 88, "username" => "first"},
               "imc-first",
               first_claim
             )

    assert {:ok, %{link: moved, displaced: [previous]}} =
             TelegramLinks.put_link(
               second_user["id"],
               second_workspace["id"],
               %{"id" => 88, "username" => "second"},
               "imc-second",
               second_claim
             )

    assert previous.workspace_id == first_workspace["id"]
    assert moved.workspace_id == second_workspace["id"]
    assert TelegramLinks.get_link(first_workspace["id"]) == nil

    assert {:ok, %{workspace: resolved, link: resolved_link}} =
             TelegramLinks.resolve_sender("88")

    assert resolved["id"] == second_workspace["id"]
    assert resolved_link.connect_id == "imc-second"
  end

  test "workspace authorization gates reads, claims, and disconnect" do
    {owner, workspace} = account_with_workspace("owner")
    {:ok, stranger} = Comma.Accounts.create_user(%{"email" => "#{unique("stranger")}@comma.test"})

    assert {:error, :forbidden} = TelegramLinks.get(stranger, %{}, workspace["id"])
    assert {:error, :forbidden} = TelegramLinks.create_claim(stranger, %{}, workspace["id"])

    assert {:ok, %{}} =
             TelegramLinks.put_link(
               owner["id"],
               workspace["id"],
               %{"id" => "99"},
               "imc-owner",
               consumed_claim(owner, workspace)
             )

    assert {:error, :forbidden} = TelegramLinks.delete(stranger, %{}, workspace["id"])
    assert {:ok, ^workspace, true} = TelegramLinks.delete(owner, %{}, workspace["id"])
    assert {:error, :telegram_not_linked} = TelegramLinks.resolve_sender("99")
  end

  test "OIDC attempts keep PKCE state server-side and are consumed once" do
    {user, workspace} = account_with_workspace("oidc")

    assert {:ok, ^workspace, attempt} =
             TelegramLinks.create_oidc_attempt(user, %{}, workspace["id"], %{
               "state" => "opaque-browser-state",
               "nonce" => "oidc-nonce",
               "pkce_verifier" => "private-pkce-verifier"
             })

    refute attempt.state_hash == "opaque-browser-state"

    assert {:ok, %{attempt: consumed, workspace: ^workspace, user: ^user}} =
             TelegramLinks.take_oidc_attempt("opaque-browser-state")

    assert consumed.nonce == "oidc-nonce"
    assert consumed.pkce_verifier == "private-pkce-verifier"

    assert {:error, :invalid_telegram_oidc_attempt} =
             TelegramLinks.take_oidc_attempt("opaque-browser-state")
  end

  defp account_with_workspace(label) do
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "#{unique(label)}@comma.test"})
    workspace = insert_workspace!(user["id"], label)

    Comma.Repo.insert!(
      WorkspaceMembership.changeset(%WorkspaceMembership{}, %{
        workspace_id: workspace.id,
        user_id: user["id"],
        role: "owner",
        status: "active"
      })
    )

    {:ok, public_workspace} = Comma.Workspaces.get(workspace.id)
    {user, public_workspace}
  end

  defp consumed_claim(user, workspace) do
    {:ok, _, claim} = TelegramLinks.create_claim(user, %{}, workspace["id"])
    {:ok, %{claim: consumed}} = TelegramLinks.take_claim(claim.code)
    consumed
  end

  defp insert_workspace!(user_id, label) do
    id = unique("wsp-#{label}")

    Comma.Repo.insert!(
      Workspace.changeset(%Workspace{}, %{
        id: id,
        owner_user_id: user_id,
        salix_tenant_id: unique("ten"),
        salix_group_id: unique("grp"),
        group_generation: unique("generation"),
        salix_router_agent_id: unique("router"),
        salix_worker_agent_id: unique("worker"),
        billing_owner_id: "comma-ba-#{id}",
        name: "Telegram #{label}",
        status: "active"
      })
    )
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
end
