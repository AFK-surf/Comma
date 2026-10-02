defmodule Comma.Repo.Migrations.AddUserLocale do
  use Ecto.Migration

  # The account's app language. Before this, the only stored language was the
  # Routine profile's client-reported locale, so it seeds the account once,
  # from the member's most recently updated profile.
  def up do
    alter table(:comma_users) do
      add(:locale, :string)
    end

    create(
      constraint(:comma_users, :comma_users_locale_check, check: "locale IN ('en', 'zh-CN')")
    )

    execute("""
    UPDATE comma_users AS u
    SET locale = p.locale
    FROM (
      SELECT DISTINCT ON (user_id) user_id, locale
      FROM comma_recommendation_profiles
      WHERE locale IN ('en', 'zh-CN')
      ORDER BY user_id, updated_at DESC
    ) AS p
    WHERE p.user_id = u.id AND u.locale IS NULL
    """)
  end

  def down do
    drop(constraint(:comma_users, :comma_users_locale_check))

    alter table(:comma_users) do
      remove(:locale)
    end
  end
end
