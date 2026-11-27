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

  test "list_recent_group returns newest projections first, supports keyset cursor, and reports truncation" do
    Repo.query!("""
    INSERT INTO meeting_group_projections (meeting_id, group_id, inserted_at)
    VALUES
      ('mtg-z-oldest', 'group-r', now() - interval '3 days'),
      ('mtg-a-middle', 'group-r', now() - interval '2 days'),
      ('mtg-m-newest', 'group-r', now() - interval '1 day'),
      ('mtg-other', 'group-other', now())
    """)

    assert {:ok,
            %{
              meeting_ids: ["mtg-m-newest", "mtg-a-middle"],
              truncated: true,
              next_cursor: %{inserted_at: %DateTime{}, meeting_id: "mtg-a-middle"} = cursor
            }} =
             MeetingGroupProjections.list_recent_group("group-r", limit: 2)

    assert {:ok, %{meeting_ids: ["mtg-z-oldest"], truncated: false, next_cursor: nil}} =
             MeetingGroupProjections.list_recent_group("group-r", limit: 2, cursor: cursor)

    assert {:ok,
            %{
              meeting_ids: ["mtg-m-newest", "mtg-a-middle", "mtg-z-oldest"],
              truncated: false,
              next_cursor: nil
            }} =
             MeetingGroupProjections.list_recent_group("group-r", limit: 10)

    assert {:error, :invalid} = MeetingGroupProjections.list_recent_group("group-r", limit: 0)

    assert {:error, :invalid} =
             MeetingGroupProjections.list_recent_group("group-r", limit: 2, cursor: "bad")
  end
end
