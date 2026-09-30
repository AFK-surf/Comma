defmodule BridgeForTeams.TriageEngineFixture do
  @moduledoc """
  The one realistic project shape every Triage engine acceptance drive runs
  against, and the two seams those drives are allowed to close.

  This module owns everything that is NOT the thing under test: the durable
  Postgres org/project/member/agent rows, the twelve-meeting `SalixMeet` group
  whose summaries carry a URL, an email and a filesystem path, the loopback
  ClickHouse current-state reader, and the typed ingress that turns a mirrored
  message into a durable receipt. What each acceptance file owns is its own scenario — which
  messages are in the thread, and which evaluator port the engine is wired to.

  Extracted so the offline drive (deterministic provider behind the real
  evaluator) and the live drive (real provider, real model) prove their
  respective decisions against the SAME durable fixture rather than against two
  fixtures that drifted apart.
  """

  import ExUnit.Assertions

  alias BridgeForTeams.{Accounts, Memberships, Orgs, Repo}
  alias BridgeForTeams.Schema.{Agent, Project, ProjectMembership}
  alias SalixIM.Triage.Runtime
  alias SalixStore.{CasRecord, Ids, ULID}

  @root_ts "1787019000.000000"
  @owner_env_key :triage_acceptance_owner
  @thread_env_key :triage_acceptance_thread
  @namespaces_env_key :triage_acceptance_namespaces
  @connects_env_key :triage_acceptance_connects

  # The three literal shapes the projection's privacy gate exists to remove,
  # planted inside meeting facts rather than inside Slack text so the removal is
  # proved on the product-memory path specifically.
  @raw_meeting_url "https://runbooks.example.test/atlas/login-incident"
  @raw_meeting_email "oncall-atlas@example.test"
  @raw_meeting_path "/var/log/atlas/login-incident.json"

  @doc "The thread timestamp every scenario roots itself at."
  def root_ts, do: @root_ts

  @doc "The raw URL planted in a meeting key point."
  def raw_meeting_url, do: @raw_meeting_url

  @doc "The raw email planted in a meeting action item."
  def raw_meeting_email, do: @raw_meeting_email

  @doc "The raw filesystem path planted in a meeting key point."
  def raw_meeting_path, do: @raw_meeting_path

  @doc "Every raw literal the privacy gate must remove before the model payload."
  def raw_meeting_literals, do: [@raw_meeting_url, @raw_meeting_email, @raw_meeting_path]

  # The CH fixture still exposes the bounded workspace-emoji read used by the
  # expression policy. Every method is reported so the tests can prove that no
  # Slack thread read or write returned through the callback transport.
  defmodule SlackLoopback do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, _opts) do
      owner = Application.fetch_env!(:bridge_for_teams_core, :triage_acceptance_owner)
      path = Enum.join(conn.path_info, "/")
      send(owner, {:slack_call, path})
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)

      body_params =
        if String.starts_with?(body, "{"), do: Jason.decode!(body), else: URI.decode_query(body)

      params = Map.merge(conn.query_params, body_params)
      source = Application.get_env(:bridge_for_teams_core, :triage_acceptance_linked_message)

      response =
        case {path, source} do
          {"api/auth.test", %{} = source} ->
            %{"ok" => true, "team_id" => "T_ATLAS", "url" => source["workspace_url"]}

          {"api/conversations.history", %{} = source} ->
            send(owner, {:slack_link_read, params})

            exact? =
              params["channel"] == "C_ATLAS" and params["oldest"] == source["ts"] and
                params["latest"] == source["ts"] and params["limit"] == "1" and
                params["inclusive"] == "true"

            %{
              "ok" => true,
              "messages" => if(exact?, do: [Map.take(source, ~w(ts text user))], else: []),
              "has_more" => false
            }

          {"api/conversations.replies", %{} = _source} ->
            messages =
              if params["limit"] == "1" do
                send(owner, {:slack_link_read, params})

                exact? =
                  params["channel"] == "C_ATLAS" and params["ts"] == source["thread_ts"] and
                    params["oldest"] == source["ts"] and params["latest"] == source["ts"] and
                    params["inclusive"] == "true"

                if exact?, do: [Map.take(source, ~w(ts thread_ts text user))], else: []
              else
                posted =
                  Application.get_env(:bridge_for_teams_core, :triage_acceptance_posted_reply)

                if is_map(posted) and posted["channel"] == params["channel"] and
                     posted["thread_ts"] == params["ts"],
                   do: [posted],
                   else: []
              end

            %{"ok" => true, "messages" => messages, "has_more" => false}

          {"api/chat.postMessage", %{} = _source} ->
            metadata = params["metadata"]
            metadata = if is_binary(metadata), do: Jason.decode!(metadata), else: metadata

            posted =
              params
              |> Map.take(~w(channel thread_ts text))
              |> Map.put("metadata", metadata)
              |> Map.put("ts", "1787019010.000001")

            Application.put_env(:bridge_for_teams_core, :triage_acceptance_posted_reply, posted)
            send(owner, {:slack_reply_posted, posted})
            Map.merge(%{"ok" => true, "message" => posted}, Map.take(posted, ~w(channel ts)))

          _ ->
            %{"ok" => false, "error" => "not_available"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.put_resp_header("x-slack-req-id", "triage-acceptance-req")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  # A loopback implementation of the production ClickHouse read port. It
  # records every scoped current-state read, so the acceptance drive proves
  # both that context came from the sole ambient source and that no Slack read
  # transport was reachable.
  defmodule ClickHouseReader do
    @moduledoc false

    @zero_cursor %{
      "ingest_at" => "1970-01-01T00:00:00.000Z",
      "message_ts_us" => 0,
      "version" => 0
    }

    def tail(scope) do
      report("clickhouse.tail", scope, nil)

      cursor =
        scope
        |> rows()
        |> List.last()
        |> case do
          nil -> @zero_cursor
          row -> cursor(row)
        end

      {:ok, cursor}
    end

    def list_changes(scope, window, limit) do
      report("clickhouse.list_changes", scope, nil)

      matching =
        scope
        |> rows()
        |> Enum.filter(&inside_window?(&1, window))

      page = Enum.take(matching, limit)

      {:ok,
       %{
         rows: page,
         next_cursor: page |> List.last() |> then(&if(&1, do: cursor(&1), else: nil)),
         has_more?: length(matching) > limit
       }}
    end

    def latest_states(scope, message_ts_us_values) do
      report("clickhouse.latest_states", scope, nil)

      {:ok,
       scope
       |> rows()
       |> Enum.filter(&(&1["message_ts_us"] in message_ts_us_values))
       |> Map.new(&{&1["message_ts_us"], &1})}
    end

    def read_thread(scope, root_ts, _opts) do
      report("clickhouse.thread_current", scope, root_ts)

      messages =
        scope
        |> rows()
        |> Enum.filter(&(&1["message_ts"] == root_ts or &1["thread_ts"] == root_ts))

      {:ok,
       %{
         messages: messages,
         reactions: [],
         complete?: true,
         truncated_reason: nil
       }}
    end

    def read_channel(scope, window, opts) do
      report("clickhouse.channel_current", scope, window)
      roots = window["thread_roots"]

      messages =
        scope
        |> rows()
        |> Enum.filter(fn row ->
          row["message_ts_us"] >= window["oldest_ts_us"] or
            row["thread_ts"] in roots or row["message_ts"] in roots
        end)

      limit = Keyword.fetch!(opts, :limit)

      {:ok,
       %{
         messages: Enum.take(messages, limit),
         reactions: [],
         complete?: length(messages) <= limit,
         truncated_reason: if(length(messages) > limit, do: :count)
       }}
    end

    defp rows(scope) do
      messages = Application.fetch_env!(:bridge_for_teams_core, :triage_acceptance_thread)
      root_ts = messages |> List.first() |> Map.fetch!("ts")
      Enum.map(messages, &row(&1, root_ts, scope))
    end

    defp row(message, root_ts, scope) do
      message_ts = message["ts"]
      {:ok, message_ts_us} = SalixIM.SlackMessageMirror.Row.slack_ts_micros(message_ts)
      bot_id = trim(message["bot_id"])
      app_id = trim(message["app_id"])
      user_id = trim(message["user"])

      actor_kind =
        cond do
          bot_id != "" -> "bot"
          app_id != "" -> "app"
          true -> "user"
        end

      actor_id = Enum.find([user_id, bot_id, app_id], "", &(&1 != ""))

      actor_label = get_in(message, ["bot_profile", "name"]) || ""

      %{
        "tenant_id" => scope["tenant_id"],
        "workspace_id" => scope["workspace_id"],
        "channel_id" => scope["channel_id"],
        "message_ts" => message_ts,
        "message_ts_us" => message_ts_us,
        "thread_ts" =>
          Map.get(message, "thread_ts", if(message_ts == root_ts, do: "", else: root_ts)),
        "version" => message_ts_us * 2,
        "deleted" => false,
        "actor_kind" => actor_kind,
        "actor_id" => actor_id,
        "actor_label" => actor_label,
        "subtype" => trim(message["subtype"]),
        "text" => message["text"] || "",
        "payload" => Jason.encode!(message),
        "ingest_at" => "2026-09-01T00:00:01.000Z"
      }
    end

    defp inside_window?(row, window) do
      key = cursor_key(cursor(row))
      lower = cursor_key(window["lower_bound"])
      tail = cursor_key(window["tail"])
      page_after = window["page_after"]

      key >= lower and key <= tail and
        (is_nil(page_after) or key > cursor_key(page_after))
    end

    defp cursor(row), do: Map.take(row, ~w(ingest_at message_ts_us version))

    defp cursor_key(value),
      do: {value["ingest_at"], value["message_ts_us"], value["version"]}

    defp report(operation, scope, root_ts) do
      owner = Application.fetch_env!(:bridge_for_teams_core, :triage_acceptance_owner)
      send(owner, {:clickhouse_read, operation, scope, root_ts})
    end

    defp trim(value) when is_binary(value), do: String.trim(value)
    defp trim(_value), do: ""
  end

  @doc """
  Points the production CH read port at the loopback reader for this test, with
  `owner` as the process every scoped read is reported to. Restores the
  previous reader on exit.
  """
  def install_clickhouse_reader!(owner) do
    previous_reader = Application.get_env(:salix_im, :slack_triage_clickhouse_reader_mod)
    previous_base_url = Application.get_env(:salix_im, :slack_api_base_url)
    previous_review_ingress = Application.get_env(:salix_im, :slack_triage_review_ingress)
    suspended_product_triage = suspend_product_triage!()

    port =
      SalixIM.TestSupport.BanditServer.start!(fn port ->
        {Bandit, plug: SlackLoopback, port: port, startup_log: false}
      end)

    Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, ClickHouseReader)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    Application.delete_env(:salix_im, :slack_triage_review_ingress)
    Application.put_env(:bridge_for_teams_core, @owner_env_key, owner)
    Application.put_env(:bridge_for_teams_core, @thread_env_key, [])
    Application.put_env(:bridge_for_teams_core, @namespaces_env_key, [])
    Application.put_env(:bridge_for_teams_core, @connects_env_key, [])
    Application.delete_env(:bridge_for_teams_core, :triage_acceptance_posted_reply)

    ExUnit.Callbacks.on_exit(fn ->
      # ExUnit has stopped the fixture runtimes at this point. Retire only this
      # test's exact sources/obligations while all default consumers are still
      # suspended and the loopback transports are still installed. Resuming a
      # default worker with old fixture work would cross the isolation boundary.
      retire_test_sources!()

      if is_nil(previous_reader),
        do: Application.delete_env(:salix_im, :slack_triage_clickhouse_reader_mod),
        else: Application.put_env(:salix_im, :slack_triage_clickhouse_reader_mod, previous_reader)

      if is_nil(previous_base_url),
        do: Application.delete_env(:salix_im, :slack_api_base_url),
        else: Application.put_env(:salix_im, :slack_api_base_url, previous_base_url)

      if is_nil(previous_review_ingress),
        do: Application.delete_env(:salix_im, :slack_triage_review_ingress),
        else:
          Application.put_env(
            :salix_im,
            :slack_triage_review_ingress,
            previous_review_ingress
          )

      resume_product_triage(suspended_product_triage)

      Application.delete_env(:bridge_for_teams_core, @owner_env_key)
      Application.delete_env(:bridge_for_teams_core, @thread_env_key)
      Application.delete_env(:bridge_for_teams_core, @namespaces_env_key)
      Application.delete_env(:bridge_for_teams_core, @connects_env_key)
      Application.delete_env(:bridge_for_teams_core, :triage_acceptance_linked_message)
      Application.delete_env(:bridge_for_teams_core, :triage_acceptance_posted_reply)
    end)

    :ok
  end

  # Stop the product recovery lane before the product runtime. ReceiptRecovery
  # scans the same durable provider receipts as this fixture, independently of
  # the callback ingress binding, so deleting that binding alone is not enough
  # to keep an explicit test runtime isolated. Resume in reverse order: runtime
  # first, then recovery.
  defp suspend_product_triage! do
    [
      Salix.Bindings.TriageReceiptRecovery,
      Salix.Bindings.TriageReviewRuntime,
      SalixIM.Triage.ProductEffectWorker,
      SalixIM.Triage.CompanionReactionEffectWorker
    ]
    |> Enum.flat_map(fn name ->
      case Process.whereis(name) do
        pid when is_pid(pid) ->
          :ok = :sys.suspend(pid)
          [{name, pid}]

        nil ->
          []
      end
    end)
  end

  @doc "Retires only this fixture's sources and unfinished local effects; preserves the audit rows."
  def retire_test_sources! do
    for {group_id, connect_id} <-
          Application.get_env(:bridge_for_teams_core, @connects_env_key, []) do
      case CasRecord.update(
             SalixStore.Keys.ctl_im_connect(group_id, connect_id),
             &Map.put(&1, "triage_enabled", false)
           ) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
        other -> flunk("could not retire the local Triage fixture connect: #{inspect(other)}")
      end
    end

    for namespace <- Application.get_env(:bridge_for_teams_core, @namespaces_env_key, []) do
      refute namespace == SalixStore.TriageKeys.default_namespace()
      namespace_key = SalixStore.TriageKeys.namespace_key(namespace)

      for table <- ~w(triage_product_obligations triage_companion_reaction_obligations) do
        SalixStore.Repo.query!(
          """
          UPDATE #{table}
          SET state = 'failed', claim_token = NULL, lease_until = NULL,
              last_error = 'local_acceptance_fixture_retired', updated_at = now()
          WHERE namespace_key = $1 AND state IN ('pending', 'claimed')
          """,
          [namespace_key]
        )
      end
    end

    :ok
  end

  @doc """
  Test-only claim selection for one fixture run. The production worker and
  settlement remain real; its global oldest-first selector is replaced so this
  delivery probe cannot execute another test's pending work. This does not test
  production claim scheduling or concurrency.
  """
  def claim_round!(round, holder) do
    assert round.namespace in Application.fetch_env!(:bridge_for_teams_core, @namespaces_env_key)

    namespace_key = SalixStore.TriageKeys.namespace_key(round.namespace)
    token = "triage-fixture-claim-" <> ULID.generate()

    %{rows: rows} =
      SalixStore.Repo.query!(
        """
        UPDATE triage_product_obligations
        SET state = 'claimed', attempts = attempts + 1, claim_token = $3,
            lease_until = statement_timestamp() + interval '30 seconds',
            updated_at = statement_timestamp()
        WHERE namespace_key = $1 AND run_id = $2 AND state = 'pending'
        RETURNING obligation_id, payload, attempts, lease_until
        """,
        [namespace_key, round.run["run_id"], token]
      )

    {:ok,
     Enum.map(rows, fn [obligation_id, payload, attempt, lease_until] ->
       %{
         namespace_key: namespace_key,
         run_id: round.run["run_id"],
         obligation_id: obligation_id,
         payload: payload,
         attempt: attempt,
         claim_token: token,
         lease_until: lease_until,
         holder: holder
       }
     end)}
  end

  defp resume_product_triage(suspended) do
    suspended
    |> Enum.reverse()
    |> Enum.each(fn {name, pid} ->
      if Process.alive?(pid) and Process.whereis(name) == pid,
        do: :ok = :sys.resume(pid)
    end)
  end

  @doc "The current mirrored thread the loopback CH reader returns."
  def put_thread(messages),
    do: Application.put_env(:bridge_for_teams_core, @thread_env_key, messages)

  @doc "A separate linked message; never included in the ambient frozen thread."
  def put_linked_message(message),
    do: Application.put_env(:bridge_for_teams_core, :triage_acceptance_linked_message, message)

  @doc "One mirrored human thread message in the shape the CH fixture narrows."
  def mirrored_message(ts, user, text), do: %{"ts" => ts, "user" => user, "text" => text}

  @doc """
  One thread message authored by ANOTHER Slack app.

  The shape is what Slack delivers for an app posting as itself: the app's own
  bot user id in `user` — which is what makes it addressable, and therefore
  both admissible and nameable — alongside the bot/app attribution the
  actor-kind rule classifies on and the `bot_profile` the reader narrows to a
  display name.
  """
  def mirrored_agent_message(ts, user, text, opts \\ []) do
    %{
      "ts" => ts,
      "user" => user,
      "text" => text,
      "bot_id" => Keyword.get(opts, :bot_id, "B_REVIEWER"),
      "app_id" => Keyword.get(opts, :app_id, "A_REVIEWER"),
      "bot_profile" => %{"name" => Keyword.get(opts, :display_name, "codex-review")}
    }
  end

  @doc "Drains every scoped CH current-state read observed since the last drain."
  def collected_source_reads(acc \\ []) do
    receive do
      {:clickhouse_read, operation, scope, root_ts} ->
        collected_source_reads([{operation, scope, root_ts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "Drains every Slack method the emoji loopback observed since the last drain."
  def collected_slack_calls(acc \\ []) do
    receive do
      {:slack_call, method} -> collected_slack_calls([method | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  ## Engine

  @doc """
  A review-mode Triage runtime over this fixture's context port and the caller's
  evaluator port. The engine is the production `SalixIM.Triage.Runtime`; only
  the evaluator seam is the caller's to choose.
  """
  def start_engine!(namespace, evaluator_port, overrides \\ []) do
    refute namespace == SalixStore.TriageKeys.default_namespace()
    namespaces = Application.get_env(:bridge_for_teams_core, @namespaces_env_key, [])

    Application.put_env(
      :bridge_for_teams_core,
      @namespaces_env_key,
      Enum.uniq([namespace | namespaces])
    )

    options =
      Keyword.merge(
        [
          name: nil,
          mode: :review,
          namespace: namespace,
          debounce_ms: 15,
          max_wait_ms: 60,
          evaluation_timeout_ms: 30_000,
          recovery_idle_ms: 500,
          review_projection: :slack,
          context_port: {BridgeForTeams.TriageContext, []},
          evaluator_port: evaluator_port
        ],
        overrides
      )

    ExUnit.Callbacks.start_supervised!({Runtime, options}, id: make_ref())
  end

  @doc "Blocks until the engine's ledger holds `count` records, then returns them."
  def await_runs!(server, count, attempts \\ 400) do
    records =
      eventually(
        fn ->
          case SalixIM.Triage.ledger_records(server) do
            found when length(found) >= count -> found
            _pending -> false
          end
        end,
        attempts
      )

    assert length(records) == count
    records
  end

  @doc "Blocks until the engine settled exactly one run, and returns it."
  def await_run!(server, attempts \\ 400) do
    [run] = await_runs!(server, 1, attempts)
    run
  end

  ## Ingress

  @doc """
  Admits a human thread root through the CH ETL typed receipt contract.
  """
  def admit_root!(server, authority, event_id, text, opts \\ []) do
    root_ts = Keyword.get(opts, :root_ts, @root_ts)
    actor_kind = Keyword.get(opts, :actor_kind, "human")

    assert {:ok, _kind, receipt} =
             record_fixture_receipt(
               authority,
               event_id,
               root_ts,
               root_ts,
               text,
               Keyword.get(opts, :actor_id, "U_LIN"),
               actor_kind,
               Keyword.get(opts, :event_type, "message")
             )

    assert {:ok, :accepted} = Runtime.accept_current(server, authority, receipt)
    receipt
  end

  @doc """
  A continuation of the admitted root. Human ambient replies and explicitly
  addressed agent replies both use the CH ETL receipt contract.
  """
  def admit_reply!(server, authority, event_id, message_ts, text, opts \\ []) do
    assert {:ok, _kind, receipt} =
             record_fixture_receipt(
               authority,
               event_id,
               Keyword.get(opts, :root_ts, @root_ts),
               message_ts,
               text,
               Keyword.get(opts, :actor_id, actor_for(message_ts)),
               Keyword.get(opts, :actor_kind, "human"),
               Keyword.get(opts, :event_type, "message")
             )

    assert {:ok, :accepted} = Runtime.accept_current(server, authority, receipt)
    receipt
  end

  defp record_fixture_receipt(
         authority,
         _event_id,
         root_ts,
         message_ts,
         text,
         actor_id,
         "agent",
         _event_type
       ),
       do:
         record_clickhouse_fixture_receipt(
           authority,
           root_ts,
           message_ts,
           text,
           actor_id,
           "agent"
         )

  defp record_fixture_receipt(
         authority,
         _event_id,
         root_ts,
         message_ts,
         text,
         actor_id,
         "human",
         _event_type
       ),
       do:
         record_clickhouse_fixture_receipt(
           authority,
           root_ts,
           message_ts,
           text,
           actor_id,
           "human"
         )

  defp record_clickhouse_fixture_receipt(
         authority,
         root_ts,
         message_ts,
         text,
         actor_id,
         actor_kind
       ) do
    {:ok, message_ts_us} = SalixIM.SlackMessageMirror.Row.slack_ts_micros(message_ts)

    SalixIM.ProviderReceipts.record_slack_triage_clickhouse(
      authority,
      %{
        "workspace_id" => authority["workspace_id"],
        "channel_id" => authority["approved_channel_id"],
        "root_thread_ts" => root_ts,
        "message_ts" => message_ts,
        "message_ts_us" => message_ts_us,
        "observed_version" => message_ts_us * 2,
        "ingest_at" => "2026-09-01T00:00:01.000Z",
        "actor_id" => actor_id,
        "actor_kind" => actor_kind,
        "text" => text
      },
      7
    )
  end

  # The fixture's second thread message is the other human; every other message
  # is the person who opened the thread. Keyed on the message ordinal rather
  # than on a whole timestamp so it holds for any thread root.
  defp actor_for(ts) do
    if String.ends_with?(ts, ".000002"), do: "U_PENG", else: "U_LIN"
  end

  ## Durable fixtures

  @doc """
  A real OAuth-completed Slack connect, its control group, and the triage
  authority the ingress and the engine both read back from it.
  """
  def seed_authority!(source_ids \\ %{}) do
    tenant_id = Ids.new_tenant_id()

    assert {:ok, %{"tenant_id" => ^tenant_id}} =
             BridgeForTeams.Salix.Erpc.create_tenant(%{
               "tenant_id" => tenant_id,
               "name" => "Triage fixture"
             })

    group_id = Ids.new_group_id(tenant_id)

    authority = %{
      "provider" => "slack",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => Ids.new_connect_id(),
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_ATLAS",
      "approved_channel_id" => "C_ATLAS",
      "inbound_agent_id" => Ids.new_agent_id(group_id),
      "app_id" => "A_BFT",
      "bot_user_id" => "U_BFT",
      "bot_id" => "B_BFT",
      "oauth_completed_at" => 1,
      "triage_enabled" => true
    }

    authority = Map.merge(authority, Map.take(source_ids, ~w(workspace_id approved_channel_id)))

    group = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "router_agent_id" => authority["inbound_agent_id"],
      "router_conversation_id" => SalixStore.Ids.new_conversation_id()
    }

    # A real OAuth-completed connect carries the presentation fields the frozen
    # self endpoint's display aliases are built from; `app_name` in particular is
    # written with a non-blank default by every connect writer.
    connect =
      authority
      |> Map.put("bot_token", "xoxb-acceptance-only")
      |> Map.put("bot_username", "bft")
      |> Map.put("app_name", "Bridge For Teams")
      |> Map.put("disabled_at", nil)
      |> Map.put("deleted_at", nil)

    assert {:ok, _group} = CasRecord.create(SalixStore.Keys.ctl_group(group_id), group)

    assert {:ok, _connect} =
             CasRecord.create(
               SalixStore.Keys.ctl_im_connect(group_id, authority["connect_id"]),
               connect
             )

    assert {:ok, _channel} =
             SalixStore.SlackTriageChannels.provision(%{
               "tenant_id" => authority["tenant_id"],
               "group_id" => authority["group_id"],
               "connect_id" => authority["connect_id"],
               "channel_id" => authority["approved_channel_id"],
               "installation_generation" => authority["connect_generation"],
               "workspace_id" => authority["workspace_id"],
               "channel_name" => "triage",
               "channel_generation" => authority["connect_generation"]
             })

    assert {:ok, ^authority} =
             SalixIM.ProviderConnects.get_slack_triage_authority(
               tenant_id,
               group_id,
               authority["connect_id"]
             )

    connects = Application.get_env(:bridge_for_teams_core, @connects_env_key, [])

    Application.put_env(:bridge_for_teams_core, @connects_env_key, [
      {group_id, authority["connect_id"]} | connects
    ])

    authority
  end

  @doc """
  The product side of the same project: an org, three members with distinct
  roles, the project bound to the connect's group, and the router agent row the
  frozen identity context is built from.
  """
  def seed_project!(authority) do
    n = ULID.generate()

    {:ok, org} = Orgs.create_org(%{"name" => "Atlas #{n}", "slug" => "atlas-org-#{n}"})

    org = Repo.update!(Ecto.Changeset.change(org, salix_tenant_id: authority["tenant_id"]))

    members =
      [{"Lin", "admin"}, {"Peng", "member"}, {"Ada", "member"}]
      |> Enum.with_index()
      |> Enum.map(fn {{name, role}, index} ->
        {:ok, user} =
          Accounts.create_user(%{
            "email" => "#{String.downcase(name)}-#{n}-#{index}@example.test",
            "name" => name
          })

        {user, role}
      end)

    {owner_user, _role} = hd(members)
    {:ok, _org_member} = Memberships.put_org_member(org.id, owner_user.id, "owner")

    project =
      Repo.insert!(%Project{
        org_id: org.id,
        name: "Atlas",
        slug: "atlas-#{n}",
        salix_group_id: authority["group_id"],
        created_by_user_id: owner_user.id
      })

    Repo.insert!(%Agent{
      project_id: project.id,
      salix_agent_id: authority["inbound_agent_id"],
      role: "router"
    })

    if SalixAgent.Control.get(authority["inbound_agent_id"]) == {:error, :not_found} do
      assert {:ok, _} =
               SalixAgent.Control.create_preallocated(
                 %{
                   "group_id" => authority["group_id"],
                   "role" => "router",
                   "name" => "BFT",
                   "system_prompt" => "Review the bounded triage context."
                 },
                 authority["tenant_id"],
                 authority["inbound_agent_id"]
               )
    end

    Enum.each(members, fn {user, role} ->
      Repo.insert!(%ProjectMembership{project_id: project.id, user_id: user.id, role: role})
    end)

    project
  end

  @doc """
  Twelve meetings in one group: six that carry usable summaries (three of them
  holding a URL, an email, and a filesystem path), two done meetings whose key
  points are blank, two in progress, and two scheduled.
  """
  def seed_meetings!(group_id) do
    summarized = [
      %{
        "key_points" => [
          "Login incident follow-up stays with Lin; runbook at #{@raw_meeting_url}."
        ],
        "action_items" => [
          %{
            "description" => "Close the login incident follow-up",
            "owner" => "Lin",
            "deadline" => "2026-08-18"
          }
        ]
      },
      %{
        "key_points" => ["Paging rotation confirmed for the next two weeks."],
        "action_items" => [
          %{
            "description" => "Page #{@raw_meeting_email} before any rollback",
            "owner" => "Peng",
            "deadline" => "2026-08-19"
          }
        ]
      },
      %{
        "key_points" => ["Incident evidence is archived at #{@raw_meeting_path}."],
        "action_items" => []
      },
      %{
        "key_points" => ["Ada owns the login retry budget review."],
        "action_items" => [
          %{"description" => "Review the retry budget", "owner" => "Ada", "deadline" => ""}
        ]
      },
      %{
        "key_points" => ["The rollout stays behind the review flag until Friday."],
        "action_items" => []
      },
      %{
        "key_points" => ["Weekly sync moves to Thursday."],
        "action_items" => []
      }
    ]

    blank = [
      %{"key_points" => ["", "   "], "action_items" => []},
      %{"key_points" => [], "action_items" => [%{"description" => "   ", "owner" => ""}]}
    ]

    meetings =
      Enum.with_index(summarized, fn summary, index ->
        {"done", summary, index}
      end) ++
        Enum.with_index(blank, fn summary, index ->
          {"done", summary, index + 6}
        end) ++
        [
          {"active", nil, 8},
          {"active", nil, 9},
          {"scheduled", nil, 10},
          {"scheduled", nil, 11}
        ]

    n = ULID.generate()

    Enum.each(meetings, fn {status, summary, index} ->
      state =
        %{
          "group_id" => group_id,
          "provider" => "slack",
          "title" => "Atlas Weekly #{index}",
          "status" => status,
          "start_at" => 1_776_000_000 + index
        }
        |> then(&if(summary, do: Map.put(&1, "summary", summary), else: &1))

      assert {:ok, _doc, _etag} =
               apply(meet_store(), :create_once, [
                 "meeting-acceptance-#{n}-#{index}",
                 [state: state]
               ])
    end)

    :ok =
      apply(
        :"Elixir.SalixStore.MeetingGroupProjections",
        :mark_ready,
        [%{"mode" => "test-fixture"}]
      )

    :ok = apply(:"Elixir.SalixStore.MeetingGroupProjectionReadiness", :refresh, [])
  end

  # `bridge_for_teams_core` does not depend on `salix_meet`, and must not start
  # to just so a test fixture can seed meetings. Naming the module as a literal
  # atom keeps this support module free of a compile-time dependency on it —
  # the same idiom `SalixWeb.Application` uses to reach BridgeForTeams from the
  # composition root without inverting the dependency graph.
  defp meet_store, do: :"Elixir.SalixMeet.Store"

  ## Small helpers

  @doc "The durable bucket scope key a thread rooted at `root_ts` seals under."
  def scope(authority, root_ts \\ @root_ts) do
    Enum.join(
      [
        authority["connect_generation"],
        authority["workspace_id"],
        authority["approved_channel_id"],
        root_ts
      ],
      ":"
    )
  end

  @doc "The `n`th message timestamp inside a thread rooted at `root_ts`."
  def ts(n, root_ts \\ @root_ts) do
    [seconds, _micros] = String.split(root_ts, ".")
    seconds <> "." <> String.pad_leading(Integer.to_string(n), 6, "0")
  end

  @doc """
  A distinct thread root, so rounds sharing one process cannot collide on the
  durable receipt or bucket keys a real Slack thread would make unique.
  """
  def new_root_ts do
    seconds =
      System.unique_integer([:positive])
      |> rem(1_000_000)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

    "1787" <> seconds <> ".000000"
  end

  @doc "Lowercase hex SHA-256 of raw bytes."
  def sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @doc "Polls `fun` until it returns something other than nil/false/[]."
  def eventually(fun, attempts \\ 400)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, attempts) do
    case fun.() do
      value when value in [nil, false, []] ->
        Process.sleep(25)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end
end
