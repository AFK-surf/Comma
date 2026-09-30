defmodule BridgeForTeams.TriageIdentityContextTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.Schema.{Agent, Project}
  alias BridgeForTeams.SourcedContext.Grounding
  alias SalixIM.Triage.CanonicalJSON

  defmodule ProductSource do
    def resolve_connect(_authority, opts), do: {:ok, Keyword.fetch!(opts, :connect)}

    def load_product(_connect, opts) do
      if pid = opts[:test_pid], do: send(pid, {:product_options, opts})
      {:ok, Keyword.fetch!(opts, :product)}
    end
  end

  defmodule GuardedProductSource do
    def resolve_connect(_authority, opts), do: {:ok, Keyword.fetch!(opts, :connect)}

    def load_product(_connect, opts) do
      send(Keyword.fetch!(opts, :test_pid), :unexpected_product_read)
      {:error, :unexpected_product_read}
    end
  end

  defmodule ThreadReader do
    def read(_authority, _connect, opts) do
      send(Keyword.fetch!(opts, :test_pid), :thread_read)

      {:ok,
       %{
         "checked_at" => "2026-08-14T11:00:00Z",
         "messages" => Keyword.get(opts, :messages, [])
       }}
    end
  end

  defmodule ForbiddenProfileReader do
    def users_info(_provider_user_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), :unexpected_users_info)
      {:error, :forbidden}
    end
  end

  defmodule InjectedProductSource do
    def resolve_connect(_authority, _opts), do: raise("injected ProductSource was called")
    def load_product(_connect, _opts), do: raise("injected ProductSource was called")
  end

  defmodule InjectedThreadReader do
    def read(_authority, _connect, _opts), do: raise("injected ThreadReader was called")
  end

  test "synthetic project identities do not reach the sourced-context database preflight" do
    refute Grounding.project_context_available?("project-identity")
  end

  test "scheduled source pins its reminder even when the confirmation has no topic words" do
    connect = current_connect()
    input = identity_input(connect)
    [event] = input["events"]

    scheduled =
      Map.merge(event, %{
        "source_mode" => "scheduled_recheck",
        "recheck_context_ref" => "triage-context://due-reminder",
        "text" => "好"
      })

    retained = %{
      state: :active,
      kind: "follow_up",
      subject: "发送周报",
      value: "提醒我发送周报",
      source_ref: "triage-context://due-reminder",
      source_count: 1,
      follow_up_basis: "reminder_confirmed",
      next_check_at_ms: 1_999_999_999_999,
      current_wakeup: true
    }

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(
               %{input | "events" => [scheduled]},
               product_source: ProductSource,
               product: Map.put(product(represented_agent()), :retained_context, [retained]),
               connect: connect,
               test_pid: self(),
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert_receive {:product_options, opts}
    assert opts[:recheck_context_refs] == ["triage-context://due-reminder"]
    assert opts[:knowledge_query] == "好"

    assert Enum.any?(frozen["team_project_memory"]["facts"], fn fact ->
             fact["source_ref"] == retained.source_ref and
               fact["text"] =~ "triggered the current scheduled recheck" and
               fact["text"] =~ "提醒我发送周报"
           end)
  end

  test "identity allowlist rejects source, reader, and sink injection before source reads" do
    input = identity_input(current_connect())

    injected_options = [
      [product_source: InjectedProductSource],
      [thread_reader: {InjectedThreadReader, test_pid: self()}],
      [identity_receipt_sink: {self(), make_ref()}]
    ]

    Enum.each(injected_options, fn injected ->
      assert {:error, :invalid_identity_diagnostic_configuration} =
               BridgeForTeams.TriageContext.freeze(
                 input,
                 [identity_allowlist: %{}] ++ injected
               )
    end)
  end

  test "identity allowlist rejects wrappers, credentials, and unknown selector keys" do
    input = identity_input(current_connect())

    invalid_allowlists = [
      %{"profile" => %{}},
      %{"bot_token" => "xoxb-must-not-enter-context"},
      %{"schema" => "comma.triage-identity-selector.v1", "unexpected" => "value"}
    ]

    Enum.each(invalid_allowlists, fn allowlist ->
      assert {:error, :invalid_identity_allowlist} =
               BridgeForTeams.TriageContext.freeze(input,
                 identity_allowlist: allowlist,
                 identity_fence_handle: identity_fence_handle()
               )
    end)
  end

  test "identity CH mode reaches the production authority reader and fails closed when absent" do
    connect = current_connect()

    assert {:error, :not_found} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect),
               identity_allowlist: identity_allowlist(connect),
               identity_fence_handle: identity_fence_handle()
             )
  end

  test "freezes the exact represented agent and current Slack endpoint without secrets" do
    connect = current_connect()
    agent = represented_agent()

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect),
               product_source: ProductSource,
               product: product(agent),
               connect: connect,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert_receive :thread_read, 100

    identity = frozen["identity_context"]
    assert identity["schema"] == "comma.triage-identity-context.v1"
    assert identity["source_mode"] == "callback"

    self_agent = identity["self_agent"]

    assert self_agent["principal_ref"] == "comma-agent://agt1_identity_router"

    assert self_agent["source_ref"] ==
             "bft://projects/project-identity/agents/agent-row-identity"

    assert self_agent["agent_id"] == "agt1_identity_router"
    assert self_agent["role"] == "router"
    assert self_agent["display_name"] == "BFT"
    assert_sha256(self_agent["persona_revision_sha256"])
    assert_sha256(self_agent["identity_revision_sha256"])

    assert identity["self_endpoint"] == %{
             "source_ref" => "slack-endpoint://T_IDENTITY/imc-identity@generation-identity-7",
             "provider" => "slack",
             "workspace_id" => "T_IDENTITY",
             "connect_id" => "imc-identity",
             "connect_generation" => "generation-identity-7",
             "provider_app_id" => "A_SELF",
             "bot_user_id" => "U_SELF",
             "bot_id" => "B_SELF",
             "display_aliases" => ["BFT"],
             "represents_principal_ref" => "comma-agent://agt1_identity_router",
             "revision_sha256" => endpoint_revision(connect),
             "revision_status" => "exact"
           }

    encoded = CanonicalJSON.encode!(identity)
    refute encoded =~ "xoxb-private"
    refute encoded =~ "client-private"
    refute encoded =~ "signing-private"
    refute encoded =~ "You are BFT's private persona"
    refute encoded =~ "https://slack.com/oauth"
  end

  test "annotates only the sanctioned blank-to-known bot identity backfill" do
    current = Map.put(current_connect(), "bot_identity_resolved_at", 1_786_693_125_000)
    event_time = Map.put(current, "bot_user_id", "")

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(identity_input(current, event_time),
               product_source: ProductSource,
               product: product(represented_agent()),
               connect: current,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    assert frozen["identity_context"]["self_endpoint"]["revision_status"] ==
             "sanctioned_bot_identity_backfill"

    assert frozen["identity_context"]["self_endpoint"]["bot_user_id"] == "U_SELF"
    assert_receive :thread_read, 100
  end

  test "sender attribution remains source content but contributes no recipient evidence" do
    connect = current_connect()
    text = "Does RSS growth prove actor state growth? *Sent using* <@U_TOOL>"
    messages = [%{"ts" => "200.004", "user" => "U_PENG", "text" => text}]

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect, nil, "200.004"),
               product_source: ProductSource,
               product: product(represented_agent()),
               connect: connect,
               thread_reader: {ThreadReader, test_pid: self(), messages: messages}
             )

    assert frozen["identity_context"]["mention_evidence"] == []
    assert Enum.any?(frozen["slack_context"]["messages"], &(&1["text"] == text))
  end

  test "deduplicates pre-target text and rich mentions into tier-1 principals" do
    connect = current_connect()

    messages = [
      %{
        "ts" => "200.001",
        "user" => "U_PENG",
        "text" => "<@U_SELF> please pair with <@U_FOREIGN>",
        "blocks" => rich_mentions(["U_SELF", "U_FOREIGN"])
      },
      %{
        "ts" => "200.002",
        "user" => "U_FOREIGN",
        "bot_id" => "B_FOREIGN",
        "app_id" => "A_FOREIGN",
        "bot_profile" => %{"name" => "codex-3720"},
        "text" => "I can help"
      },
      %{"ts" => "200.003", "user" => "U_HUMAN", "text" => "human evidence"},
      %{
        "ts" => "200.004",
        "user" => "U_PENG",
        "text" => "<@U_FOREIGN> <@U_HUMAN> <@U_UNKNOWN>",
        "blocks" => rich_mentions(["U_FOREIGN", "U_UNKNOWN"])
      },
      %{
        "ts" => "200.005",
        "user" => "U_POST",
        "bot_id" => "B_POST",
        "text" => "post-target <@U_POST>"
      }
    ]

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect, nil, "200.004"),
               product_source: ProductSource,
               product: product(represented_agent()),
               connect: connect,
               identity_profile_reader: {ForbiddenProfileReader, test_pid: self()},
               thread_reader: {ThreadReader, test_pid: self(), messages: messages}
             )

    identity = frozen["identity_context"]

    assert Enum.map(identity["observed_principals"], &Map.take(&1, ~w(
             principal_ref kind relation_to_self evidence_tier display_aliases
           ))) == [
             %{
               "principal_ref" => "comma-agent://agt1_identity_router",
               "kind" => "agent",
               "relation_to_self" => "self",
               "evidence_tier" => "self_endpoint",
               "display_aliases" => ["BFT"]
             },
             %{
               "principal_ref" => "slack-principal://T_IDENTITY/U_FOREIGN",
               "kind" => "agent",
               "relation_to_self" => "other",
               "evidence_tier" => "thread_authorship",
               "display_aliases" => ["codex-3720"]
             },
             %{
               "principal_ref" => "slack-principal://T_IDENTITY/U_HUMAN",
               "kind" => "human",
               "relation_to_self" => "other",
               "evidence_tier" => "thread_authorship",
               "display_aliases" => []
             },
             %{
               "principal_ref" => "slack-principal://T_IDENTITY/U_UNKNOWN",
               "kind" => "unknown",
               "relation_to_self" => "unknown",
               "evidence_tier" => "unresolved",
               "display_aliases" => []
             }
           ]

    root_foreign =
      Enum.find(identity["mention_evidence"], fn evidence ->
        evidence["provider_user_id"] == "U_FOREIGN" and
          String.ends_with?(evidence["message_source_ref"], "/200.001")
      end)

    assert root_foreign["selectors"] == ["rich_text_user", "text_token"]
    assert root_foreign["source_refs"] == [root_foreign["message_source_ref"]]
    assert length(identity["mention_evidence"]) == 5
    assert Enum.all?(identity["mention_evidence"], &Map.has_key?(&1, "source_ref"))

    refute Enum.any?(identity["principal_refs"], &String.contains?(&1, "U_POST"))
    # Later conversation is evidence, not a new sealed addressing target.
    assert Enum.any?(frozen["slack_context"]["messages"], &(&1["message_ts"] == "200.005"))
    refute_received :unexpected_users_info
  end

  # BRI-1659. Being mentioned is not the only way to be a party here: an agent
  # that simply POSTED is a member of the conversation, so the freeze names it.
  # A human who was never mentioned deliberately stays a pseudonymous
  # participant, which is the privacy posture this projection already had.
  test "an agent author is registered as a principal even when nobody mentioned it" do
    connect = current_connect()

    messages = [
      %{"ts" => "200.001", "user" => "U_PENG", "text" => "<@U_SELF> 看一下这个 PR"},
      %{
        "ts" => "200.002",
        "user" => "U_REVIEWER",
        "bot_id" => "B_REVIEWER",
        "app_id" => "A_REVIEWER",
        "bot_profile" => %{"name" => "codex-review"},
        "text" => "静态检查通过了"
      },
      %{"ts" => "200.003", "user" => "U_QUIET", "text" => "收到"},
      %{"ts" => "200.004", "user" => "U_PENG", "text" => "多谢"}
    ]

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect, nil, "200.004"),
               product_source: ProductSource,
               product: product(represented_agent()),
               connect: connect,
               identity_profile_reader: {ForbiddenProfileReader, test_pid: self()},
               thread_reader: {ThreadReader, test_pid: self(), messages: messages}
             )

    identity = frozen["identity_context"]

    reviewer =
      Enum.find(
        identity["observed_principals"],
        &(&1["principal_ref"] == "slack-principal://T_IDENTITY/U_REVIEWER")
      )

    assert reviewer["kind"] == "agent"
    assert reviewer["relation_to_self"] == "other"
    assert reviewer["evidence_tier"] == "thread_authorship"
    assert reviewer["display_aliases"] == ["codex-review"]

    # It became a principal WITHOUT any mention evidence naming it.
    refute Enum.any?(identity["mention_evidence"], &(&1["provider_user_id"] == "U_REVIEWER"))

    # A silent human author is still not promoted.
    refute Enum.any?(identity["principal_refs"], &String.contains?(&1, "U_QUIET"))
  end

  test "rejects endpoint drift before Product or thread reads" do
    connect = current_connect()

    input =
      connect
      |> identity_input()
      |> put_in(["events", Access.at(0), "endpoint_provenance", "callback_api_app_id"], "A_OTHER")

    assert {:error, :identity_provenance_drift} =
             BridgeForTeams.TriageContext.freeze(input,
               product_source: GuardedProductSource,
               connect: connect,
               test_pid: self(),
               thread_reader: {ThreadReader, test_pid: self()}
             )

    refute_received :unexpected_product_read
    refute_received :thread_read
  end

  test "rejects a stale represented Agent before the Slack thread read" do
    connect = current_connect()
    stale_agent = %{represented_agent() | salix_agent_id: "agt1_stale_router"}

    assert {:error, :stale_self_agent_identity} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect),
               product_source: ProductSource,
               product: product(stale_agent),
               connect: connect,
               thread_reader: {ThreadReader, test_pid: self()}
             )

    refute_received :thread_read
  end

  test "rejects inactive Project and Agent identity before the Slack thread read" do
    connect = current_connect()

    inactive_products = [
      %{
        product(represented_agent())
        | project: %{product(represented_agent()).project | status: "paused"}
      },
      product(%{
        represented_agent()
        | salix: Map.put(represented_agent().salix, "archived_at", 0)
      })
    ]

    Enum.each(inactive_products, fn inactive_product ->
      assert {:error, :inactive_self_agent_identity} =
               BridgeForTeams.TriageContext.freeze(identity_input(connect),
                 product_source: ProductSource,
                 product: inactive_product,
                 connect: connect,
                 thread_reader: {ThreadReader, test_pid: self()}
               )

      refute_received :thread_read
    end)
  end

  test "treats app attribution without bot evidence as human authorship" do
    connect = current_connect()

    messages = [
      %{
        "ts" => "200.001",
        "user" => "U_APP_ATTRIBUTED_HUMAN",
        "app_id" => "A_USER_SCOPED_CLIENT",
        "text" => "human row carrying app attribution"
      },
      %{
        "ts" => "200.002",
        "user" => "U_APP_ATTRIBUTED_HUMAN",
        "text" => "ordinary human row"
      },
      %{
        "ts" => "200.003",
        "user" => "U_PENG",
        "text" => "<@U_APP_ATTRIBUTED_HUMAN> can you confirm?"
      }
    ]

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect, nil, "200.003"),
               product_source: ProductSource,
               product: product(represented_agent()),
               connect: connect,
               thread_reader: {ThreadReader, test_pid: self(), messages: messages}
             )

    principal =
      Enum.find(frozen["identity_context"]["observed_principals"], fn principal ->
        principal["principal_ref"] ==
          "slack-principal://T_IDENTITY/U_APP_ATTRIBUTED_HUMAN"
      end)

    assert principal["kind"] == "human"
    assert principal["evidence_tier"] == "thread_authorship"
  end

  test "honors projected human authorship even when transport retained a bot id" do
    connect = current_connect()

    messages = [
      %{
        "ts" => "200.001",
        "user" => "U_FILE_OWNER",
        "bot_id" => "B_UPLOAD_TRANSPORT",
        "app_id" => "A_USER_SCOPED_CLIENT",
        "actor_kind" => "human",
        "text" => "user-owned upload"
      },
      %{"ts" => "200.002", "user" => "U_FILE_OWNER", "text" => "ordinary human row"},
      %{"ts" => "200.003", "user" => "U_PENG", "text" => "<@U_FILE_OWNER> can you confirm?"}
    ]

    assert {:ok, frozen} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect, nil, "200.003"),
               product_source: ProductSource,
               product: product(represented_agent()),
               connect: connect,
               thread_reader: {ThreadReader, test_pid: self(), messages: messages}
             )

    principal =
      Enum.find(frozen["identity_context"]["observed_principals"], fn principal ->
        principal["principal_ref"] == "slack-principal://T_IDENTITY/U_FILE_OWNER"
      end)

    assert principal["kind"] == "human"
    assert principal["evidence_tier"] == "thread_authorship"
  end

  test "fails closed on conflicting human and bot authorship evidence" do
    connect = current_connect()

    messages = [
      %{"ts" => "200.001", "user" => "U_CONFLICT", "text" => "human row"},
      %{
        "ts" => "200.002",
        "user" => "U_CONFLICT",
        "bot_id" => "B_CONFLICT",
        "text" => "bot row"
      },
      %{"ts" => "200.003", "user" => "U_PENG", "text" => "<@U_CONFLICT> who are you?"}
    ]

    assert {:error, :conflicting_principal_evidence} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect, nil, "200.003"),
               product_source: ProductSource,
               product: product(represented_agent()),
               connect: connect,
               thread_reader: {ThreadReader, test_pid: self(), messages: messages}
             )
  end

  test "caps the frozen context at sixteen unique mentioned provider ids" do
    connect = current_connect()

    text =
      1..17
      |> Enum.map_join(" ", &"<@U_#{String.pad_leading(to_string(&1), 2, "0")}>")

    messages = [%{"ts" => "200.002", "user" => "U_PENG", "text" => text}]

    assert {:error, :identity_mention_limit_exceeded} =
             BridgeForTeams.TriageContext.freeze(identity_input(connect),
               product_source: ProductSource,
               product: product(represented_agent()),
               connect: connect,
               thread_reader: {ThreadReader, test_pid: self(), messages: messages}
             )
  end

  defp identity_input(connect, event_time_connect \\ nil, message_ts \\ "200.002") do
    event_time_connect = event_time_connect || connect

    %{
      "schema" => "comma.triage-input-snapshot.v2",
      "source_mode" => "callback",
      "source_authority" => source_authority(connect),
      "events" => [
        %{
          "event_id" => "Ev-identity",
          "message_ts" => message_ts,
          "actor_id" => "U_PENG",
          "text" => "Who is BFT?",
          "endpoint_provenance" => %{
            "schema" => "comma.slack-endpoint-provenance.v1",
            "captured_at_ms" => 1_786_693_124_936,
            "callback_api_app_id" => event_time_connect["app_id"],
            "fast_path_bot_user_id" => event_time_connect["bot_user_id"],
            "endpoint_revision_sha256" => endpoint_revision(event_time_connect)
          }
        }
      ]
    }
  end

  defp current_connect do
    %{
      "provider" => "slack",
      "tenant_id" => "tenant-identity",
      "group_id" => "group-identity",
      "connect_id" => "imc-identity",
      "connect_generation" => "generation-identity-7",
      "workspace_id" => "T_IDENTITY",
      "approved_channel_id" => "C_IDENTITY",
      "inbound_agent_id" => "agt1_identity_router",
      "app_id" => "A_SELF",
      "app_name" => "BFT",
      "bot_user_id" => "U_SELF",
      "bot_id" => "B_SELF",
      "bot_username" => "BFT",
      "bot_token" => "xoxb-private",
      "client_secret" => "client-private",
      "signing_secret" => "signing-private",
      "oauth_url" => "https://slack.com/oauth/private"
    }
  end

  defp represented_agent do
    %Agent{
      id: "agent-row-identity",
      project_id: "project-identity",
      salix_agent_id: "agt1_identity_router",
      role: "router",
      salix: %{
        "name" => "BFT",
        "template_id" => "template-identity",
        "llm_config" => %{"model" => "fixed-identity-model"},
        "system_prompt" => "You are BFT's private persona",
        "status" => "active",
        "agent_id" => "agt1_identity_router"
      }
    }
  end

  defp product(agent) do
    %{
      project: %Project{
        id: "project-identity",
        name: "Identity Project",
        slug: "identity-project",
        status: "active",
        salix_group_id: "group-identity"
      },
      agent: agent,
      members: [],
      meetings: []
    }
  end

  defp source_authority(connect) do
    %{
      "connect_id" => connect["connect_id"],
      "connect_generation" => connect["connect_generation"],
      "workspace_id" => connect["workspace_id"],
      "channel_id" => connect["approved_channel_id"],
      "thread_ts" => "200.001"
    }
  end

  defp identity_allowlist(connect) do
    %{
      "schema" => "comma.triage-identity-selector.v2",
      "provider" => "slack",
      "operation" => "clickhouse.thread_current",
      "tenant_id" => connect["tenant_id"],
      "group_id" => connect["group_id"],
      "connect_id" => connect["connect_id"],
      "connect_generation" => connect["connect_generation"],
      "workspace_id" => connect["workspace_id"],
      "approved_channel_id" => connect["approved_channel_id"],
      "root_ts" => "200.001",
      "inbound_agent_id" => connect["inbound_agent_id"],
      "app_id" => connect["app_id"],
      "bot_user_id" => connect["bot_user_id"],
      "bot_id" => connect["bot_id"],
      "endpoint_revision_sha256" => endpoint_revision(connect),
      "project_id" => "project-identity",
      "project_status" => "active",
      "agent_id" => "agt1_identity_router",
      "agent_role" => "router",
      "agent_name" => "BFT",
      "self_agent_identity_revision_sha256" => String.duplicate("a", 64),
      "source_origin_sha256" => String.duplicate("b", 64)
    }
  end

  defp endpoint_revision(connect) do
    connect
    |> Map.take(~w(
      provider tenant_id group_id connect_id connect_generation workspace_id
      inbound_agent_id app_id bot_user_id
    ))
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp rich_mentions(user_ids) do
    [
      %{
        "type" => "rich_text",
        "elements" => [
          %{
            "type" => "rich_text_section",
            "elements" => Enum.map(user_ids, &%{"type" => "user", "user_id" => &1})
          }
        ]
      }
    ]
  end

  defp assert_sha256(value), do: assert(value =~ ~r/\A[0-9a-f]{64}\z/)

  defp identity_fence_handle do
    %SalixIM.Triage.IdentityFenceHandle{runtime: self(), capability: make_ref()}
  end
end
