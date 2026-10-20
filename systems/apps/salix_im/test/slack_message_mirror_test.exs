defmodule SalixIM.SlackMessageMirrorTest do
  use SystemsClock.Case, async: false
  use SalixStore.QueueCase, queues: [:slack_mirror_outbox, :slack_mirror_backfill]

  alias SalixIM.ProviderHTTP
  alias SalixIM.SlackMessageMirror
  alias SalixIM.SlackMessageMirror.{MetadataRow, PinRow, ReactionRow, Row}
  alias SalixStore.{CasRecord, Ids, Keys, Repo, S3, SlackMirrorBackfillLedger, SlackMirrorOutbox}

  defmodule TestMirror do
    @moduledoc false
    def record_batch(_rows), do: :ok
    def record_reaction_batch(_rows), do: :ok
    def record_pin_batch(_rows), do: :ok
    def record_metadata_batch(_rows), do: :ok
  end

  defmodule RaisingOutbox do
    @moduledoc false
    def append(_row, _kind \\ "message", _context \\ %{}), do: raise("outbox exploded")
  end

  describe "version term priority" do
  end

  describe "ReactionRow.from_event/2 current state" do
  end

  describe "Row.from_event/2 version derivation" do
    test "an ordinary post is versioned by its own timestamp" do
      assert {:ok, row} = Row.from_event(connect(), message_envelope())

      assert row["message_ts"] == "1787019000.000100"
      assert row["message_ts_us"] == 1_787_019_000_000_100
      assert row["version"] == Row.version(1_787_019_000_000_100, false)
      assert row["deleted"] == false
      assert row["text"] == "the original text"
      assert row["actor_kind"] == "user"
      assert row["actor_id"] == "U_HUMAN"
      assert row["actor_label"] == ""
      assert row["observed_ts_us"] == 1_787_019_000_000_100
    end

    test "a backfill snapshot uses the caller-supplied observation cut" do
      assert {:ok, row} =
               Row.from_history(
                 connect(),
                 "C_MIRROR",
                 %{"ts" => "1787019000.000100", "text" => "backfilled"},
                 1_111
               )

      assert row["observed_ts_us"] == 1_111
      assert row["ingest_source"] == "backfill"
    end

    test "a backfill snapshot without a cut does not invent a clock" do
      assert {:ok, row} =
               Row.from_history(connect(), "C_MIRROR", %{
                 "ts" => "1787019000.000100",
                 "text" => "backfilled"
               })

      assert row["observed_ts_us"] == 0
    end

    # The edit and the delete keep the ORIGINAL message's identity and only
    # move the version, which is what lets ClickHouse collapse all three
    # observations of one message into the newest one.
    test "an edit keeps the message identity and takes the edit timestamp" do
      assert {:ok, post} = Row.from_event(connect(), message_envelope())
      assert {:ok, edit} = Row.from_event(connect(), edited_envelope())

      assert edit["message_ts_us"] == post["message_ts_us"]
      assert edit["channel_id"] == post["channel_id"]
      assert edit["text"] == "the edited text"
      assert edit["edited_ts"] == "1787019100.000000"
      assert edit["version"] == Row.version(1_787_019_100_000_000, false)
      assert edit["version"] > post["version"]
    end

    test "a deletion outranks every edit that shares its microsecond" do
      assert {:ok, edit} = Row.from_event(connect(), edited_envelope())

      assert {:ok, tombstone} =
               Row.from_event(connect(), deleted_envelope("1787019100.000000"))

      assert tombstone["deleted"] == true
      assert tombstone["message_ts_us"] == edit["message_ts_us"]
      assert tombstone["version"] == Row.version(1_787_019_100_000_000, true)
      assert tombstone["version"] > edit["version"]
      assert tombstone["text"] == ""
    end

    test "the same delivery replayed produces a byte-identical row" do
      assert {:ok, first} = Row.from_event(connect(), message_envelope())
      assert {:ok, second} = Row.from_event(connect(), message_envelope())

      assert first == second
    end

    test "attachment metadata is kept and private URLs never are" do
      envelope =
        put_event(message_envelope(), "files", [
          %{
            "id" => "F1",
            "name" => "diagram.png",
            "mimetype" => "image/png",
            "size" => 23,
            "url_private" => "https://files.slack.test/private",
            "url_private_download" => "https://files.slack.test/private/download"
          }
        ])

      assert {:ok, row} = Row.from_event(connect(), envelope)
      assert row["file_count"] == 1
      assert row["files"] =~ "diagram.png"
      refute row["files"] =~ "url_private"
      refute row["files"] =~ "files.slack.test"
    end
  end

  describe "the seam is total" do
    setup do
      previous = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_mod)
      previous_outbox = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_outbox)

      on_exit(fn ->
        restore_env(:salix_im, :slack_message_mirror_mod, previous)
        restore_env(:salix_im, :slack_message_mirror_outbox, previous_outbox)
      end)

      :ok
    end
  end

  describe "channel join kicks backfill" do
    setup do
      previous_mirror = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_mod)
      SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, TestMirror)
      Repo.query!("TRUNCATE slack_mirror_backfill_connects")

      on_exit(fn -> restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror) end)
      :ok
    end

    for {name, joined_user, kicks?} <- [
          {"the bot joining a channel makes that installation due now", "U_BOT", true},
          {"another user joining a channel does not kick backfill", "U_HUMAN", false}
        ] do
      @joined_user joined_user
      @kicks kicks?
      test name do
        connect = Map.put(connect(), "bot_user_id", "U_BOT")
        :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
        {:ok, _} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
        :ok = SlackMirrorBackfillLedger.finish_connect(connect["connect_id"], 60_000, nil)
        assert :empty = SlackMirrorBackfillLedger.claim_due_connect(60_000)

        envelope = %{
          "event" => %{
            "type" => "member_joined_channel",
            "user" => @joined_user,
            "channel" => "C_NEW"
          }
        }

        assert SlackMessageMirror.observe(connect, envelope) == :ok

        if @kicks do
          assert {:ok, %{"connect_id" => id}} =
                   SlackMirrorBackfillLedger.claim_due_connect(60_000)

          assert id == connect["connect_id"]
        else
          assert :empty = SlackMirrorBackfillLedger.claim_due_connect(60_000)
        end
      end
    end
  end

  describe "webhook seam placement" do
    setup do
      previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
      previous_mirror = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_mod)
      previous_outbox = SystemsRuntime.get_env(:salix_im, :slack_message_mirror_outbox)

      SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
      SystemsRuntime.put_env(:salix_im, :slack_message_mirror_mod, TestMirror)

      on_exit(fn ->
        restore_env(:salix_store, :s3_backend, previous_backend)
        restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror)
        restore_env(:salix_im, :slack_message_mirror_outbox, previous_outbox)
      end)

      if SystemsRuntime.Proc.whereis(S3.Fake),
        do: S3.Fake.reset(),
        else: start_supervised!(S3.Fake)

      Repo.query!("TRUNCATE slack_mirror_outbox")

      {:ok, connect: seed_connect!()}
    end

    # Each authenticated event reaches the mirror outbox even when the router
    # ignores it. The routing path deliberately ignores `message_deleted`: it
    # carries no routable body. Slack marks it `hidden: true`, so it is also
    # excluded from `conversations.history` — which means an ingest point
    # downstream of that filter could never learn the message was removed, from
    # the webhook or from the API. The deletion row pins the seam ABOVE the filter.
    for {name, envelope, kind, expected} <- [
          {"a deletion the router ignores still reaches the mirror", :deleted, "message",
           %{"deleted" => true, "message_ts" => "1787019000.000100"}},
          {"an edit the router ignores still reaches the mirror", :edited, "message",
           %{"deleted" => false, "text" => "the edited text"}},
          {"an authenticated reaction reaches only the shared reaction mirror", :reaction,
           "reaction", %{"reaction" => "eyes"}},
          {"a pin the router ignores still reaches the mirror", :pin, "pin",
           %{"pinned_by" => "U_PIN"}}
        ] do
      @envelope envelope
      @kind kind
      @expected expected
      test name, %{connect: connect} do
        envelope =
          case @envelope do
            :deleted -> deleted_envelope("1787019100.000000", connect)
            :edited -> edited_envelope(connect)
            :reaction -> reaction_envelope("reaction_added", "1787019100.000000", connect)
            :pin -> pin_envelope(connect)
          end

        ProviderHTTP.handle_slack_event(
          connect,
          envelope,
          signed_headers(connect, envelope),
          Jason.encode!(envelope)
        )

        assert [%{kind: @kind, row: row}] = outbox_entries()
        assert Map.take(row, Map.keys(@expected)) == @expected
      end
    end

    test "a failed outbox insert fails the Slack callback", %{connect: connect} do
      SystemsRuntime.put_env(:salix_im, :slack_message_mirror_outbox, RaisingOutbox)
      envelope = message_envelope(connect)

      assert {:error, :outbox_unavailable} =
               ProviderHTTP.handle_slack_event(
                 connect,
                 envelope,
                 signed_headers(connect, envelope),
                 Jason.encode!(envelope)
               )

      assert outbox_rows() == []
    end

    # Signature verification runs before the mirror, so an unauthenticated
    # payload must never be able to write into the index.
    test "an unsigned callback is never mirrored", %{connect: connect} do
      envelope = message_envelope(connect)

      ProviderHTTP.handle_slack_event(
        connect,
        envelope,
        [{"x-slack-request-timestamp", "1"}, {"x-slack-signature", "v0=deadbeef"}],
        Jason.encode!(envelope)
      )

      assert outbox_rows() == []
    end
  end

  defp outbox_entries do
    {:ok, entries} = SlackMirrorOutbox.claim(10, 60_000)
    entries
  end

  defp outbox_rows, do: Enum.map(outbox_entries(), & &1.row)

  defp seed_connect! do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)
    connect_id = Ids.new_connect_id()

    group = %{
      "schema" => "comma.group.v1",
      "group_id" => group_id,
      "tenant_id" => tenant_id,
      "router_agent_id" => agent_id
    }

    agent = %{
      "schema" => "comma.agent.v1",
      "agent_id" => agent_id,
      "group_id" => group_id,
      "tenant_id" => tenant_id,
      "role" => "router"
    }

    connect = %{
      "schema" => "comma.im_connect.v1",
      "provider" => "slack",
      "connect_id" => connect_id,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "app_id" => "A_MIRROR",
      "workspace_id" => "T_MIRROR",
      "inbound_agent_id" => agent_id,
      "bot_user_id" => "U_MIRROR_BOT",
      "bot_id" => "B_MIRROR_BOT",
      "bot_token" => "xoxb-mirror-test-token",
      "signing_secret" => "mirror-signing-secret",
      "oauth_completed_at" => 1,
      "disabled_at" => nil,
      "deleted_at" => nil
    }

    {:ok, _} = CasRecord.create(Keys.ctl_group(group_id), group)
    {:ok, _} = CasRecord.create(Keys.ctl_agent(agent_id), agent)
    {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), connect)

    connect
  end

  defp connect do
    %{
      "provider" => "slack",
      "tenant_id" => "ten1_mirror",
      "group_id" => "grp1_mirror",
      "connect_id" => "imc1_mirror",
      "app_id" => "A_MIRROR",
      "workspace_id" => "T_MIRROR"
    }
  end

  defp message_envelope(connect \\ connect()) do
    envelope(connect, "Ev-mirror-post", %{
      "type" => "message",
      "user" => "U_HUMAN",
      "text" => "the original text",
      "channel" => "C_MIRROR",
      "ts" => "1787019000.000100",
      "event_ts" => "1787019000.000100"
    })
  end

  defp edited_envelope(connect \\ connect()) do
    envelope(connect, "Ev-mirror-edit", %{
      "type" => "message",
      "subtype" => "message_changed",
      "hidden" => true,
      "channel" => "C_MIRROR",
      "event_ts" => "1787019100.000000",
      "message" => %{
        "type" => "message",
        "user" => "U_HUMAN",
        "text" => "the edited text",
        "ts" => "1787019000.000100",
        "edited" => %{"user" => "U_HUMAN", "ts" => "1787019100.000000"}
      }
    })
  end

  defp deleted_envelope(event_ts, connect \\ connect()) do
    envelope(connect, "Ev-mirror-delete", %{
      "type" => "message",
      "subtype" => "message_deleted",
      "hidden" => true,
      "channel" => "C_MIRROR",
      "deleted_ts" => "1787019000.000100",
      "event_ts" => event_ts
    })
  end

  defp pin_envelope(connect \\ connect()) do
    envelope(connect, "Ev-mirror-pin", %{
      "type" => "pin_added",
      "user" => "U_PIN",
      "channel_id" => "C_MIRROR",
      "event_ts" => "1787019009.000000",
      "item" => %{"type" => "message", "channel" => "C_MIRROR", "ts" => "1787019000.000100"}
    })
  end

  defp reaction_envelope(
         type,
         event_ts \\ "1787019100.000000",
         connect \\ connect()
       ) do
    envelope(connect, "Ev-mirror-reaction", %{
      "type" => type,
      "user" => "U_REACTOR",
      "reaction" => "eyes",
      "item" => %{
        "type" => "message",
        "channel" => "C_MIRROR",
        "ts" => "1787019000.000100"
      },
      "event_ts" => event_ts
    })
  end

  defp envelope(connect, event_id, event) do
    %{
      "type" => "event_callback",
      "api_app_id" => connect["app_id"],
      "team_id" => connect["workspace_id"],
      "event_id" => event_id,
      "event" => event
    }
  end

  defp put_event(envelope, key, value),
    do: put_in(envelope, ["event", key], value)

  defp signed_headers(connect, envelope) do
    body = Jason.encode!(envelope)
    timestamp = SystemsClock.system_time(:second)

    mac =
      :crypto.mac(:hmac, :sha256, connect["signing_secret"], "v0:#{timestamp}:#{body}")
      |> Base.encode16(case: :lower)

    [
      {"x-slack-request-timestamp", Integer.to_string(timestamp)},
      {"x-slack-signature", "v0=" <> mac}
    ]
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
