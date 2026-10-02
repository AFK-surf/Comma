defmodule Comma.GuestModeTest do
  use Comma.DataCase, async: false

  alias Comma.Accounts
  alias Comma.Data.{ExternalOperation, Workspace}
  alias Comma.GuestMode

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
    previous = Application.get_env(:comma_core, :selfhost)
    Application.put_env(:comma_core, :selfhost, false)
    on_exit(fn -> Application.put_env(:comma_core, :selfhost, previous) end)
    :ok
  end

  test "the admin policy needs a guest Tenant before enabling and rejects stale revisions" do
    {:ok, policy} = GuestMode.get_policy()
    refute policy["enabled"]
    assert GuestMode.public_status() == %{"enabled" => false}
    assert {:error, :guest_mode_disabled} = GuestMode.create_guest(%{})

    assert {:error, :guest_tenant_required} =
             GuestMode.update_policy(%{"enabled" => true, "revision" => policy["revision"]})

    assert {:error, :invalid_guest_policy} =
             GuestMode.update_policy(%{"tenant_concurrency" => 0, "revision" => policy["revision"]})

    {:ok, with_tenant} = GuestMode.create_tenant(%{"revision" => policy["revision"]})
    assert is_binary(with_tenant["salix_tenant_id"])
    assert SalixStore.TenantProfiles.router_only?(with_tenant["salix_tenant_id"])

    assert {:error, :guest_policy_conflict} =
             GuestMode.update_policy(%{"enabled" => true, "revision" => policy["revision"]})

    {:ok, enabled} =
      GuestMode.update_policy(%{
        "enabled" => true,
        "tenant_concurrency" => 48,
        "revision" => with_tenant["revision"]
      })

    assert enabled["enabled"]
    assert %{"enabled" => true, "pow" => %{}} = GuestMode.public_status()

    assert SalixStore.TenantProfiles.dependency_limits()[with_tenant["salix_tenant_id"]] == 48
  end

  test "a guest gets a router-only Workspace in the shared guest Tenant" do
    tenant_id = enable_guest_mode!()

    guest = create_guest!()
    assert guest["kind"] == "guest"
    assert GuestMode.guest_email?(guest["email"])

    workspace = create_ready_workspace!(guest["id"])
    stored = Repo.get!(Workspace, workspace["id"])
    assert stored.kind == "guest"
    assert stored.salix_tenant_id == tenant_id
    assert is_nil(stored.salix_worker_agent_id)
    assert stored.vm == %{"enabled" => false}

    {:ok, router} = SalixAgent.Control.get(stored.salix_router_agent_id, tenant_id)
    assert router["role"] == "router"
    assert router["purpose"] == SalixStore.TenantProfiles.guest_router_purpose()
    assert router["vm"]["enabled"] == false

    # Salix refuses a Worker or a VM in the guest Tenant, whoever asks.
    assert {:error, {:bad_request, _message}} =
             SalixAgent.Control.create_preallocated(
               %{"role" => "worker", "group_id" => stored.salix_group_id, "name" => "Worker"},
               tenant_id,
               SalixStore.Ids.new_agent_id(stored.salix_group_id)
             )

    # A second guest shares the Tenant.
    other = create_guest!() |> Map.fetch!("id") |> create_ready_workspace!()
    assert Repo.get!(Workspace, other["id"]).salix_tenant_id == tenant_id

    assert {:error, :forbidden} =
             Comma.Workspaces.update(guest, %{}, workspace["id"], %{"vm" => %{"enabled" => true}})
  end

  test "handoff revokes the guest and one account redeems the claim once" do
    enable_guest_mode!()
    guest_session = create_guest_session!()
    guest = guest_session["user"]
    create_ready_workspace!(guest["id"])

    {:ok, %{"claim" => claim}} = GuestMode.handoff(Map.put(guest, "kind", "guest"))
    assert {:error, _reason} = Accounts.validate_session(guest_session["token"])

    {:ok, account} = Accounts.get_or_create_user_by_email("guest-signup-#{unique()}@comma.test")
    {:ok, other} = Accounts.get_or_create_user_by_email("guest-other-#{unique()}@comma.test")

    assert {:error, :guest_claim_invalid} = GuestMode.redeem(account, "cgc_unknown")
    assert {:error, :guest_forbidden} = GuestMode.redeem(Map.put(guest, "kind", "guest"), claim)

    assert {:ok, %{"import_id" => import_id, "status" => "pending"}} =
             GuestMode.redeem(account, claim)

    assert {:ok, %{"import_id" => ^import_id}} = GuestMode.redeem(account, claim)
    assert {:error, :guest_claim_invalid} = GuestMode.redeem(other, claim)
    assert {:ok, %{"import_id" => ^import_id}} = GuestMode.import_status(account, import_id)
    assert {:error, :not_found} = GuestMode.import_status(other, import_id)

    # The import waits for the account's Workspace, then an empty guest chat
    # completes without posting a message.
    assert {:busy, _seconds} = Comma.Workers.GuestImport.run(import_id)
    create_ready_workspace!(account["id"])
    Repo.update_all(ExternalOperation, set: [next_attempt_at: nil])
    assert {:ok, %ExternalOperation{status: "succeeded"}} = Comma.Workers.GuestImport.run(import_id)
    assert {:ok, %{"status" => "succeeded"}} = GuestMode.import_status(account, import_id)
  end

  test "the import posts the guest chat transcript into the account's Router chat" do
    enable_guest_mode!()
    guest = create_guest!()
    guest_workspace = create_ready_workspace!(guest["id"])
    salix = Comma.Salix.Client.impl()
    {:ok, scoped} = salix.resolve_workspace_scope(guest_workspace)

    {:ok, _message} =
      salix.append_group_router_conversation_message(scoped, %{
        "client_request_id" => "req_guest_hello_1",
        "actor_type" => "user",
        "user_id" => guest["id"],
        "content" => "Plan a three-day trip to Kyoto"
      })

    {:ok, %{"claim" => claim}} = GuestMode.handoff(guest)
    {:ok, account} = Accounts.get_or_create_user_by_email("guest-import-#{unique()}@comma.test")
    account_workspace = create_ready_workspace!(account["id"])
    {:ok, %{"import_id" => import_id}} = GuestMode.redeem(account, claim)

    assert {:ok, %ExternalOperation{status: "succeeded"}} = Comma.Workers.GuestImport.run(import_id)
    # A repeated run neither writes nor sends again.
    assert {:ok, %ExternalOperation{status: "succeeded"}} = Comma.Workers.GuestImport.run(import_id)

    {:ok, chat} =
      Comma.AssistantChats.ensure_chat(account, %{}, account_workspace["default_group_id"])

    {:ok, page} =
      Comma.Conversations.message_page(
        account,
        %{},
        account_workspace["default_group_id"],
        chat["id"],
        limit: 50
      )

    [imported] =
      Enum.filter(page["messages"], &(&1["actor_type"] == "user" and &1["user_id"] == account["id"]))

    [%{"text" => text}] = imported["content"]
    [_, path] = Regex.run(~r{workspace file: (/uploads/guest-chat-[^)]+\.md)}, text)

    {:ok, transcript} = salix.read_agent_file(account_workspace, path, 1_000_000)
    assert transcript =~ "Plan a three-day trip to Kyoto"
  end

  test "guest creation needs one fresh solved proof of work per guest" do
    enable_guest_mode!()
    assert %{"pow" => %{"difficulty" => 12}} = GuestMode.public_status()

    assert {:error, :guest_pow_invalid} = GuestMode.create_guest(%{})

    solved = solved_pow()

    assert {:error, :guest_pow_invalid} =
             GuestMode.create_guest(%{"pow" => %{solved | "nonce" => wrong_nonce(solved)}})

    [prefix, payload, _mac] = String.split(solved["challenge"], ".")
    forged = %{solved | "challenge" => Enum.join([prefix, payload, "forged"], ".")}
    assert {:error, :guest_pow_invalid} = GuestMode.create_guest(%{"pow" => forged})

    assert {:ok, _session} = GuestMode.create_guest(%{"pow" => solved})
    assert {:error, :guest_pow_invalid} = GuestMode.create_guest(%{"pow" => solved})
  end

  test "guest creation stops at the daily limit" do
    enable_guest_mode!()
    {:ok, policy} = GuestMode.get_policy()

    {:ok, _policy} =
      GuestMode.update_policy(%{"daily_creation_limit" => 0, "revision" => policy["revision"]})

    assert {:error, :guest_daily_limit} = GuestMode.create_guest(%{"pow" => solved_pow()})
  end

  test "registered accounts cannot use the guest placeholder domain" do
    assert {:error, :not_found} =
             Accounts.get_or_create_user_by_email("someone@guest.comma.invalid")

    assert {:error, :invalid_email} =
             Accounts.Email.normalize_recipient("someone@guest.comma.invalid")
  end

  defp enable_guest_mode! do
    {:ok, policy} = GuestMode.get_policy()
    {:ok, policy} = GuestMode.create_tenant(%{"revision" => policy["revision"]})
    {:ok, policy} = GuestMode.update_policy(%{"enabled" => true, "revision" => policy["revision"]})
    policy["salix_tenant_id"]
  end

  defp create_guest!, do: create_guest_session!()["user"] |> then(&elem(Accounts.get_user(&1["id"]), 1))

  defp create_guest_session! do
    assert {:ok, session} = GuestMode.create_guest(%{"pow" => solved_pow()})
    session
  end

  defp solved_pow do
    %{"enabled" => true, "pow" => %{"challenge" => challenge, "difficulty" => difficulty}} =
      GuestMode.public_status()

    nonce =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&Integer.to_string/1)
      |> Enum.find(fn nonce ->
        :crypto.hash(:sha256, challenge <> ":" <> nonce)
        |> Comma.GuestPow.leading_zero_bits() >= difficulty
      end)

    %{"challenge" => challenge, "nonce" => nonce}
  end

  defp unique, do: System.unique_integer([:positive])

  defp wrong_nonce(%{"challenge" => challenge}) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&Integer.to_string/1)
    |> Enum.find(fn nonce ->
      Comma.GuestPow.leading_zero_bits(:crypto.hash(:sha256, challenge <> ":" <> nonce)) == 0
    end)
  end
end
