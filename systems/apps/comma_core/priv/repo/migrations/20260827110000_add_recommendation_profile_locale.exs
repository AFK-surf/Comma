defmodule Comma.Repo.Migrations.AddRecommendationProfileLocale do
  use Ecto.Migration

  # The briefing renderer is an LLM with no language anchor: its run prompt is
  # machine-authored English, so the model mirrored whatever language dominated
  # the collected source facts. The client's language preference lived only in
  # localStorage and never reached the server, so an English UI could publish a
  # Chinese briefing. Persist the reported preference here because the daily
  # scheduled run fires with no client in the loop.
  #
  # NULL means "no client has reported a preference yet" and keeps the previous
  # unpinned behaviour rather than forcing a language onto an existing profile;
  # the next recommendations fetch fills it in.
  def change do
    alter table(:comma_recommendation_profiles) do
      add(:locale, :string)
    end
  end
end
