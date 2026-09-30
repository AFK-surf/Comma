defmodule SalixStore.Repo.Migrations.CreateIfcProjections do
  use Ecto.Migration

  # Information-flow integrity (docs/salix/information-flow-integrity.md §3.6,
  # §8). Three operator-owned configuration tables, two provider-observed
  # projections, and the declassification receipts. Everything here is a fact
  # the pure kernel reads; no content is ever stored.
  def change do
    # Operator classification of one provider conversation: tags, audience
    # mode, sealed. `revision` is echoed into an archived decision so a stored
    # verdict names the configuration it was made under.
    create table(:ifc_scope_labels, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:scope_id, :text, primary_key: true)
      add(:tags, {:array, :text}, null: false, default: [])
      add(:audience_mode, :text, null: false, default: "space")
      add(:sealed, :boolean, null: false, default: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    # A user label is a clearance, never a classification: it says what the
    # person may read and never changes what they write.
    create table(:ifc_tag_clearances, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:tag, :text, primary_key: true)
      add(:principal_key, :text, primary_key: true)
      add(:revision, :bigint, null: false, default: 1)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(index(:ifc_tag_clearances, [:tenant_id, :group_id, :connect_id, :tag]))

    # Operator override of the provider-derived internal/external placement.
    create table(:ifc_principal_facts, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:user_id, :text, primary_key: true)
      # What the provider said (guest flags, foreign team) and what an
      # administrator decided. The override wins; neither is guessed, because
      # a user nobody has placed must never read as an internal member.
      add(:placement_observed, :text)
      add(:placement_override, :text)
      add(:revision, :bigint, null: false, default: 1)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    # What a provider conversation structurally IS. `members_complete` is the
    # difference between "nobody is a member" and "we have not enumerated the
    # members", which the kernel must never confuse: incomplete membership is
    # unknown, and unknown denies.
    create table(:ifc_scope_facts, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:scope_id, :text, primary_key: true)
      add(:kind, :text, null: false)
      add(:within_scope_id, :text)
      # A one-to-one conversation is named by its counterpart, not by the
      # channel the provider happened to open: the same audience must get the
      # same atom whether it is reached by channel id or by user id.
      add(:canonical_scope_id, :text)
      # Shown to people in a refusal or a provenance footer, never to the
      # kernel: it compares opaque ids only.
      add(:display_name, :text)
      add(:members_complete, :boolean, null: false, default: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:observed_at, :utc_datetime_usec, null: false)
    end

    # One row per member. Bootstrapped from the provider's member listing for
    # the conversations the bot is in, then maintained from join/leave events.
    create table(:ifc_scope_members, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:connect_id, :text, primary_key: true)
      add(:scope_id, :text, primary_key: true)
      add(:member_key, :text, primary_key: true)
      add(:observed_at, :utc_datetime_usec, null: false)
    end

    # Human declassification receipts. TTL-bounded, per requester, never S3.
    create table(:ifc_receipts, primary_key: false) do
      add(:tenant_id, :text, primary_key: true)
      add(:group_id, :text, primary_key: true)
      add(:receipt_id, :text, primary_key: true)
      add(:requester_key, :text, null: false)
      add(:source_atoms, {:array, :text}, null: false)
      add(:destination_atoms, {:array, :text}, null: false)
      add(:thread_ref, :text)
      add(:expires_at_ms, :bigint)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(index(:ifc_receipts, [:tenant_id, :group_id, :requester_key]))
    create(index(:ifc_receipts, [:expires_at_ms]))
  end
end
