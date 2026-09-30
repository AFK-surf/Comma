defmodule BridgeForTeams.Repo.Migrations.CreateProjectKnowledge do
  use Ecto.Migration

  def up do
    create table(:project_knowledge_aliases, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:project_id, references(:projects, type: :uuid, on_delete: :restrict), null: false)
      add(:entity_kind, :text, null: false)
      add(:user_id, references(:users, type: :uuid, on_delete: :restrict))
      add(:target_project_id, references(:projects, type: :uuid, on_delete: :restrict))
      add(:alias, :text, null: false)
      add(:normalized_alias, :text, null: false)
      add(:source_type, :text, null: false)
      add(:source_ref, :text, null: false)

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create(
      constraint(:project_knowledge_aliases, :project_knowledge_aliases_typed_target,
        check: """
        (entity_kind = 'person' AND user_id IS NOT NULL AND target_project_id IS NULL) OR
        (entity_kind = 'project' AND user_id IS NULL AND target_project_id IS NOT NULL)
        """
      )
    )

    create(
      constraint(:project_knowledge_aliases, :project_knowledge_aliases_normalized,
        check: "normalized_alias = lower(btrim(alias)) AND normalized_alias <> ''"
      )
    )

    create(
      unique_index(
        :project_knowledge_aliases,
        [:project_id, :user_id, :normalized_alias],
        where: "entity_kind = 'person'",
        name: :project_knowledge_aliases_person_identity_idx
      )
    )

    create(
      unique_index(
        :project_knowledge_aliases,
        [:project_id, :target_project_id, :normalized_alias],
        where: "entity_kind = 'project'",
        name: :project_knowledge_aliases_project_identity_idx
      )
    )

    create(
      index(:project_knowledge_aliases, [:project_id, :normalized_alias],
        name: :project_knowledge_aliases_lookup_idx
      )
    )

    create table(:project_knowledge_assertions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:project_id, references(:projects, type: :uuid, on_delete: :restrict), null: false)
      add(:kind, :text, null: false)
      add(:content, :text, null: false)
      add(:source_type, :text, null: false)
      add(:source_ref, :text, null: false)
      add(:observed_at, :utc_datetime_usec, null: false)

      add(
        :supersedes_id,
        references(:project_knowledge_assertions, type: :uuid, on_delete: :restrict)
      )

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create(
      constraint(:project_knowledge_assertions, :project_knowledge_assertions_kind,
        check: "kind IN ('decision', 'fact')"
      )
    )

    create(
      constraint(:project_knowledge_assertions, :project_knowledge_assertions_content,
        check: "btrim(content) <> '' AND btrim(source_ref) <> ''"
      )
    )

    create(
      unique_index(
        :project_knowledge_assertions,
        [:project_id, :kind, :source_type, :source_ref],
        name: :project_knowledge_assertions_source_idx
      )
    )

    create(
      index(:project_knowledge_assertions, [:project_id, :observed_at],
        name: :project_knowledge_assertions_observed_idx
      )
    )

    create table(:project_knowledge_assertion_subjects, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :assertion_id,
        references(:project_knowledge_assertions, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:user_id, references(:users, type: :uuid, on_delete: :restrict))
      add(:target_project_id, references(:projects, type: :uuid, on_delete: :restrict))

      timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
    end

    create(
      constraint(
        :project_knowledge_assertion_subjects,
        :project_knowledge_assertion_subjects_typed_target,
        check: "num_nonnulls(user_id, target_project_id) = 1"
      )
    )

    create(
      unique_index(
        :project_knowledge_assertion_subjects,
        [:assertion_id, :user_id],
        where: "user_id IS NOT NULL",
        name: :project_knowledge_assertion_subjects_person_idx
      )
    )

    create(
      unique_index(
        :project_knowledge_assertion_subjects,
        [:assertion_id, :target_project_id],
        where: "target_project_id IS NOT NULL",
        name: :project_knowledge_assertion_subjects_project_idx
      )
    )

    create(index(:project_knowledge_assertion_subjects, [:user_id]))
    create(index(:project_knowledge_assertion_subjects, [:target_project_id]))

    execute("""
    CREATE FUNCTION reject_project_knowledge_mutation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RAISE EXCEPTION 'project knowledge records are append-only';
    END;
    $$
    """)

    for table <- [
          :project_knowledge_aliases,
          :project_knowledge_assertions,
          :project_knowledge_assertion_subjects
        ] do
      execute("""
      CREATE TRIGGER #{table}_append_only
      BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION reject_project_knowledge_mutation()
      """)
    end
  end

  def down do
    drop(table(:project_knowledge_assertion_subjects))
    drop(table(:project_knowledge_assertions))
    drop(table(:project_knowledge_aliases))
    execute("DROP FUNCTION reject_project_knowledge_mutation()")
  end
end
