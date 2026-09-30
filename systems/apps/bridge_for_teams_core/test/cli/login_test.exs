defmodule BridgeForTeams.CLI.LoginTest do
  use BridgeForTeams.DataCase, async: true

  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Memberships
  alias BridgeForTeams.Schema.{Organization, User}

  defp user! do
    %User{}
    |> User.changeset(%{
      email: "cli-login-#{System.unique_integer([:positive])}@example.test",
      name: "CLI User"
    })
    |> Repo.insert!()
  end

  defp org_with_owner!(user) do
    suffix = System.unique_integer([:positive])

    org =
      %Organization{}
      |> Organization.changeset(%{
        "name" => "CLI Org #{suffix}",
        "slug" => "cli-org-#{suffix}",
        "billing_account_id" => "billing_cli_org_#{suffix}",
        "salix_tenant_id" => SalixStore.Ids.new_tenant_id()
      })
      |> Repo.insert!()

    {:ok, _membership} = Memberships.put_org_member(org.id, user.id, "owner")
    org
  end

  test "device authorization is not an authenticated CLI session until approved and consumed" do
    user = user!()
    org = org_with_owner!(user)

    assert {:ok,
            %{
              device_code: device_code,
              authorization: authorization,
              interval_seconds: interval_seconds
            }} =
             CLILogin.start_device_authorization(%{client_name: "agent laptop"})

    assert is_binary(device_code)
    assert authorization.status == "pending"
    assert authorization.client_name == "agent laptop"
    assert interval_seconds > 0
    assert {:error, :invalid} = Sessions.fetch(device_code)

    assert {:ok, %{status: "pending"}} = CLILogin.poll_device_authorization(device_code)
    assert {:ok, approved} = CLILogin.approve_device_authorization(authorization.user_code, user)
    assert approved.status == "approved"
    assert approved.approved_by_user_id == user.id
    assert [%{org_id: org_id}] = approved.org_grants
    assert org_id == org.id

    assert {:ok,
            %{
              status: "approved",
              token: token,
              session: session,
              token_type: "bearer",
              granted_orgs: [granted_org]
            }} = CLILogin.poll_device_authorization(device_code)

    assert granted_org.id == org.id

    assert session.device == "bft-cli"
    assert session.client_name == "agent laptop"
    assert {:ok, fetched} = Sessions.fetch(token)
    assert fetched.id == session.id

    assert {:ok, %{status: "consumed"}} = CLILogin.poll_device_authorization(device_code)
  end

  test "cancelled device authorization never creates a CLI session" do
    user = user!()

    {:ok, %{device_code: device_code, authorization: authorization}} =
      CLILogin.start_device_authorization()

    assert {:ok, cancelled} = CLILogin.cancel_device_authorization(authorization.user_code, user)
    assert cancelled.status == "cancelled"
    assert cancelled.cancelled_by_user_id == user.id

    assert {:ok, cancelled_poll} = CLILogin.poll_device_authorization(device_code)
    assert cancelled_poll.status == "cancelled"
    refute Map.has_key?(cancelled_poll, :token)
  end

  test "approved device authorization cannot be cancelled before CLI consumption" do
    user = user!()
    _org = org_with_owner!(user)

    {:ok, %{device_code: device_code, authorization: authorization}} =
      CLILogin.start_device_authorization(%{client_name: "agent laptop"})

    assert {:ok, approved} = CLILogin.approve_device_authorization(authorization.user_code, user)
    assert approved.status == "approved"

    assert {:error, "approved"} =
             CLILogin.cancel_device_authorization(authorization.user_code, user)

    assert {:ok, %{status: "approved", token: token, session: session}} =
             CLILogin.poll_device_authorization(device_code)

    assert session.device == "bft-cli"
    assert {:ok, fetched} = Sessions.fetch(token)
    assert fetched.id == session.id
  end

  test "approved device authorization expires instead of returning server errors when approver is inactive" do
    user = user!()
    _org = org_with_owner!(user)

    {:ok, %{device_code: device_code, authorization: authorization}} =
      CLILogin.start_device_authorization(%{client_name: "agent laptop"})

    assert {:ok, %{status: "approved"}} =
             CLILogin.approve_device_authorization(authorization.user_code, user)

    user
    |> User.changeset(%{status: "inactive"})
    |> Repo.update!()

    assert {:ok, expired} = CLILogin.poll_device_authorization(device_code)
    assert expired.status == "expired"
    refute Map.has_key?(expired, :token)
  end

  test "expired device authorization never creates a CLI session" do
    {:ok, %{device_code: device_code, authorization: authorization}} =
      CLILogin.start_device_authorization()

    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    authorization
    |> Ecto.Changeset.change(expires_at: expired_at)
    |> Repo.update!()

    assert {:ok, expired_poll} = CLILogin.poll_device_authorization(device_code)
    assert expired_poll.status == "expired"
    refute Map.has_key?(expired_poll, :token)
  end

  test "lists and revokes CLI sessions for a user by session id" do
    user = user!()
    other = user!()

    {:ok, %{token: cli_token, session: cli_session}} =
      Sessions.create(user, device: "bft-cli", client_name: "workstation")

    {:ok, %{session: _web_session}} = Sessions.create(user, device: "web", client_name: "browser")
    {:ok, %{session: _other_cli_session}} = Sessions.create(other, device: "bft-cli")

    assert [%{id: id, client_name: "workstation"}] = CLILogin.list_cli_sessions(user)
    assert id == cli_session.id

    assert :ok = CLILogin.revoke_cli_session_for_user(user, cli_session.id)
    assert {:error, :invalid} = Sessions.fetch(cli_token)
    assert [] = CLILogin.list_cli_sessions(user)
  end
end
