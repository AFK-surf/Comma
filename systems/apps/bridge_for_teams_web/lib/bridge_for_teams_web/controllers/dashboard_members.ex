defmodule BridgeForTeamsWeb.DashboardMembers do
  @moduledoc """
  Builds the Members page payloads and applies member writes for
  `DashboardAPIController`.

  Every org member may read the list. Only owners and admins may write. Only
  owners may grant or revoke the owner role, and the last owner can be neither
  demoted nor removed. A refused write by a non-admin records a denied audit
  entry, as the LiveView page did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Accounts, Memberships, Observability}

  @roles ~w(owner admin member)
  @admin_roles ~w(owner admin)
  @email_pattern ~r/^[^\s@]+@[^\s@]+$/

  @doc "The Members page payload: the caller's permissions and the member list."
  def page(org, user, role) do
    %{
      "viewer" => %{
        "user_id" => user.id,
        "role" => role,
        "can_manage" => role in @admin_roles,
        "can_grant_owner" => role == "owner"
      },
      "members" => org.id |> Memberships.list_org_members() |> Enum.map(&public_member/1)
    }
  end

  @doc "Add a user (found or created by email) to the org with `role`."
  def invite(org, user, role, params) do
    email = params |> Map.get("email") |> normalize_email()
    new_role = Map.get(params, "role") || "member"

    cond do
      role not in @admin_roles ->
        record_denied(org, user, "org_member.granted", nil, %{
          "attempted_email_configured" => email != "",
          "attempted_role" => text(new_role)
        })

        forbidden(gettext("Only organization admins can invite members."))

      not Regex.match?(@email_pattern, email) ->
        {:error, 422, "invalid_email", gettext("Enter a valid email address."), %{}}

      new_role not in @roles ->
        invalid_role()

      new_role == "owner" and role != "owner" ->
        owner_required()

      true ->
        with {:ok, invitee} <- find_or_create_user(email),
             :ok <- ensure_not_member(org, invitee),
             {:ok, _membership} <-
               Memberships.put_org_member(org.id, invitee.id, new_role, audit_opts(user)) do
          :ok
        else
          {:error, 409, _code, _message, _details} = error -> error
          {:error, _reason} -> write_failed(gettext("Couldn't add %{email}.", email: email))
        end
    end
  end

  @doc "Change one member's role."
  def change_role(org, user, role, target_user_id, params) do
    new_role = Map.get(params, "role")

    with :ok <-
           authorize_write(org, user, role, "org_member.role_changed", target_user_id, %{
             "target_user_id_configured" => present?(target_user_id),
             "attempted_role" => text(new_role)
           }),
         :ok <- validate_role(new_role),
         {:ok, member_role} <- member_role(org, target_user_id),
         :ok <- authorize_owner_change(role, member_role, new_role),
         :ok <- ensure_owner_remains(org, member_role, new_role) do
      if member_role == new_role do
        :ok
      else
        case Memberships.put_org_member(org.id, target_user_id, new_role, audit_opts(user)) do
          {:ok, _membership} -> :ok
          {:error, _reason} -> write_failed(gettext("Couldn't update role."))
        end
      end
    end
  end

  @doc "Remove one member from the org."
  def remove(org, user, role, target_user_id) do
    with :ok <-
           authorize_write(org, user, role, "org_member.removed", target_user_id, %{
             "target_user_id_configured" => present?(target_user_id)
           }),
         {:ok, member_role} <- member_role(org, target_user_id),
         :ok <- authorize_owner_change(role, member_role, nil),
         :ok <- ensure_owner_remains(org, member_role, nil) do
      case Memberships.remove_org_member(org.id, target_user_id, audit_opts(user)) do
        :ok -> :ok
        {:error, :not_found} -> member_not_found()
        {:error, _reason} -> write_failed(gettext("Couldn't remove member."))
      end
    end
  end

  defp authorize_write(_org, _user, role, _action, _target, _metadata) when role in @admin_roles,
    do: :ok

  defp authorize_write(org, user, _role, action, target_user_id, metadata) do
    record_denied(org, user, action, uuid_or_nil(target_user_id), metadata)

    message =
      case action do
        "org_member.role_changed" -> gettext("Only organization admins can change roles.")
        _removed -> gettext("Only organization admins can remove members.")
      end

    forbidden(message)
  end

  defp validate_role(role) when role in @roles, do: :ok
  defp validate_role(_role), do: invalid_role()

  # Granting or revoking the owner role changes who controls the org, so it
  # needs an owner; an admin may still manage admins and members.
  defp authorize_owner_change("owner", _member_role, _new_role), do: :ok

  defp authorize_owner_change(_role, member_role, new_role)
       when member_role == "owner" or new_role == "owner",
       do: owner_required()

  defp authorize_owner_change(_role, _member_role, _new_role), do: :ok

  defp ensure_owner_remains(org, "owner", new_role) when new_role != "owner" do
    if Memberships.count_org_owners(org.id) <= 1 do
      message =
        if new_role,
          do: gettext("Can't demote the last owner."),
          else: gettext("Can't remove the last owner.")

      {:error, 409, "last_owner", message, %{}}
    else
      :ok
    end
  end

  defp ensure_owner_remains(_org, _member_role, _new_role), do: :ok

  defp member_role(org, user_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         {:ok, role} <- Memberships.org_role(org.id, user_id) do
      {:ok, role}
    else
      _ -> member_not_found()
    end
  end

  defp ensure_not_member(org, invitee) do
    case Memberships.org_role(org.id, invitee.id) do
      {:ok, _role} ->
        {:error, 409, "already_member",
         gettext("%{email} is already a member. Change their role instead.",
           email: invitee.email
         ), %{}}

      {:error, :not_found} ->
        :ok
    end
  end

  defp find_or_create_user(email) do
    case Accounts.get_user_by_email(email) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> Accounts.create_user(%{"email" => email})
    end
  end

  defp public_member(membership) do
    user = membership.user
    identity = primary_sso_identity(user)

    %{
      "user_id" => membership.user_id,
      "name" => display_name(user, identity),
      "email" => trimmed(user.email),
      "mobile" => identity && trimmed(identity.mobile),
      "role" => membership.role,
      "joined_at" => membership.created_at,
      "sso" => not is_nil(identity),
      "sso_provider" => identity && identity.provider
    }
  end

  defp display_name(user, identity) do
    trimmed(user.name) || (identity && trimmed(identity.display_name)) || trimmed(user.email)
  end

  # Feishu first: phone-only Feishu users have no email, only this identity.
  defp primary_sso_identity(%{org_sso_identities: identities}) when is_list(identities) do
    identities
    |> Enum.sort_by(&if(&1.provider == "feishu", do: 0, else: 1))
    |> List.first()
  end

  defp primary_sso_identity(_user), do: nil

  defp record_denied(org, user, action, resource_id, metadata) do
    _ =
      Observability.record_write_attempt(%{
        org_id: org.id,
        actor_user_id: user.id,
        actor_label: actor_label(user),
        action: action,
        resource_type: "org_member",
        resource_id: resource_id,
        resource_label: resource_label(resource_id),
        result: "denied",
        reason: :forbidden,
        request_id: Ecto.UUID.generate(),
        surface: "members",
        metadata: metadata
      })

    :ok
  end

  defp resource_label(nil), do: "Org member write attempt"
  defp resource_label(user_id), do: "Org member #{String.slice(user_id, 0, 8)}"

  defp audit_opts(user) do
    [actor_user_id: user.id, actor_label: actor_label(user), request_id: Ecto.UUID.generate()]
  end

  defp actor_label(user), do: trimmed(user.email) || trimmed(user.name) || user.id

  defp uuid_or_nil(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp normalize_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalize_email(_email), do: ""

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil

  defp present?(value), do: not is_nil(trimmed(value))

  defp forbidden(message), do: {:error, 403, "forbidden", message, %{}}

  defp owner_required,
    do:
      {:error, 403, "owner_required", gettext("Only owners can grant or remove the owner role."),
       %{}}

  defp invalid_role,
    do: {:error, 422, "invalid_role", gettext("Role must be owner, admin or member."), %{}}

  defp member_not_found, do: {:error, 404, "member_not_found", gettext("Member not found."), %{}}

  defp write_failed(message), do: {:error, 500, "write_failed", message, %{}}
end
