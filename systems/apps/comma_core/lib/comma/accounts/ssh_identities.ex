defmodule Comma.Accounts.SSHIdentities do
  @moduledoc "Account-owned SSH login identities. Revocation preserves the key binding."
  import Ecto.Query
  alias Comma.Accounts.{Identity, User}
  alias Comma.{Accounts, Repo}
  @issuer "comma:ssh"

  def fingerprint(blob),
    do: "SHA256:" <> Base.encode64(:crypto.hash(:sha256, blob), padding: false)

  def lookup(blob) do
    case Repo.get_by(Identity, provider: "ssh", issuer: @issuer, subject: fingerprint(blob)) do
      nil -> {:error, :unknown_key}
      %{public_key: ^blob, disabled_at: nil} = identity -> {:ok, identity}
      _ -> {:error, :revoked}
    end
  end

  def enroll(user, blob) when is_binary(blob) and byte_size(blob) in 32..16384 do
    Repo.transaction(fn ->
      owner = Repo.one!(from(u in User, where: u.id == ^user["id"], lock: "FOR UPDATE"))
      if owner.status != "active", do: Repo.rollback(:disabled)

      case lookup(blob) do
        {:ok, %{user_id: id} = identity} when id == owner.id ->
          identity

        {:error, :unknown_key} ->
          count =
            Repo.aggregate(
              from(i in Identity, where: i.user_id == ^owner.id and i.provider == "ssh"),
              :count
            )

          if count >= 50, do: Repo.rollback(:key_limit)

          attrs = %{
            user_id: owner.id,
            provider: "ssh",
            issuer: @issuer,
            subject: fingerprint(blob),
            public_key: blob,
            email_snapshot: owner.email,
            email_verified: true,
            last_authenticated_at: DateTime.utc_now()
          }

          case Repo.insert(Identity.changeset(%Identity{}, attrs)) do
            {:ok, identity} -> identity
            {:error, _} -> Repo.rollback(:key_conflict)
          end

        _ ->
          Repo.rollback(:key_conflict)
      end
    end)
  end

  def login(blob) do
    with {:ok, identity} <- lookup(blob),
         {:ok, session} <-
           Accounts.create_session(identity.user_id,
             auth_method: "ssh_public_key",
             client_kind: "ssh",
             device_label: "Comma SSH",
             login_identity_id: identity.id,
             ttl_seconds: 12 * 60 * 60
           ),
         {:ok, _user, _session} <- Accounts.resolve_session(session["token"]) do
      Repo.update_all(from(i in Identity, where: i.id == ^identity.id),
        set: [last_authenticated_at: DateTime.utc_now()]
      )

      {:ok, session["token"]}
    end
  end

  def list(user_id) do
    Repo.all(
      from(i in Identity,
        where: i.user_id == ^user_id and i.provider == "ssh",
        order_by: [desc: i.created_at],
        limit: 50
      )
    )
    |> Enum.map(
      &%{
        id: &1.id,
        fingerprint: &1.subject,
        label: &1.label,
        revoked_at: &1.disabled_at,
        last_used_at: &1.last_authenticated_at
      }
    )
  end

  def revoke(user_id, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id) do
      {count, _} =
        Repo.update_all(
          from(i in Identity,
            where: i.user_id == ^user_id and i.id == ^uuid and i.provider == "ssh"
          ),
          set: [disabled_at: DateTime.utc_now()]
        )

      if count == 1, do: :ok, else: {:error, :not_found}
    else
      _ -> {:error, :not_found}
    end
  end
end
