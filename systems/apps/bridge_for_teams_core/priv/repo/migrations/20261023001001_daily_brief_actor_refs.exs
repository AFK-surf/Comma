defmodule BridgeForTeams.Repo.Migrations.DailyBriefActorRefs do
  use Ecto.Migration

  # People in daily brief rows are source-qualified actor refs ("slack:U123")
  # instead of bare Slack ids, so a second source cannot collide with Slack.
  # Existing rows are all from Slack and are rewritten once.
  def up do
    rename table(:daily_brief_followups), :owner_slack_id, to: :owner_actor_ref
    rename table(:daily_brief_followups), :waiting_on_slack_id, to: :waiting_on_actor_ref

    execute """
    UPDATE daily_brief_followups SET
      owner_actor_ref = 'slack:' || owner_actor_ref
    WHERE owner_actor_ref IS NOT NULL AND position(':' in owner_actor_ref) = 0
    """

    execute """
    UPDATE daily_brief_followups SET
      waiting_on_actor_ref = 'slack:' || waiting_on_actor_ref
    WHERE waiting_on_actor_ref IS NOT NULL AND position(':' in waiting_on_actor_ref) = 0
    """

    execute """
    UPDATE daily_brief_events SET author_ref = 'slack:' || author_ref
    WHERE source = 'slack' AND author_ref IS NOT NULL AND position(':' in author_ref) = 0
    """
  end

  def down do
    execute """
    UPDATE daily_brief_events SET author_ref = substr(author_ref, 7)
    WHERE source = 'slack' AND author_ref LIKE 'slack:%'
    """

    execute """
    UPDATE daily_brief_followups SET
      owner_actor_ref = CASE WHEN owner_actor_ref LIKE 'slack:%'
        THEN substr(owner_actor_ref, 7) ELSE NULL END,
      waiting_on_actor_ref = CASE WHEN waiting_on_actor_ref LIKE 'slack:%'
        THEN substr(waiting_on_actor_ref, 7) ELSE NULL END
    """

    rename table(:daily_brief_followups), :waiting_on_actor_ref, to: :waiting_on_slack_id
    rename table(:daily_brief_followups), :owner_actor_ref, to: :owner_slack_id
  end
end
