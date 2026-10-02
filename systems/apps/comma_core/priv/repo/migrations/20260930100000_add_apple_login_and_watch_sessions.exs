defmodule Comma.Repo.Migrations.AddAppleLoginAndWatchSessions do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '5s'")

    alter table(:comma_auth_sessions) do
      add(:parent_session_id, references(:comma_auth_sessions, type: :uuid, on_delete: :restrict))
    end

    create(index(:comma_auth_sessions, [:parent_session_id]))

    drop(constraint(:comma_user_identities, :comma_user_identities_provider_valid))

    create(
      constraint(:comma_user_identities, :comma_user_identities_provider_valid,
        check: "provider IN ('google', 'apple', 'ssh')"
      )
    )

    create(
      unique_index(:comma_user_identities, [:user_id, :provider],
        name: :comma_user_identities_apple_owner_unique,
        where: "provider = 'apple'"
      )
    )

    # The Apple/Watch login methods join the source-method check in
    # 20261001100000, after guest mode. Rebuilding it here would drop 'guest' and
    # revalidate every session where guest mode already ran.

    # The iOS/Watch client kinds join the client-kind check in 20261002100001,
    # after Android, so neither migration drops the other's kinds.

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_watch_parent_valid,
        check:
          "(auth_method = 'watch_pairing' AND parent_session_id IS NOT NULL AND NOT restricted AND session_source = 'user_login') OR (auth_method IS DISTINCT FROM 'watch_pairing' AND parent_session_id IS NULL)"
      )
    )

    create(
      constraint(:comma_auth_sessions, :comma_auth_sessions_apple_identity_required,
        check: "auth_method != 'apple' OR login_identity_id IS NOT NULL"
      )
    )
  end

  def down, do: raise("Apple login identities and paired Watch sessions require forward repair")
end
