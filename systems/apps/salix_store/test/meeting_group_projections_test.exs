defmodule SalixStore.MeetingGroupProjectionsTest do
  use SystemsClock.Case, async: false

  alias SalixStore.{MeetingGroupProjections, Repo}

  setup do
    Repo.query!("TRUNCATE meeting_group_projections")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'meeting_group_projection_v1'")

    on_exit(fn ->
      Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('meeting_group_projection_v1', now(), '{"mode":"test-baseline"}'::jsonb)
      ON CONFLICT (name) DO NOTHING
      """)
    end)

    :ok
  end

  test "one meeting has one stable group projection" do
    assert :ok = MeetingGroupProjections.ensure("group-a", "meeting-1")
    assert :ok = MeetingGroupProjections.ensure("group-a", "meeting-1")

    assert {:error, :identity_conflict} =
             MeetingGroupProjections.ensure("group-b", "meeting-1")

    assert {:ok, %{meeting_ids: ["meeting-1"], truncated: false}} =
             MeetingGroupProjections.list_group("group-a", limit: 10)
  end
end
