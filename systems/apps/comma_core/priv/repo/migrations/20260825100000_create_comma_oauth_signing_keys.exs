defmodule Comma.Repo.Migrations.CreateCommaOauthSigningKeys do
  use Ecto.Migration

  def change do
    create table(:comma_oauth_signing_keys, primary_key: false) do
      # The kid is the public identifier clients see in id_token headers
      # and JWKS entries; it is the natural primary key.
      add(:kid, :string, primary_key: true)
      # Public half, published verbatim in the JWKS.
      add(:public_pem, :text, null: false)
      # Private half, AES-256-GCM ciphertext under the deployment key
      # encryption key. A database read alone yields no usable signer.
      add(:private_pem_ciphertext, :binary, null: false)
      add(:private_pem_iv, :binary, null: false)
      add(:private_pem_tag, :binary, null: false)
      # Exactly one row may be "signing"; every other row is
      # "verify_only" and exists so tokens issued under it keep
      # verifying until they expire.
      add(:status, :string, null: false)
      add(:retire_after, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
    end

    create(
      constraint(:comma_oauth_signing_keys, :comma_oauth_signing_keys_status_valid,
        check: "status in ('signing', 'pending', 'verify_only')"
      )
    )

    # At most one signing key and at most one pending key, enforced by
    # the database rather than by application discipline: a second row of
    # either status cannot be created even under concurrent admin
    # commands.
    create(
      unique_index(:comma_oauth_signing_keys, [:status],
        where: "status = 'signing'",
        name: :comma_oauth_signing_keys_one_signing
      )
    )

    create(
      unique_index(:comma_oauth_signing_keys, [:status],
        where: "status = 'pending'",
        name: :comma_oauth_signing_keys_one_pending
      )
    )
  end
end
