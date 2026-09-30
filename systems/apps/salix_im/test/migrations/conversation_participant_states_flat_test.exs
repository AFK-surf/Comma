defmodule SalixIM.Migrations.ConversationParticipantStatesFlatTest do
  use ExUnit.Case, async: false

  defmodule UnderfilledListBackend do
    defdelegate put(key, body, opts), to: SalixStore.S3.Fake
    defdelegate get(key, opts), to: SalixStore.S3.Fake
    defdelegate head(key), to: SalixStore.S3.Fake
    defdelegate delete(key, opts), to: SalixStore.S3.Fake

    def list(prefix, opts) do
      page_opts = if opts[:start_after], do: opts, else: Keyword.put(opts, :max_keys, 1)
      SalixStore.S3.Fake.list(prefix, page_opts)
    end
  end

  defmodule TruncatedEmptyListBackend do
    def list(_prefix, _opts), do: {:ok, %{objects: [], next: "unexpected-continuation"}}
  end

  alias SalixIM.Migrations.ConversationParticipantStatesFlat
  alias SalixIM.Release
  alias SalixStore.{Keys, S3}

  @group_id "grp1_1000000000000000001_1000000000000000002"
  @conversation_id "cnv1_1000000000000000003"
  @participant_id "ptp1_1000000000000000004"

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> restore(:salix_store, :s3_backend, previous) end)
  end

  test "moves nested participant state to the bounded flat projection" do
    participant = %{
      "participant_id" => @participant_id,
      "conversation_id" => @conversation_id,
      "actor_type" => "agent",
      "state" => "active"
    }

    old_key =
      Keys.ctl_group_conversation_participant_dir(
        @group_id,
        @conversation_id,
        @participant_id
      ) <> "state.json"

    new_key =
      Keys.ctl_group_conversation_participant_state(
        @group_id,
        @conversation_id,
        @participant_id
      )

    assert {:ok, _} = S3.put(old_key, Jason.encode!(participant))

    assert {:ok, stats} = ConversationParticipantStatesFlat.run(limit: 20)
    assert stats.migrated == 1
    assert stats.failed == []
    assert {:error, :not_found} = S3.get(old_key)
    assert {:ok, %{body: body}} = S3.get(new_key)
    assert Jason.decode!(body) == participant

    assert {:ok, rerun} = ConversationParticipantStatesFlat.run(limit: 20)
    assert rerun.migrated == 0
    assert rerun.failed == []
  end

  test "release cutover requires the no-writer gate and follows an underfilled truncated page" do
    participants =
      for index <- 4..6 do
        participant_id = "ptp1_100000000000000000#{index}"

        participant = %{
          "participant_id" => participant_id,
          "conversation_id" => @conversation_id,
          "actor_type" => "agent",
          "state" => "active"
        }

        assert {:ok, _} = S3.put(old_key(participant_id), Jason.encode!(participant))
        participant
      end

    assert_raise RuntimeError, ~r/confirm_no_writers/, fn ->
      Release.migrate_conversation_participant_states()
    end

    Application.put_env(:salix_store, :s3_backend, UnderfilledListBackend)
    test_pid = self()

    stats =
      Release.migrate_conversation_participant_states(
        confirm_no_writers: true,
        limit: 20,
        ensure_started: fn app ->
          send(test_pid, {:started, app})
          {:ok, []}
        end
      )

    assert_received {:started, :salix_store}
    refute_received {:started, _other}
    assert stats.migrated == 3
    assert stats.pages > 1
    assert stats.complete

    Enum.each(participants, fn participant ->
      participant_id = participant["participant_id"]
      assert {:error, :not_found} = S3.get(old_key(participant_id))
      assert {:ok, %{body: body}} = S3.get(new_key(participant_id))
      assert Jason.decode!(body) == participant
    end)
  end

  test "release cutover fails nonzero on a divergent destination" do
    old = %{
      "participant_id" => @participant_id,
      "conversation_id" => @conversation_id,
      "state" => "active"
    }

    new = Map.put(old, "state", "inactive")

    old_key = old_key(@participant_id)
    new_key = new_key(@participant_id)

    assert {:ok, _} = S3.put(old_key, Jason.encode!(old))
    assert {:ok, _} = S3.put(new_key, Jason.encode!(new))

    assert_raise RuntimeError, ~r/participant-state cutover failed/, fn ->
      Release.migrate_conversation_participant_states(
        confirm_no_writers: true,
        ensure_started: fn :salix_store -> {:ok, []} end
      )
    end

    assert {:ok, _} = S3.get(old_key)
    assert {:ok, %{body: body}} = S3.get(new_key)
    assert Jason.decode!(body) == new
  end

  test "fails closed when a truncated page contains no cursor-bearing object" do
    Application.put_env(:salix_store, :s3_backend, TruncatedEmptyListBackend)

    assert {:error, {:participant_state_migration_failed, stats}} =
             ConversationParticipantStatesFlat.run()

    assert stats.pages == 1
    assert stats.list_error == :truncated_empty_page
    refute stats.complete
  end

  defp old_key(participant_id) do
    Keys.ctl_group_conversation_participant_dir(
      @group_id,
      @conversation_id,
      participant_id
    ) <> "state.json"
  end

  defp new_key(participant_id) do
    Keys.ctl_group_conversation_participant_state(
      @group_id,
      @conversation_id,
      participant_id
    )
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
