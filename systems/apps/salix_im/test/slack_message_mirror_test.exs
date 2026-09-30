defmodule SalixIM.SlackMessageMirrorTest do
  use ExUnit.Case, async: false

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
    # `state_ts * 2 + deleted`: observed state first, deletion second, nothing
    # else. A tombstone must beat every live observation of its own microsecond,
    # and a later observation must beat any earlier tombstone.
    test "a tombstone outranks the live observation sharing its microsecond" do
      state_ts = 1_787_019_001_000_000

      assert Row.version(state_ts, false) < Row.version(state_ts, true)
    end

    test "a later observed state outranks an earlier tombstone" do
      earlier = 1_787_019_001_000_000

      assert Row.version(earlier + 1, false) > Row.version(earlier, true)
    end
  end

  describe "ReactionRow.from_event/2 current state" do
    test "add and remove at the same event_ts are two rows ordered by version" do
      added = reaction_envelope("reaction_added", "1787019100.000000")
      removed = reaction_envelope("reaction_removed", "1787019100.000000")

      assert {:ok, add_row} = ReactionRow.from_event(connect(), added)
      assert {:ok, remove_row} = ReactionRow.from_event(connect(), removed)

      assert Map.drop(add_row, ["deleted", "version"]) ==
               Map.drop(remove_row, ["deleted", "version"])

      assert add_row["message_ts"] == "1787019000.000100"
      assert add_row["user_id"] == "U_REACTOR"
      assert add_row["reaction"] == "eyes"
      assert add_row["deleted"] == false
      assert remove_row["deleted"] == true
      assert remove_row["version"] == add_row["version"] + 1
    end

    test "foreign reaction targets and invalid emoji names are ignored" do
      assert ReactionRow.from_event(
               connect(),
               put_in(reaction_envelope("reaction_added"), ["event", "item", "type"], "file")
             ) == :ignore

      assert ReactionRow.from_event(
               connect(),
               put_in(reaction_envelope("reaction_added"), ["event", "reaction"], "bad emoji")
             ) == :ignore
    end
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

    test "a bot post keeps agent authorship and a bounded display label" do
      envelope =
        message_envelope()
        |> put_event("subtype", "bot_message")
        |> put_event("bot_id", "B_REVIEWER")
        |> put_event("app_id", "A_REVIEWER")
        |> put_event("bot_profile", %{"name" => "codex-review"})

      assert {:ok, row} = Row.from_event(connect(), envelope)
      assert row["actor_kind"] == "bot"
      assert row["actor_id"] == "U_HUMAN"
      assert row["actor_label"] == "codex-review"
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

    # Slack's ceiling is 40,000 characters, and CJK is three UTF-8 bytes each.
    # A byte limit derived from the character number rejects a legitimate
    # message at the top of Slack's own range — and this corpus is bilingual.
    test "a message at Slack's character ceiling is kept in any script" do
      cjk = String.duplicate("测", 40_000)
      assert byte_size(cjk) == 120_000

      assert {:ok, row} = Row.from_event(connect(), put_event(message_envelope(), "text", cjk))
      assert row["text"] == cjk

      emoji = String.duplicate("🙂", 40_000)
      assert byte_size(emoji) == 160_000

      assert {:ok, row} = Row.from_event(connect(), put_event(message_envelope(), "text", emoji))
      assert row["text"] == emoji
    end

    # Worse than dropping a post: a dropped edit leaves the PREVIOUS text
    # standing in the index as though the edit never happened.
    test "an edit at the character ceiling is kept in any script" do
      cjk = String.duplicate("改", 40_000)
      envelope = put_in(edited_envelope(), ["event", "message", "text"], cjk)

      assert {:ok, row} = Row.from_event(connect(), envelope)
      assert row["text"] == cjk
      assert row["deleted"] == false
    end

    test "a payload past the sanity ceiling is clamped rather than dropped" do
      huge = String.duplicate("x", 64_001)

      assert {:ok, row} = Row.from_event(connect(), put_event(message_envelope(), "text", huge))
      assert String.length(row["text"]) == 64_000
      assert row["message_ts"] == "1787019000.000100"
    end

    test "channel lifecycle and unknown subtypes are stored; foreign events are ignored" do
      assert {:ok, join} =
               Row.from_event(connect(), put_event(message_envelope(), "subtype", "channel_join"))

      assert join["subtype"] == "channel_join"

      assert {:ok, assistant} =
               Row.from_history(connect(), "C_MIRROR", %{
                 "ts" => "1787019000.000100",
                 "subtype" => "assistant_app_thread",
                 "text" => "assistant root",
                 "assistant_app_thread" => %{"title" => "oncall"}
               })

      assert assistant["subtype"] == "assistant_app_thread"
      assert assistant["payload"] =~ "assistant_app_thread"
      assert assistant["payload"] =~ "oncall"

      assert Row.from_event(connect(), put_event(message_envelope(), "type", "reaction_added")) ==
               :ignore

      assert Row.from_event(connect(), %{}) == :ignore
    end

    test "pin and metadata events are stored beside the message row" do
      pin_envelope = %{
        "event" => %{
          "type" => "pin_added",
          "user" => "U_PIN",
          "channel_id" => "C_MIRROR",
          "event_ts" => "1787019009.000000",
          "pinned_info" => %{
            "channel" => "C_MIRROR",
            "pinned_by" => "U_PIN",
            "pinned_ts" => 1_787_019_009
          },
          "item" => %{"type" => "message", "channel" => "C_MIRROR", "ts" => "1787019000.000100"}
        }
      }

      assert {:ok, pin} = PinRow.from_event(connect(), pin_envelope)
      assert pin["pinned_by"] == "U_PIN"
      assert pin["pinned_ts"] == "1787019009"
      refute pin["pinned_ts"] == pin["message_ts"]
      assert pin["deleted"] == false

      metadata_envelope = %{
        "event" => %{
          "type" => "message_metadata_posted",
          "channel_id" => "C_MIRROR",
          "message_ts" => "1787019000.000100",
          "event_ts" => "1787019009.000000",
          "metadata" => %{"event_type" => "incident", "event_payload" => %{"sev" => "1"}}
        }
      }

      assert {:ok, metadata} = MetadataRow.from_event(connect(), metadata_envelope)
      assert metadata["deleted"] == false
      assert metadata["metadata"] =~ "incident"
    end

    test "the canonical payload keeps attachments, metadata, reactions, and bot identity" do
      envelope =
        message_envelope()
        |> put_event("subtype", "bot_message")
        |> put_event("bot_id", "B_REVIEWER")
        |> put_event("app_id", "A_REVIEWER")
        |> put_event("attachments", [%{"title" => "Pager", "text" => "disk full"}])
        |> put_event("metadata", %{"event_type" => "incident", "event_payload" => %{"sev" => "1"}})
        |> put_event("reactions", [%{"name" => "eyes", "count" => 2, "users" => ["U1", "U2"]}])

      assert {:ok, row} = Row.from_event(connect(), envelope)
      assert row["payload"] =~ "Pager"
      assert row["payload"] =~ "incident"
      assert row["payload"] =~ "B_REVIEWER"
      assert row["payload"] =~ "eyes"
      assert row["actor_kind"] == "bot"
    end

    test "a connect without tenant or workspace identity cannot produce a row" do
      assert Row.from_event(Map.delete(connect(), "workspace_id"), message_envelope()) == :ignore
      assert Row.from_event(Map.delete(connect(), "tenant_id"), message_envelope()) == :ignore
    end

    test "a short fractional timestamp is padded, not parsed as an integer" do
      assert Row.slack_ts_micros("1787019000.1") == {:ok, 1_787_019_000_100_000}
      assert Row.slack_ts_micros("1787019000.000100") == {:ok, 1_787_019_000_000_100}
      assert Row.slack_ts_micros("not-a-timestamp") == :error
    end
  end

  describe "the seam is total" do
    setup do
      previous = Application.get_env(:salix_im, :slack_message_mirror_mod)
      previous_outbox = Application.get_env(:salix_im, :slack_message_mirror_outbox)

      on_exit(fn ->
        restore_env(:salix_im, :slack_message_mirror_mod, previous)
        restore_env(:salix_im, :slack_message_mirror_outbox, previous_outbox)
      end)

      :ok
    end

    test "an outbox that raises fails the caller so Slack can retry" do
      Application.put_env(:salix_im, :slack_message_mirror_mod, TestMirror)
      Application.put_env(:salix_im, :slack_message_mirror_outbox, RaisingOutbox)

      handler = "mirror-drop-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:salix, :slack_mirror, :dropped],
        fn _event, measurements, metadata, _config ->
          send(parent, {:dropped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert SlackMessageMirror.observe(connect(), message_envelope()) ==
               {:error, :outbox_unavailable}

      assert_receive {:dropped, %{count: 1}, %{reason: :outbox_unavailable}}
    end

    # Without an adapter the seam does not even build a row, so a deployment
    # with no ClickHouse pays one `Application.get_env/3` per Slack event.
    test "with no adapter wired in nothing is built" do
      Application.delete_env(:salix_im, :slack_message_mirror_mod)

      refute SlackMessageMirror.enabled?()
      assert SlackMessageMirror.observe(connect(), message_envelope()) == :ok
    end
  end

  describe "channel join kicks backfill" do
    setup do
      previous_mirror = Application.get_env(:salix_im, :slack_message_mirror_mod)
      Application.put_env(:salix_im, :slack_message_mirror_mod, TestMirror)
      Repo.query!("TRUNCATE slack_mirror_backfill_connects")

      on_exit(fn -> restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror) end)
      :ok
    end

    test "the bot joining a channel makes that installation due now" do
      connect = Map.put(connect(), "bot_user_id", "U_BOT")
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      {:ok, _} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      :ok = SlackMirrorBackfillLedger.finish_connect(connect["connect_id"], 60_000, nil)
      assert :empty = SlackMirrorBackfillLedger.claim_due_connect(60_000)

      envelope = %{
        "event" => %{
          "type" => "member_joined_channel",
          "user" => "U_BOT",
          "channel" => "C_NEW"
        }
      }

      assert SlackMessageMirror.observe(connect, envelope) == :ok
      assert {:ok, %{"connect_id" => id}} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      assert id == connect["connect_id"]
    end

    test "another user joining a channel does not kick backfill" do
      connect = Map.put(connect(), "bot_user_id", "U_BOT")
      :ok = SlackMirrorBackfillLedger.upsert_connects([connect])
      {:ok, _} = SlackMirrorBackfillLedger.claim_due_connect(60_000)
      :ok = SlackMirrorBackfillLedger.finish_connect(connect["connect_id"], 60_000, nil)
      assert :empty = SlackMirrorBackfillLedger.claim_due_connect(60_000)

      envelope = %{
        "event" => %{
          "type" => "member_joined_channel",
          "user" => "U_HUMAN",
          "channel" => "C_NEW"
        }
      }

      assert SlackMessageMirror.observe(connect, envelope) == :ok
      assert :empty = SlackMirrorBackfillLedger.claim_due_connect(60_000)
    end
  end

  describe "webhook seam placement" do
    setup do
      previous_backend = Application.get_env(:salix_store, :s3_backend)
      previous_mirror = Application.get_env(:salix_im, :slack_message_mirror_mod)
      previous_outbox = Application.get_env(:salix_im, :slack_message_mirror_outbox)

      Application.put_env(:salix_store, :s3_backend, S3.Fake)
      Application.put_env(:salix_im, :slack_message_mirror_mod, TestMirror)

      on_exit(fn ->
        restore_env(:salix_store, :s3_backend, previous_backend)
        restore_env(:salix_im, :slack_message_mirror_mod, previous_mirror)
        restore_env(:salix_im, :slack_message_mirror_outbox, previous_outbox)
      end)

      if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
      Repo.query!("TRUNCATE slack_mirror_outbox")

      {:ok, connect: seed_connect!()}
    end

    # The routing path deliberately ignores `message_deleted`: it carries no
    # routable body. Slack marks it `hidden: true`, so it is also excluded from
    # `conversations.history` — which means an ingest point downstream of that
    # filter could never learn the message was removed, from the webhook or
    # from the API. This is the regression that pins the seam ABOVE the filter.
    test "a deletion the router ignores still reaches the mirror", %{connect: connect} do
      envelope = deleted_envelope("1787019100.000000", connect)

      ProviderHTTP.handle_slack_event(
        connect,
        envelope,
        signed_headers(connect, envelope),
        Jason.encode!(envelope)
      )

      assert [row] = outbox_rows()
      assert row["deleted"] == true
      assert row["message_ts"] == "1787019000.000100"
    end

    test "an edit the router ignores still reaches the mirror", %{connect: connect} do
      envelope = edited_envelope(connect)

      ProviderHTTP.handle_slack_event(
        connect,
        envelope,
        signed_headers(connect, envelope),
        Jason.encode!(envelope)
      )

      assert [row] = outbox_rows()
      assert row["deleted"] == false
      assert row["text"] == "the edited text"
    end

    test "an authenticated reaction reaches only the shared reaction mirror", %{connect: connect} do
      envelope = reaction_envelope("reaction_added", "1787019100.000000", connect)

      ProviderHTTP.handle_slack_event(
        connect,
        envelope,
        signed_headers(connect, envelope),
        Jason.encode!(envelope)
      )

      assert [%{kind: "reaction", row: row}] = outbox_entries()
      assert row["reaction"] == "eyes"
    end

    # Signature verification runs before the mirror, so an unauthenticated
    # payload must never be able to write into the index.
    test "a pin the router ignores still reaches the mirror", %{connect: connect} do
      envelope = pin_envelope(connect)

      ProviderHTTP.handle_slack_event(
        connect,
        envelope,
        signed_headers(connect, envelope),
        Jason.encode!(envelope)
      )

      assert [%{kind: "pin", row: row}] = outbox_entries()
      assert row["pinned_by"] == "U_PIN"
    end

    test "a failed outbox insert fails the Slack callback", %{connect: connect} do
      Application.put_env(:salix_im, :slack_message_mirror_outbox, RaisingOutbox)
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
    timestamp = System.system_time(:second)

    mac =
      :crypto.mac(:hmac, :sha256, connect["signing_secret"], "v0:#{timestamp}:#{body}")
      |> Base.encode16(case: :lower)

    [
      {"x-slack-request-timestamp", Integer.to_string(timestamp)},
      {"x-slack-signature", "v0=" <> mac}
    ]
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
