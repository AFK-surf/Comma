defmodule SalixStore.SlackTriageChannelCutoverTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Repo, SlackTriageChannelCutover}

  setup do
    Repo.query!("""
    DELETE FROM salix_cutover_markers
    WHERE name IN ('slack_triage_channels_v1', 'slack_triage_channels_v1_preparing')
    """)

    on_exit(fn -> seed_ready_marker() end)
    :ok
  end

  test "the barrier freezes in-flight writers before binding exact rollout evidence" do
    assert :legacy = SlackTriageChannelCutover.mode()
    assert {:error, :invalid_evidence} = SlackTriageChannelCutover.mark_ready(%{})
    assert :legacy = SlackTriageChannelCutover.mode()

    parent = self()

    writer =
      Task.async(fn ->
        SlackTriageChannelCutover.with_authority_write(fn ->
          send(parent, :writer_entered)
          receive do: (:release_writer -> :written)
        end)
      end)

    assert_receive :writer_entered

    freezer = Task.async(fn -> SlackTriageChannelCutover.begin_preparing(preparation()) end)
    assert nil == Task.yield(freezer, 50)

    send(writer.pid, :release_writer)
    assert :written = Task.await(writer)
    assert {:ok, "release-2026-08-21"} = Task.await(freezer)

    assert :legacy = SlackTriageChannelCutover.mode()

    assert {:error, :slack_triage_channel_cutover_pending} =
             SlackTriageChannelCutover.with_authority_write(fn -> :must_not_run end)

    assert {:error, :invalid_evidence} =
             SlackTriageChannelCutover.mark_ready(readiness("a-different-preparation"))

    assert :ok = SlackTriageChannelCutover.mark_ready(readiness())

    assert :projected = SlackTriageChannelCutover.mode()

    assert :written_after_cutover =
             SlackTriageChannelCutover.with_authority_write(fn -> :written_after_cutover end)

    assert :ok = SlackTriageChannelCutover.mark_ready(readiness())

    assert :projected = SlackTriageChannelCutover.mode()
  end

  defp preparation do
    %{
      "schema_version" => 1,
      "preparation_id" => "release-2026-08-21",
      "all_readers_current" => true,
      "old_control_writers_retired" => true
    }
  end

  defp readiness(preparation_id \\ "release-2026-08-21") do
    preparation()
    |> Map.put("preparation_id", preparation_id)
    |> Map.merge(%{
      "legacy_rows_materialized" => true,
      "generation_fences_verified" => true
    })
  end

  defp seed_ready_marker do
    Repo.query!("""
    INSERT INTO salix_cutover_markers (name, completed_at, evidence)
    VALUES ('slack_triage_channels_v1', now(), '{"mode":"test-baseline"}'::jsonb)
    ON CONFLICT (name) DO NOTHING
    """)
  end
end
