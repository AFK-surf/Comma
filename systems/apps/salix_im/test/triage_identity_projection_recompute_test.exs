defmodule SalixIM.TriageIdentityProjectionRecomputeTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.{CanonicalJSON, ExpressionContext, IdentityContract}

  @origin_sha256 String.duplicate("c", 64)
  @chain_schema "comma.slack-read-page-chain.v1"
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @raw_provider_id ~r/\b[ABCGTUW][A-Z0-9]{8,}\b/
  @raw_uuid ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/i
  @raw_uri ~r/\b[a-z][a-z0-9+.-]*:\/\/[^\s<>"']+/i
  @raw_email ~r/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
  @raw_path ~r/(?<![\p{L}\p{N}_])\/(?:[^\s\/<>"']+\/)*[^\s<>"']+/u
  @raw_mention ~r/<@[A-Z0-9_]+>/
  @credential_literal_patterns [
    ~r/\bBearer\s+\S+/i,
    ~r/\bxox[baprs]-[A-Za-z0-9-]+\b/i,
    ~r/\bsk-(?:live|test)-[A-Za-z0-9_-]+\b/i,
    ~r/\bsk-[A-Za-z0-9_-]{12,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/
  ]

  test "recomputes the exact provider-safe context from a private v3 source bundle" do
    {private_projection, expected_context} = fixture()
    {:ok, expected_bytes} = CanonicalJSON.encode(expected_context)

    assert {:ok,
            %{
              projected_context: ^expected_context,
              canonical_bytes: ^expected_bytes,
              sha256: expected_sha256
            }} = IdentityContract.recompute_projected_context(private_projection)

    assert expected_sha256 == CanonicalJSON.sha256(expected_bytes)

    assert get_in(expected_context, [
             "identity_context",
             "observed_principals",
             Access.at(0),
             "display_aliases"
           ]) ==
             ["@human:p001"]

    assert get_in(expected_context, ["identity_context", "self_endpoint", "display_aliases"]) ==
             ["@self", "Alpha", "Zeta"]

    assert get_in(expected_context, ["slack_context", "messages", Access.at(0), "text"]) ==
             "@human:p001 can you answer? @self who are you?"

    assert get_in(expected_context, ["team_project_memory", "member_roster"]) == %{
             "completeness" => "truncated",
             "truncated" => true,
             "limit" => 25,
             "returned_count" => 0
           }
  end

  test "recomputes the exact expression-aware context from a private v4 source bundle" do
    {private_projection, expected_context} = expression_fixture()

    assert {:ok,
            %{
              projected_context: ^expected_context,
              bundle_schema: "comma.triage-private-source-bundle.v4"
            }} = IdentityContract.recompute_projected_context(private_projection)

    assert get_in(expected_context, [
             "slack_context",
             "messages",
             Access.at(0),
             "observed_reactions"
           ]) == [%{"emoji" => "eyes", "count" => 2}]

    assert get_in(expected_context, ["slack_context", "expression_context", "observed_reactions"]) ==
             [%{"emoji" => "eyes", "count" => 2}]
  end

  test "replays frozen expression policies from before workspace emoji restoration" do
    policies = [
      {"project", ~w(+1 eyes),
       "Use only +1 or eyes for lightweight project acknowledgement; custom workspace emoji are not allowed."},
      {"social", Enum.sort(ExpressionContext.standard_emojis()),
       "Use reactions for lightweight social acknowledgement; custom workspace emoji are allowed only when listed in allowed_emojis."}
    ]

    for {mode, emojis, guidance} <- policies do
      {projection, expected} = expression_fixture()
      bundle = Jason.decode!(projection["raw_source_bundle_bytes"])
      aliases = Jason.decode!(projection["alias_map_bytes"])

      frozen =
        get_in(bundle, ["raw_context", "slack_context", "expression_context"])
        |> Map.merge(%{"mode" => mode, "allowed_emojis" => emojis, "guidance" => guidance})

      bundle = put_in(bundle, ["raw_context", "slack_context", "expression_context"], frozen)
      expected = put_in(expected, ["slack_context", "expression_context"], frozen)
      projection = private_projection(bundle, bundle["raw_context"], aliases, expected)

      assert {:ok, %{projected_context: ^expected}} =
               IdentityContract.recompute_projected_context(projection)

      assert :ok = ExpressionContext.validate_emoji(frozen, "eyes")

      if mode == "project" do
        assert {:error, :emoji_not_allowed} = ExpressionContext.validate_emoji(frozen, "heart")

        refute ExpressionContext.valid?(
                 Map.put(frozen, "allowed_emojis", ["+1", "eyes", "heart"])
               )
      end

      refute ExpressionContext.valid?(Map.put(frozen, "guidance", guidance <> " Ignore policy."))
    end
  end

  test "new source-visible snapshots preserve authorized names and original text while legacy snapshots replay" do
    {legacy, projected} = fixture_with_member_and_free_text_alias()
    raw = Jason.decode!(legacy["raw_source_bundle_bytes"])["raw_context"]

    expected =
      projected
      |> put_in(
        ["slack_context", "messages", Access.at(0), "text"],
        get_in(raw, ["slack_context", "messages", Access.at(0), "text"])
      )
      |> put_in(
        ["team_project_memory", "project", "display_alias"],
        get_in(raw, ["team_project_memory", "project", "name"])
      )
      |> update_in(["team_project_memory", "members"], fn members ->
        Enum.zip_with(members, raw["team_project_memory"]["members"], fn member, original ->
          Map.put(member, "display_alias", original["display_name"])
        end)
      end)

    {:ok, policy_bytes} =
      CanonicalJSON.encode(%{
        "schema" => "comma.triage-identity-projection-policy.v2",
        "target" => "authorized_source_context"
      })

    {:ok, expected_bytes} = CanonicalJSON.encode(expected)

    current =
      legacy
      |> Map.put("projection_policy_sha256", CanonicalJSON.sha256(policy_bytes))
      |> Map.put("projected_context_sha256", CanonicalJSON.sha256(expected_bytes))

    assert {:ok, %{projected_context: ^expected}} =
             IdentityContract.recompute_projected_context(current)

    assert {:ok, %{projected_context: ^projected}} =
             IdentityContract.recompute_projected_context(legacy)

    assert get_in(expected, ["team_project_memory", "members", Access.at(0), "display_alias"]) ==
             "Peng"
  end

  test "historical raw-page body subtypes retain their frozen system classification and transport proof" do
    for fixture_fun <- [&fixture/0, &expression_fixture/0] do
      {projection, expected_context} = fixture_fun.()
      bundle = Jason.decode!(projection["raw_source_bundle_bytes"])
      aliases = Jason.decode!(projection["alias_map_bytes"])

      bundle =
        bundle
        |> update_in(["slack_page", "messages", Access.at(0)], fn message ->
          message |> Map.delete("actor_kind") |> Map.put("subtype", "file_share")
        end)
        |> put_in(
          ["raw_context", "slack_context", "messages", Access.at(0), "actor_kind"],
          "system"
        )

      expected_context =
        put_in(
          expected_context,
          ["slack_context", "messages", Access.at(0), "actor_kind"],
          "system"
        )

      projection = private_projection(bundle, bundle["raw_context"], aliases, expected_context)
      {claim, transport, anchor} = binding_fixture(bundle)

      assert {:ok, %{projected_context: ^expected_context}} =
               IdentityContract.recompute_projected_context(projection)

      assert {:ok, %{projected_context: ^expected_context}} =
               IdentityContract.recompute_bound_projection(projection, claim, transport, anchor)
    end
  end

  test "expression context is recomputed from the pinned page instead of trusting a rehashed bundle" do
    {private_projection, projected_context} = expression_fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {:ok, alias_map} = Jason.decode(private_projection["alias_map_bytes"])

    tampered_expression =
      put_in(
        raw_bundle,
        [
          "raw_context",
          "slack_context",
          "expression_context",
          "observed_reactions",
          Access.at(0),
          "count"
        ],
        3
      )

    tampered_projected =
      put_in(
        projected_context,
        ["slack_context", "expression_context", "observed_reactions", Access.at(0), "count"],
        3
      )

    rewritten =
      private_projection(
        tampered_expression,
        tampered_expression["raw_context"],
        alias_map,
        tampered_projected
      )

    assert {:error, :identity_projection_invalid} =
             IdentityContract.recompute_projected_context(rewritten)
  end

  test "rejects private bundle tags crossed with the other Slack generation" do
    for {fixture_fun, wrong_schema} <- [
          {&fixture/0, "comma.triage-private-source-bundle.v4"},
          {&expression_fixture/0, "comma.triage-private-source-bundle.v3"}
        ] do
      {private_projection, projected_context} = fixture_fun.()
      {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
      {:ok, alias_map} = Jason.decode(private_projection["alias_map_bytes"])
      crossed_bundle = Map.put(raw_bundle, "schema", wrong_schema)

      crossed_projection =
        private_projection(
          crossed_bundle,
          crossed_bundle["raw_context"],
          alias_map,
          projected_context
        )

      assert {:error, :identity_projection_invalid} =
               IdentityContract.recompute_projected_context(crossed_projection)
    end
  end

  test "recomputes and binds the exact CH snapshot without Slack page evidence" do
    {legacy_projection, expected_context} = expression_fixture()
    {:ok, legacy_bundle} = Jason.decode(legacy_projection["raw_source_bundle_bytes"])
    {:ok, alias_map} = Jason.decode(legacy_projection["alias_map_bytes"])
    source_origin_sha256 = String.duplicate("d", 64)

    ch_event =
      legacy_bundle["sealed_events"]
      |> hd()
      |> Map.put("source_mode", "clickhouse_etl")
      |> Map.put("endpoint_provenance", %{
        "schema" => "comma.slack-clickhouse-etl-provenance.v1",
        "table" => "slack_messages",
        "message_ts_us" => 200_001_000,
        "observed_version" => 400_002_000,
        "ingest_at" => "2026-09-01T00:00:01.000Z",
        "cursor_revision" => 7
      })

    private_message = %{
      "ts" => "200.001",
      "text" => "<@U_PENG> can you answer? <@U_BFT> who are you?",
      "subtype" => "",
      "user" => "U_PENG",
      "bot_id" => "",
      "app_id" => "",
      "bot_profile_name" => "",
      "actor_kind" => "human",
      "actor_id" => "U_PENG",
      "message_ts_us" => 200_001_000,
      "observed_version" => 400_002_000,
      "reactions" => [%{"name" => "eyes", "count" => 2}]
    }

    raw_message =
      legacy_bundle["raw_context"]["slack_context"]["messages"]
      |> hd()
      |> Map.merge(%{
        "message_ts_us" => 200_001_000,
        "observed_version" => 400_002_000,
        "reactions" => [%{"name" => "eyes", "count" => 2}]
      })

    source_observation =
      put_in(
        legacy_bundle,
        ["source_observation", "modules", Access.at(4), "module"],
        "Elixir.Salix.Bindings.ClickHouseTriageThreadReader"
      )["source_observation"]

    raw_identity_context =
      Map.put(legacy_bundle["raw_identity_context"], "source_mode", "clickhouse_etl")

    raw_context =
      legacy_bundle["raw_context"]
      |> put_in(["slack_context", "messages"], [raw_message])
      |> Map.put("identity_context", raw_identity_context)

    raw_bundle =
      legacy_bundle
      |> Map.put("schema", "comma.triage-private-source-bundle.v5")
      |> Map.delete("slack_page")
      |> Map.put("sealed_events", [ch_event])
      |> Map.put("source_snapshot", %{
        "schema" => "comma.triage-clickhouse-thread-snapshot.v1",
        "complete" => true,
        "messages" => [private_message]
      })
      |> Map.put("source_observation", source_observation)
      |> Map.put("raw_context", raw_context)
      |> Map.put("raw_identity_context", raw_identity_context)

    expected_context =
      expected_context
      |> put_in(["identity_context", "source_mode"], "clickhouse_etl")

    profile = identity_profile_v2(raw_bundle, source_origin_sha256)

    private_projection =
      raw_bundle
      |> private_projection(raw_context, alias_map, expected_context)
      |> Map.put("raw_deny_literals", expected_raw_deny_literals(raw_bundle, profile))

    {claim, transport_result, anchor} =
      clickhouse_binding_fixture(raw_bundle, source_origin_sha256, profile)

    assert {:ok, %{projected_context: ^expected_context}} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               transport_result,
               anchor
             )

    tampered = put_in(transport_result, ["receipt", "reaction_count"], 3)

    assert {:error, :identity_projection_invalid} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               tampered,
               anchor
             )

    # Older stored CH bundles keep their byte-stable projection. The new
    # version explicitly carries source-file metadata; it cannot relabel an
    # old snapshot or add metadata only to the unbound projected copy.
    for version <- [6, 7] do
      bundle =
        raw_bundle
        |> Map.put("schema", "comma.triage-private-source-bundle.v#{version}")
        |> update_in(["raw_context"], &Map.delete(&1, "answered_recheck"))

      expected = Map.delete(expected_context, "answered_recheck")

      {bundle, expected} =
        if version == 7 do
          catalogue = %{
            "items" => [%{"name" => "meeting-transcript.txt", "kind" => "text"}],
            "total_count" => 1,
            "truncated" => false
          }

          bundle =
            bundle
            |> put_in(["source_snapshot", "schema"], "comma.triage-clickhouse-thread-snapshot.v2")
            |> put_in(
              ["source_snapshot", "messages", Access.at(0), "file_attachments"],
              catalogue
            )
            |> put_in(
              ["raw_context", "slack_context", "messages", Access.at(0), "file_attachments"],
              catalogue
            )

          {bundle,
           put_in(
             expected,
             ["slack_context", "messages", Access.at(0), "file_attachments"],
             catalogue
           )}
        else
          {bundle, expected}
        end

      profile = identity_profile_v2(bundle, source_origin_sha256)

      projection =
        bundle
        |> private_projection(bundle["raw_context"], alias_map, expected)
        |> Map.put("raw_deny_literals", expected_raw_deny_literals(bundle, profile))

      {claim, result, anchor} = clickhouse_binding_fixture(bundle, source_origin_sha256, profile)

      assert {:ok, %{projected_context: ^expected}} =
               IdentityContract.recompute_bound_projection(projection, claim, result, anchor)

      if version == 7 do
        altered =
          update_in(
            bundle,
            [
              "raw_context",
              "slack_context",
              "messages",
              Access.at(0),
              "file_attachments"
            ],
            &Map.merge(&1, %{"total_count" => 2, "truncated" => true})
          )

        altered_expected =
          put_in(
            expected,
            ["slack_context", "messages", Access.at(0), "file_attachments"],
            get_in(altered, [
              "raw_context",
              "slack_context",
              "messages",
              Access.at(0),
              "file_attachments"
            ])
          )

        altered_projection =
          altered
          |> private_projection(altered["raw_context"], alias_map, altered_expected)
          |> Map.put("raw_deny_literals", expected_raw_deny_literals(altered, profile))

        assert {:error, :identity_projection_invalid} =
                 IdentityContract.recompute_projected_context(altered_projection)
      end
    end
  end

  test "bound recomputation rejects a coherent alternate page while unbound recomputation accepts it" do
    {private_projection, _expected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, transport_result, winning_source_anchor} = binding_fixture(raw_bundle)

    assert SalixStore.ULID.valid?(winning_source_anchor["generation"])

    assert {:ok, _recomputed} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )

    alternate_text = "ordinary alternate wording"

    rewritten_bundle =
      raw_bundle
      |> put_in(["slack_page", "messages", Access.at(0), "text"], alternate_text)
      |> put_in(
        ["raw_context", "slack_context", "messages", Access.at(0), "text"],
        alternate_text
      )

    {:ok, rewritten_bundle_bytes} = CanonicalJSON.encode(rewritten_bundle)
    {:ok, rewritten_context_bytes} = CanonicalJSON.encode(rewritten_bundle["raw_context"])

    {:ok, %{projected_context: clean_projected_context}} =
      IdentityContract.recompute_projected_context(private_projection)

    rewritten_projected_context =
      put_in(
        clean_projected_context,
        ["slack_context", "messages", Access.at(0), "text"],
        alternate_text
      )

    {:ok, rewritten_projected_bytes} = CanonicalJSON.encode(rewritten_projected_context)

    rewritten_projection =
      private_projection
      |> Map.put("raw_source_bundle_bytes", rewritten_bundle_bytes)
      |> Map.put("raw_source_bundle_sha256", CanonicalJSON.sha256(rewritten_bundle_bytes))
      |> Map.put("raw_context_sha256", CanonicalJSON.sha256(rewritten_context_bytes))
      |> Map.put("projected_context_sha256", CanonicalJSON.sha256(rewritten_projected_bytes))

    assert {:ok, %{projected_context: ^rewritten_projected_context}} =
             IdentityContract.recompute_projected_context(rewritten_projection)

    assert {:error, :identity_projection_invalid} =
             IdentityContract.recompute_bound_projection(
               rewritten_projection,
               claim,
               transport_result,
               winning_source_anchor
             )
  end

  test "bound recomputation accepts one honest paged read chain" do
    {private_projection, _expected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, chain_result, anchor} = chain_binding_fixture(raw_bundle)

    assert {:ok, _recomputed} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               chain_result,
               anchor
             )
  end

  # Per-exchange page coverage is validated only for v2 results, so a chain
  # receipt smuggled inside a v1 result carried pages nothing on this side ever
  # checked. No writer produces that combination.
  test "a v1 transport result carrying a chain receipt is refused" do
    {private_projection, _expected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, chain_result, anchor} = chain_binding_fixture(raw_bundle)

    forged =
      chain_result
      |> Map.put("schema", "comma.triage-identity-transport-result.v1")
      |> Map.drop(~w(canonical_page_chain_bytes canonical_page_chain_sha256))

    assert {:error, :identity_projection_invalid} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               forged,
               anchor
             )
  end

  # Admission binds every exchange to its own physical selector; the recompute
  # skipped the field entirely, so a page read from a different channel could
  # be spliced in as the head of the proof with no selector this side read.
  test "a chain whose first page came from another scope is refused" do
    {private_projection, _expected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, chain_result, anchor} = chain_binding_fixture(raw_bundle)

    foreign_selector =
      raw_bundle
      |> request_selector()
      |> Map.merge(%{"channel_id" => "C_SOMEONE_ELSE", "limit" => 15, "cursor" => ""})
      |> CanonicalJSON.encode!()
      |> CanonicalJSON.sha256()

    spliced =
      put_in(
        chain_result,
        ["receipt", "exchanges", Access.at(0), "request_selector_sha256"],
        foreign_selector
      )

    assert {:error, :identity_projection_invalid} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               spliced,
               anchor
             )

    missing =
      update_in(
        chain_result,
        ["receipt", "exchanges", Access.at(0)],
        &Map.put(&1, "request_selector_sha256", nil)
      )

    assert {:error, :identity_projection_invalid} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               missing,
               anchor
             )
  end

  # The reader's ONE merge licence is dropping the thread parent repeated at the
  # HEAD of a later page. Collapsing an exact repeat anywhere validated merged
  # pages the reader could never have produced.
  test "a chain that de-duplicates outside the head repeat is refused" do
    {private_projection, _expected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, chain_result, anchor} = chain_binding_fixture(raw_bundle)

    page = raw_bundle["slack_page"]
    [root | _rest] = page["messages"]

    # A second page carrying the root TWICE. Dropping the licensed head repeat
    # still leaves one copy over, so the reader could never merge this to the
    # frozen page — but collapsing an exact repeat at any position did.
    repeat_page = %{"messages" => [root, root], "next_cursor" => ""}
    pages = [Map.put(page, "next_cursor", "2"), repeat_page]
    {:ok, chain_bytes} = CanonicalJSON.encode(%{"schema" => @chain_schema, "pages" => pages})

    exchanges =
      pages
      |> Enum.with_index()
      |> Enum.map(fn {chain_page, index} ->
        chain_result["receipt"]["exchanges"]
        |> hd()
        |> Map.merge(%{
          "request_selector_sha256" =>
            page_selector_sha256(raw_bundle, if(index == 0, do: "", else: "2")),
          "canonical_page_sha256" =>
            chain_page |> CanonicalJSON.encode!() |> CanonicalJSON.sha256(),
          "message_count" => length(chain_page["messages"]),
          "next_cursor_empty" => chain_page["next_cursor"] == ""
        })
      end)

    forged =
      chain_result
      |> put_in(["receipt", "exchanges"], exchanges)
      |> put_in(["receipt", "transport_invocation_count"], 2)
      |> put_in(["receipt", "canonical_page_chain_sha256"], CanonicalJSON.sha256(chain_bytes))
      |> Map.put("canonical_page_chain_bytes", chain_bytes)
      |> Map.put("canonical_page_chain_sha256", CanonicalJSON.sha256(chain_bytes))

    assert {:error, :identity_projection_invalid} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               forged,
               anchor
             )
  end

  # No authorized read can spend more exchanges — or return more objects — than
  # its own bounds, so a receipt claiming either is a forgery, not a big thread.
  test "a chain claiming more budget or more objects than the authorized read is refused" do
    {private_projection, _expected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, chain_result, anchor} = chain_binding_fixture(raw_bundle)

    for forged <- [
          put_in(chain_result, ["receipt", "page_budget"], 64),
          put_in(chain_result, ["receipt", "message_count"], 201)
        ] do
      assert {:error, :identity_projection_invalid} =
               IdentityContract.recompute_bound_projection(
                 private_projection,
                 claim,
                 forged,
                 anchor
               )
    end
  end

  test "bound recomputation rejects drift at every external identity-chain binding" do
    {private_projection, _expected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, transport_result, winning_source_anchor} = binding_fixture(raw_bundle)
    alternate_sha256 = String.duplicate("d", 64)

    mutations = [
      {"receipt selector", private_projection, claim,
       put_in(transport_result, ["receipt", "request_selector_sha256"], alternate_sha256),
       winning_source_anchor},
      {"receipt origin", private_projection, claim,
       put_in(transport_result, ["receipt", "slack_api_origin_sha256"], alternate_sha256),
       winning_source_anchor},
      {"receipt operation", private_projection, claim,
       put_in(transport_result, ["receipt", "operation"], "conversations.history"),
       winning_source_anchor},
      {"source observation", private_projection,
       Map.put(claim, "source_observation_sha256", alternate_sha256), transport_result,
       winning_source_anchor},
      {"identity profile", private_projection,
       Map.put(claim, "identity_profile_sha256", alternate_sha256), transport_result,
       winning_source_anchor},
      {"classified messages", private_projection, claim,
       Map.put(transport_result, "classified_private_messages_sha256", alternate_sha256),
       winning_source_anchor},
      {"winning sealed events", private_projection, claim, transport_result,
       put_in(
         winning_source_anchor,
         ["sealed_events", Access.at(0), "text"],
         "different sealed input"
       )},
      {"winning source authority", private_projection, claim, transport_result,
       put_in(winning_source_anchor, ["source_authority", "thread_ts"], "999.001")}
    ]

    Enum.each(mutations, fn {binding, projection, bound_claim, result, anchor} ->
      assert {:error, :identity_projection_invalid} =
               IdentityContract.recompute_bound_projection(
                 projection,
                 bound_claim,
                 result,
                 anchor
               ),
             binding
    end)

    incomplete_deny_projection =
      Map.update!(private_projection, "raw_deny_literals", &Enum.drop(&1, 1))

    assert {:ok, _recomputed} =
             IdentityContract.recompute_bound_projection(
               incomplete_deny_projection,
               claim,
               transport_result,
               winning_source_anchor
             )
  end

  test "bound decisions accept exact projected silence and reply closures" do
    {private_projection, projected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, transport_result, winning_source_anchor} = binding_fixture(raw_bundle)

    silence = %{
      "action" => "silence",
      "identity_interpretation" => %{
        "topic" => "self_identity",
        "referenced_principal_refs" => ["principal://run/self"]
      },
      "source_refs" => []
    }

    [reply_source_ref | _] = projected_context["decision_contract"]["source_refs"]

    reply = %{
      "action" => "reply",
      "identity_interpretation" => %{
        "topic" => "self_identity",
        "referenced_principal_refs" => ["principal://run/self"]
      },
      "source_refs" => [reply_source_ref],
      "text" => "I am @self, the router for this thread."
    }

    assert :ok =
             IdentityContract.validate_bound_decision(
               silence,
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )

    assert :ok =
             IdentityContract.validate_bound_decision(
               reply,
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )
  end

  test "v3 callback snapshots retain both historical product decision schemas" do
    {projection, expected} = fixture()
    bundle = Jason.decode!(projection["raw_source_bundle_bytes"])
    aliases = Jason.decode!(projection["alias_map_bytes"])
    identity = Map.put(bundle["raw_identity_context"], "source_mode", "callback")

    bundle =
      bundle
      |> Map.put("raw_identity_context", identity)
      |> put_in(["raw_context", "identity_context"], identity)
      |> update_in(
        ["sealed_events"],
        &Enum.map(&1, fn event -> Map.put(event, "source_mode", "callback") end)
      )

    expected = put_in(expected, ["identity_context", "source_mode"], "callback")
    projection = private_projection(bundle, bundle["raw_context"], aliases, expected)
    {claim, transport, anchor} = binding_fixture(bundle)
    anchor = Map.put(anchor, "source_mode", "callback")

    assert {:ok, %{projected_context: ^expected}} =
             IdentityContract.recompute_bound_projection(projection, claim, transport, anchor)

    legacy = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{"kind" => "silence", "reason" => "duplicate", "source_refs" => []},
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    current =
      Map.merge(legacy, %{
        "schema" => "comma.triage-product-decision.v2",
        "companion_reaction" => nil
      })

    for decision <- [legacy, current] do
      assert :ok =
               IdentityContract.validate_replayed_bound_decision(
                 decision,
                 projection,
                 claim,
                 transport,
                 anchor
               )

      invalid = put_in(decision, ["communication", "reason"], "outside_authority")

      assert {:error, :identity_decision_invalid} =
               IdentityContract.validate_replayed_bound_decision(
                 invalid,
                 projection,
                 claim,
                 transport,
                 anchor
               )
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :identity_decision_invalid} =
                 IdentityContract.validate_bound_decision(
                   current,
                   projection,
                   claim,
                   transport,
                   anchor
                 )
      end)

    assert log =~ "triage_identity_decision_rejected stage=decision_schema"
  end

  test "bound decisions reject alternate schemas and references outside their source scope" do
    {private_projection, projected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, transport_result, winning_source_anchor} = binding_fixture(raw_bundle)
    [reply_source_ref | _] = projected_context["decision_contract"]["source_refs"]

    valid_reply = %{
      "action" => "reply",
      "identity_interpretation" => %{
        "topic" => "self_identity",
        "referenced_principal_refs" => ["principal://run/self"]
      },
      "source_refs" => [reply_source_ref],
      "text" => "I am @self, the router for this thread."
    }

    invalid_decisions = [
      {"extra key", Map.put(valid_reply, "unexpected", "value")},
      {"nonprojected source ref", Map.put(valid_reply, "source_refs", ["source://run/s999"])},
      {"nonprojected principal ref",
       put_in(
         valid_reply,
         ["identity_interpretation", "referenced_principal_refs"],
         ["principal://run/p999"]
       )}
    ]

    Enum.each(invalid_decisions, fn {case_name, decision} ->
      assert {:error, :identity_decision_invalid} =
               IdentityContract.validate_bound_decision(
                 decision,
                 private_projection,
                 claim,
                 transport_result,
                 winning_source_anchor
               ),
             case_name
    end)
  end

  test "bound product decisions retain multilingual assessment and diagnose rejected references" do
    {projection, expected} = expression_fixture()
    bundle = Jason.decode!(projection["raw_source_bundle_bytes"])
    aliases = Jason.decode!(projection["alias_map_bytes"])
    identity = Map.put(bundle["raw_identity_context"], "source_mode", "callback")

    bundle =
      bundle
      |> Map.put("raw_identity_context", identity)
      |> put_in(["raw_context", "identity_context"], identity)
      |> update_in(
        ["sealed_events"],
        &Enum.map(&1, fn event -> Map.put(event, "source_mode", "callback") end)
      )

    expected = put_in(expected, ["identity_context", "source_mode"], "callback")
    projection = private_projection(bundle, bundle["raw_context"], aliases, expected)
    {claim, transport, anchor} = binding_fixture(bundle)
    anchor = Map.put(anchor, "source_mode", "callback")

    decision = %{
      "schema" => "comma.triage-product-decision.v2",
      "assessment" => %{
        "requested_outcome" => "Explain the observed error",
        "available_evidence" => String.duplicate("已检查来源。", 100),
        "unread_source_refs" => [],
        "unavailable_input" => ""
      },
      "communication" => %{"kind" => "silence", "reason" => "duplicate", "source_refs" => []},
      "companion_reaction" => nil,
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    assert :ok =
             IdentityContract.validate_bound_decision(
               decision,
               projection,
               claim,
               transport,
               anchor
             )

    private_ref = "source://private/CANARY"
    invalid = put_in(decision, ["assessment", "unread_source_refs"], [private_ref])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :identity_decision_invalid} =
                 IdentityContract.validate_bound_decision(
                   invalid,
                   projection,
                   claim,
                   transport,
                   anchor
                 )
      end)

    assert log =~ "check=assessment_unread_source_refs"
    refute log =~ private_ref
    refute log =~ "已检查来源"
    assert byte_size(log) < 1000
  end

  test "bound replies allow authorized identity and links but still reject credentials" do
    {private_projection, projected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, transport_result, winning_source_anchor} = binding_fixture(raw_bundle)
    [source_ref | _] = projected_context["decision_contract"]["source_refs"]

    validate = fn text ->
      IdentityContract.validate_bound_decision(
        %{
          "action" => "reply",
          "identity_interpretation" => %{
            "topic" => "none",
            "referenced_principal_refs" => []
          },
          "source_refs" => [source_ref],
          "text" => text
        },
        private_projection,
        claim,
        transport_result,
        winning_source_anchor
      )
    end

    assert :ok =
             validate.(
               "Peng <@U_PENG> uses peng@example.com; see https://example.com/review and /tmp/report."
             )

    for credential <- [
          "xoxb-forbidden",
          "api_key = opaque-fixture-secret",
          "Bearer fixture-secret"
        ] do
      assert {:error, :identity_decision_invalid} = validate.(credential)
    end
  end

  test "bound decision validation preserves projection-invalid chain drift" do
    {private_projection, _projected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, transport_result, winning_source_anchor} = binding_fixture(raw_bundle)

    silence = %{
      "action" => "silence",
      "identity_interpretation" => %{
        "topic" => "self_identity",
        "referenced_principal_refs" => ["principal://run/self"]
      },
      "source_refs" => []
    }

    drifted_claim =
      Map.put(claim, "identity_profile_sha256", String.duplicate("d", 64))

    assert {:error, :identity_projection_invalid} =
             IdentityContract.validate_bound_decision(
               silence,
               private_projection,
               drifted_claim,
               transport_result,
               winning_source_anchor
             )
  end

  test "bound-chain drift takes precedence over a non-map model decision" do
    {private_projection, _projected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, transport_result, winning_source_anchor} = binding_fixture(raw_bundle)

    drifted_claim =
      Map.put(claim, "identity_profile_sha256", String.duplicate("d", 64))

    validate = fn bound_claim ->
      apply(IdentityContract, :validate_bound_decision, [
        nil,
        private_projection,
        bound_claim,
        transport_result,
        winning_source_anchor
      ])
    end

    actual = %{
      clean_chain: validate.(claim),
      drifted_chain: validate.(drifted_claim)
    }

    assert actual == %{
             clean_chain: {:error, :identity_decision_invalid},
             drifted_chain: {:error, :identity_projection_invalid}
           }
  end

  test "bound decision free text allows projected aliases and ordinary uppercase words only" do
    {private_projection, projected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, transport_result, winning_source_anchor} = binding_fixture(raw_bundle)
    [reply_source_ref | _] = projected_context["decision_contract"]["source_refs"]

    reply = %{
      "action" => "reply",
      "identity_interpretation" => %{
        "topic" => "identity_relation",
        "referenced_principal_refs" => ["principal://run/self", "principal://run/p001"]
      },
      "source_refs" => [reply_source_ref],
      "text" => "BACKGROUND TRANSACTION AUTHORITY CHANGELOG with @self and @human:p001."
    }

    validate = fn decision ->
      IdentityContract.validate_bound_decision(
        decision,
        private_projection,
        claim,
        transport_result,
        winning_source_anchor
      )
    end

    actual = %{
      projected_aliases: validate.(reply),
      invented_agent_alias:
        reply
        |> Map.put("text", "Ask @agent:p999 to answer.")
        |> validate.(),
      invented_human_alias:
        reply
        |> Map.put("text", "Ask @human:p999 to answer.")
        |> validate.()
    }

    assert actual == %{
             projected_aliases: :ok,
             invented_agent_alias: {:error, :identity_decision_invalid},
             invented_human_alias: {:error, :identity_decision_invalid}
           }
  end

  test "meeting fact text is redacted like Slack text and never reaches the projected bytes" do
    {private_projection, expected_context, raw_text} = fixture_with_meeting_fact_literals()

    assert {:ok, %{projected_context: ^expected_context, canonical_bytes: projected_bytes}} =
             IdentityContract.recompute_projected_context(private_projection)

    assert get_in(expected_context, ["team_project_memory", "facts", Access.at(0), "text"]) ==
             "Close https:@path and ping @email"

    # The freeze harvests every URI and email in the raw bundle as a deny
    # literal, so a meeting fact that reached the projection verbatim would
    # reject the very projection that produced it.
    assert "https://runbooks.example.test/login/incident" in private_projection[
             "raw_deny_literals"
           ]

    assert "lin@example.test" in private_projection["raw_deny_literals"]

    refute projected_bytes =~ raw_text
    refute projected_bytes =~ "https://runbooks.example.test/login/incident"
    refute projected_bytes =~ "lin@example.test"
  end

  test "bound decision aliases come only from the structured projected registry" do
    {private_projection, projected_context} = fixture_with_member_and_free_text_alias()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {claim, transport_result, winning_source_anchor} = binding_fixture(raw_bundle)
    [reply_source_ref | _] = projected_context["decision_contract"]["source_refs"]

    assert {:ok, %{projected_context: ^projected_context}} =
             IdentityContract.recompute_bound_projection(
               private_projection,
               claim,
               transport_result,
               winning_source_anchor
             )

    reply = %{
      "action" => "reply",
      "identity_interpretation" => %{
        "topic" => "identity_relation",
        "referenced_principal_refs" => ["principal://run/self", "principal://run/p001"]
      },
      "source_refs" => [reply_source_ref],
      "text" => "Coordinate with @member:m001."
    }

    validate = fn decision ->
      IdentityContract.validate_bound_decision(
        decision,
        private_projection,
        claim,
        transport_result,
        winning_source_anchor
      )
    end

    actual = %{
      structured_member_alias: validate.(reply),
      invented_member_alias:
        reply
        |> Map.put("text", "Coordinate with @member:m999.")
        |> validate.(),
      alias_from_reviewed_free_text_only:
        reply
        |> Map.put("text", "Echo @agent:p999 from reviewed Slack text.")
        |> validate.()
    }

    assert actual == %{
             structured_member_alias: :ok,
             invented_member_alias: {:error, :identity_decision_invalid},
             alias_from_reviewed_free_text_only: {:error, :identity_decision_invalid}
           }
  end

  test "rejects a coherently shaped alternate raw context hash" do
    {private_projection, _expected_context} = fixture()

    assert {:error, :identity_projection_invalid} =
             private_projection
             |> Map.put("raw_context_sha256", String.duplicate("f", 64))
             |> IdentityContract.recompute_projected_context()
  end

  for field <- ~w(bot_token authorization api_key access_token client_secret signing_secret) do
    test "rejects credential field #{field} even when the bundle hash is updated" do
      {private_projection, _expected_context} = fixture()
      {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])

      raw_bundle =
        put_in(raw_bundle, ["connect_identity", unquote(field)], "opaque-fixture-secret")

      {:ok, raw_bundle_bytes} = CanonicalJSON.encode(raw_bundle)

      private_projection =
        private_projection
        |> Map.put("raw_source_bundle_bytes", raw_bundle_bytes)
        |> Map.put("raw_source_bundle_sha256", CanonicalJSON.sha256(raw_bundle_bytes))

      assert {:error, :identity_projection_invalid} =
               IdentityContract.recompute_projected_context(private_projection)
    end
  end

  for credential <- [
        "xoxb-forbidden",
        "Bearer fixture-secret",
        "api_key = opaque-fixture-secret",
        ~s({"apiKey": "opaque-fixture-secret"}),
        "CLIENT_SECRET='opaque-fixture-secret'",
        "signing-secret: opaque-fixture-secret",
        "accessToken = opaque-fixture-secret",
        "Authorization: Basic Zml4dHVyZQ==",
        ~s({"authorization": "Basic Zml4dHVyZQ=="}),
        "sk-live-fixture-secret",
        "sk-abcdefghijklmnop",
        "ghp_abcdefghijklmnopqrst",
        "AKIA1234567890123456",
        "-----BEGIN PRIVATE KEY-----"
      ] do
    test "rejects credential-shaped material #{credential} recursively before projection" do
      {private_projection, _expected_context} = fixture()
      {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])

      raw_bundle =
        raw_bundle
        |> put_in(["slack_page", "messages", Access.at(0), "text"], unquote(credential))
        |> put_in(
          ["raw_context", "slack_context", "messages", Access.at(0), "text"],
          unquote(credential)
        )

      {:ok, raw_bundle_bytes} = CanonicalJSON.encode(raw_bundle)
      {:ok, raw_context_bytes} = CanonicalJSON.encode(raw_bundle["raw_context"])

      private_projection =
        private_projection
        |> Map.put("raw_source_bundle_bytes", raw_bundle_bytes)
        |> Map.put("raw_source_bundle_sha256", CanonicalJSON.sha256(raw_bundle_bytes))
        |> Map.put("raw_context_sha256", CanonicalJSON.sha256(raw_context_bytes))

      assert {:error, :identity_projection_privacy_rejected} =
               IdentityContract.recompute_projected_context(private_projection)
    end
  end

  test "ordinary authorized material is not rejected by the retired identity deny list" do
    {private_projection, _expected_context} = fixture()

    private_projection =
      Map.update!(private_projection, "raw_deny_literals", fn literals ->
        Enum.sort(["Alpha" | literals])
      end)

    assert {:ok, _projection} =
             IdentityContract.recompute_projected_context(private_projection)
  end

  defp fixture do
    {private_projection, projected_context} = expression_fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {:ok, alias_map} = Jason.decode(private_projection["alias_map_bytes"])

    raw_slack = raw_bundle["raw_context"]["slack_context"]

    legacy_raw_slack = %{
      "messages" => Enum.map(raw_slack["messages"], &Map.delete(&1, "reactions")),
      "source_refs" => raw_slack["source_refs"]
    }

    legacy_source_observation =
      update_in(raw_bundle, ["source_observation", "modules"], fn modules ->
        Enum.reject(modules, &(&1["module"] == "Elixir.SalixIM.Triage.ExpressionContext"))
      end)["source_observation"]

    legacy_bundle =
      raw_bundle
      |> Map.put("schema", "comma.triage-private-source-bundle.v3")
      |> Map.put("source_observation", legacy_source_observation)
      |> put_in(
        ["slack_page", "messages"],
        Enum.map(raw_bundle["slack_page"]["messages"], &Map.delete(&1, "reactions"))
      )
      |> put_in(["raw_context", "slack_context"], legacy_raw_slack)

    legacy_projected_slack =
      projected_context["slack_context"]
      |> Map.delete("expression_context")
      |> Map.update!("messages", fn messages ->
        Enum.map(messages, &Map.delete(&1, "observed_reactions"))
      end)

    legacy_projected_context =
      Map.put(projected_context, "slack_context", legacy_projected_slack)

    {
      private_projection(
        legacy_bundle,
        legacy_bundle["raw_context"],
        alias_map,
        legacy_projected_context
      ),
      legacy_projected_context
    }
  end

  defp expression_fixture do
    project_ref = "bft://projects/project-atlas"
    agent_ref = "bft://projects/project-atlas/agents/agent-router"
    endpoint_ref = "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
    message_ref = "slack://T_ATLAS/C_ATLAS/200.001/200.001"
    human_ref = "slack-principal://T_ATLAS/U_PENG"
    human_mention_ref = "#{message_ref}/mentions/U_PENG"
    self_mention_ref = "#{message_ref}/mentions/U_BFT"

    raw_identity =
      raw_identity(
        agent_ref,
        endpoint_ref,
        human_ref,
        message_ref,
        human_mention_ref,
        self_mention_ref
      )

    product_context = product_context(project_ref)

    raw_message = %{
      "actor_id" => "U_PENG",
      "actor_kind" => "human",
      "message_ts" => "200.001",
      "text" => "<@U_PENG> can you answer? <@U_BFT> who are you?",
      "source_ref" => message_ref,
      "reactions" => [%{"name" => "eyes", "count" => 2}]
    }

    {:ok, expression_context} =
      ExpressionContext.build("project", {:error, :unavailable}, [raw_message])

    raw_context = %{
      "slack_context" => %{
        "messages" => [raw_message],
        "source_refs" => [message_ref],
        "expression_context" => expression_context
      },
      "team_project_memory" => product_context,
      "answered_recheck" => %{
        "answered" => false,
        "checked_at" => "2026-08-15T00:00:00.000Z",
        "source_refs" => [message_ref]
      },
      "identity_context" => raw_identity
    }

    source_observation = %{
      "schema" => "comma.triage-source-observation.v1",
      "modules" =>
        [
          "Elixir.BridgeForTeams.TriageContext",
          "Elixir.BridgeForTeams.TriageContext.ProductSource",
          "Elixir.SalixIM.ProviderConnects",
          "Elixir.SalixIM.Triage.ExpressionContext",
          "Elixir.Salix.Bindings.SlackTriageThreadReader"
        ]
        |> Enum.with_index(1)
        |> Enum.map(fn {module, index} ->
          %{
            "module" => module,
            "object_code_sha256" => String.duplicate(Integer.to_string(index), 64)
          }
        end)
    }

    raw_bundle = %{
      "schema" => "comma.triage-private-source-bundle.v4",
      "sealed_events" => [sealed_event()],
      "slack_page" => %{
        "messages" => [
          %{
            "ts" => "200.001",
            "user" => "U_PENG",
            "text" => "<@U_PENG> can you answer? <@U_BFT> who are you?",
            "reactions" => [%{"name" => "eyes", "count" => 2}]
          }
        ],
        "next_cursor" => ""
      },
      "source_authority" => source_authority(),
      "root_ts" => "200.001",
      "source_observation" => source_observation,
      "connect_identity" => connect_identity(),
      "product_identity" => product_identity(),
      "product_context" => product_context,
      "raw_context" => raw_context,
      "raw_identity_context" => raw_identity,
      "target_cutoff" => %{"event_message_timestamps" => ["200.001"]}
    }

    source_aliases =
      [
        project_ref,
        agent_ref,
        endpoint_ref,
        message_ref,
        human_mention_ref,
        self_mention_ref
      ]
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Map.new(fn {ref, index} -> {ref, "source://run/s#{ordinal(index)}"} end)

    alias_map = %{
      "principals" => %{
        "comma-agent://agt1_atlas_router" => "principal://run/self",
        human_ref => "principal://run/p001"
      },
      "provider_principals" => %{
        "U_BFT" => "principal://run/self",
        "U_PENG" => "principal://run/p001"
      },
      "participants" => %{},
      "sources" => source_aliases,
      "messages" => %{message_ref => "message://run/m001"},
      "members" => %{},
      "links" => %{},
      "project" => %{project_ref => "project://run/p001"}
    }

    projected_identity = projected_identity(raw_identity, source_aliases)

    projected_slack = %{
      "messages" => [
        %{
          "ordinal" => 1,
          "actor_ref" => "principal://run/p001",
          "actor_kind" => "human",
          "message_ref" => "message://run/m001",
          "text" => "@human:p001 can you answer? @self who are you?",
          "source_ref" => source_aliases[message_ref],
          "observed_reactions" => [%{"emoji" => "eyes", "count" => 2}]
        }
      ],
      "source_refs" => [source_aliases[message_ref]],
      "links" => [],
      "expression_context" => expression_context,
      "decision_target" => %{
        "ordinal" => 1,
        "message_ref" => "message://run/m001",
        "source_ref" => source_aliases[message_ref],
        "link_refs" => [],
        "syntactic_addressee" => "mixed"
      }
    }

    projected_memory = %{
      "project" => %{
        "entity_ref" => "project://run/p001",
        "display_alias" => "@project:p001",
        "status" => "active",
        "source_ref" => source_aliases[project_ref]
      },
      "member_roster" => %{
        "completeness" => "truncated",
        "truncated" => true,
        "limit" => 25,
        "returned_count" => 0
      },
      "members" => [],
      "facts" => [],
      "source_refs" => [source_aliases[project_ref]]
    }

    expected_context = %{
      "slack_context" => projected_slack,
      "identity_context" => projected_identity,
      "team_project_memory" => projected_memory,
      "answered_recheck" => %{"answered" => false},
      "decision_contract" => %{
        "source_refs" =>
          (projected_slack["source_refs"] ++
             projected_identity["source_refs"] ++ projected_memory["source_refs"])
          |> Enum.uniq()
          |> Enum.sort(),
        "principal_refs" => projected_identity["principal_refs"],
        "remember_forbidden_source_refs" => projected_identity["remember_forbidden_source_refs"]
      }
    }

    {private_projection(raw_bundle, raw_context, alias_map, expected_context), expected_context}
  end

  # One meeting action item carrying free provider text with a URL and an email.
  # The `zz-` prefix keeps both new source refs sorted after every existing one,
  # so the base fixture's alias ordinals stay stable.
  defp fixture_with_meeting_fact_literals do
    {private_projection, projected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {:ok, alias_map} = Jason.decode(private_projection["alias_map_bytes"])

    meeting_ref = "zz-meeting://meeting-weekly-7"
    fact_ref = meeting_ref <> "/action-item/0"
    raw_text = "Close https://runbooks.example.test/login/incident and ping lin@example.test"
    project_ref = get_in(raw_bundle, ["product_context", "project", "source_ref"])

    raw_fact = %{
      "kind" => "meeting_action_item",
      "text" => raw_text,
      "owner" => "",
      "deadline" => "",
      "source_ref" => fact_ref
    }

    raw_memory =
      raw_bundle["product_context"]
      |> Map.put("facts", [raw_fact])
      |> Map.put(
        "source_refs",
        IdentityContract.raw_memory_source_refs(project_ref, [], [raw_fact])
      )

    raw_bundle =
      raw_bundle
      |> Map.put("product_context", raw_memory)
      |> put_in(["raw_context", "team_project_memory"], raw_memory)

    source_aliases =
      Map.merge(alias_map["sources"], %{
        meeting_ref => "source://run/s007",
        fact_ref => "source://run/s008"
      })

    alias_map = Map.put(alias_map, "sources", source_aliases)

    projected_memory =
      projected_context["team_project_memory"]
      |> Map.put("facts", [
        %{
          "kind" => "meeting_action_item",
          "text" => "Close https:@path and ping @email",
          "owner_ref" => nil,
          "deadline" => nil,
          "source_ref" => source_aliases[fact_ref]
        }
      ])
      |> Map.put("source_refs", [source_aliases[project_ref], source_aliases[fact_ref]])

    projected_context =
      projected_context
      |> Map.put("team_project_memory", projected_memory)
      |> put_in(
        ["decision_contract", "source_refs"],
        (projected_context["slack_context"]["source_refs"] ++
           projected_context["identity_context"]["source_refs"] ++
           projected_memory["source_refs"])
        |> Enum.uniq()
        |> Enum.sort()
      )

    {private_projection(raw_bundle, raw_bundle["raw_context"], alias_map, projected_context),
     projected_context, raw_text}
  end

  defp fixture_with_member_and_free_text_alias do
    {private_projection, projected_context} = fixture()
    {:ok, raw_bundle} = Jason.decode(private_projection["raw_source_bundle_bytes"])
    {:ok, alias_map} = Jason.decode(private_projection["alias_map_bytes"])

    member_ref = "zz-member://project-atlas/member-peng"
    member_source_alias = "source://run/s007"

    raw_member = %{
      "key" => "member-peng",
      "display_name" => "Peng",
      "rbac_role" => "admin",
      "source_ref" => member_ref
    }

    raw_memory =
      raw_bundle["product_context"]
      |> Map.put("members", [raw_member])
      |> put_in(["member_roster", "returned_count"], 1)
      |> Map.put("source_refs", [
        get_in(raw_bundle, ["product_context", "project", "source_ref"]),
        member_ref
      ])

    raw_slack_text = "Review @agent:p999 with <@U_PENG> and <@U_BFT>."

    raw_bundle =
      raw_bundle
      |> put_in(["slack_page", "messages", Access.at(0), "text"], raw_slack_text)
      |> put_in(
        ["raw_context", "slack_context", "messages", Access.at(0), "text"],
        raw_slack_text
      )
      |> Map.put("product_context", raw_memory)
      |> put_in(["raw_context", "team_project_memory"], raw_memory)

    alias_map =
      alias_map
      |> put_in(["sources", member_ref], member_source_alias)
      |> put_in(["members", member_ref], "member://run/m001")

    projected_slack =
      put_in(
        projected_context,
        ["slack_context", "messages", Access.at(0), "text"],
        "Review @agent:p999 with @human:p001 and @self."
      )["slack_context"]

    projected_memory =
      projected_context["team_project_memory"]
      |> Map.put("members", [
        %{
          "entity_ref" => "member://run/m001",
          "display_alias" => "@member:m001",
          "rbac_role" => "admin",
          "source_ref" => member_source_alias
        }
      ])
      |> put_in(["member_roster", "returned_count"], 1)
      |> Map.put("source_refs", [
        get_in(projected_context, ["team_project_memory", "project", "source_ref"]),
        member_source_alias
      ])

    projected_context =
      projected_context
      |> Map.put("slack_context", projected_slack)
      |> Map.put("team_project_memory", projected_memory)
      |> put_in(
        ["decision_contract", "source_refs"],
        (projected_slack["source_refs"] ++
           projected_context["identity_context"]["source_refs"] ++
           projected_memory["source_refs"])
        |> Enum.uniq()
        |> Enum.sort()
      )

    raw_context = raw_bundle["raw_context"]

    {
      private_projection(raw_bundle, raw_context, alias_map, projected_context),
      projected_context
    }
  end

  defp raw_identity(
         agent_ref,
         endpoint_ref,
         human_ref,
         message_ref,
         human_mention_ref,
         self_mention_ref
       ) do
    {:ok, endpoint_revision} = IdentityContract.endpoint_revision_sha256(connect_identity())

    agent = %{
      "source_ref" => agent_ref,
      "principal_ref" => "comma-agent://agt1_atlas_router",
      "agent_id" => "agt1_atlas_router",
      "role" => "router",
      "display_name" => "BFT",
      "persona_revision_sha256" => String.duplicate("a", 64)
    }

    {:ok, identity_revision} = IdentityContract.identity_revision_sha256(agent)

    identity = %{
      "schema" => "comma.triage-identity-context.v1",
      "source_mode" => "historical_thread_reenactment",
      "self_agent" => Map.put(agent, "identity_revision_sha256", identity_revision),
      "self_endpoint" => %{
        "source_ref" => endpoint_ref,
        "provider" => "slack",
        "workspace_id" => "T_ATLAS",
        "connect_id" => "connect-atlas",
        "connect_generation" => "generation-7",
        "provider_app_id" => "A_BFT",
        "bot_user_id" => "U_BFT",
        "bot_id" => "B_BFT",
        "display_aliases" => ["Zeta", "Alpha"],
        "represents_principal_ref" => "comma-agent://agt1_atlas_router",
        "revision_sha256" => endpoint_revision,
        "revision_status" => "exact"
      },
      "observed_principals" => [
        %{
          "principal_ref" => human_ref,
          "provider" => "slack",
          "kind" => "human",
          "relation_to_self" => "other",
          "display_aliases" => [],
          "evidence_tier" => "thread_authorship",
          "source_refs" => [message_ref]
        }
      ],
      "mention_evidence" => [
        %{
          "principal_ref" => human_ref,
          "provider_user_id" => "U_PENG",
          "message_source_ref" => message_ref,
          "selectors" => ["text_token"],
          "source_ref" => human_mention_ref,
          "source_refs" => [message_ref]
        },
        %{
          "principal_ref" => "comma-agent://agt1_atlas_router",
          "provider_user_id" => "U_BFT",
          "message_source_ref" => message_ref,
          "selectors" => ["text_token"],
          "source_ref" => self_mention_ref,
          "source_refs" => [message_ref]
        }
      ]
    }

    identity
    |> Map.put("principal_refs", IdentityContract.principal_refs(identity))
    |> Map.put(
      "remember_forbidden_source_refs",
      IdentityContract.remember_forbidden_source_refs(identity)
    )
    |> Map.put("source_refs", IdentityContract.source_refs(identity))
  end

  defp projected_identity(raw_identity, sources) do
    agent_source = sources[get_in(raw_identity, ["self_agent", "source_ref"])]
    endpoint_source = sources[get_in(raw_identity, ["self_endpoint", "source_ref"])]

    %{
      "schema" => "comma.triage-identity-model-context.v1",
      "source_mode" => "historical_thread_reenactment",
      "self_agent" => %{
        "principal_ref" => "principal://run/self",
        "display_alias" => "@self",
        "role" => "router",
        "source_ref" => agent_source
      },
      "self_endpoint" => %{
        "endpoint_ref" => "endpoint://run/self",
        "provider" => "slack",
        "display_aliases" => ["@self", "Alpha", "Zeta"],
        "represents_principal_ref" => "principal://run/self",
        "revision_status" => "exact",
        "source_ref" => endpoint_source
      },
      "observed_principals" => [
        %{
          "principal_ref" => "principal://run/p001",
          "provider" => "slack",
          "kind" => "human",
          "relation_to_self" => "other",
          "display_aliases" => ["@human:p001"],
          "evidence_tier" => "thread_authorship",
          "source_refs" => [sources["slack://T_ATLAS/C_ATLAS/200.001/200.001"]]
        }
      ],
      "mention_evidence" => [
        %{
          "principal_ref" => "principal://run/p001",
          "message_ref" => "message://run/m001",
          "message_source_ref" => sources["slack://T_ATLAS/C_ATLAS/200.001/200.001"],
          "selectors" => ["text_token"],
          "source_ref" => sources["slack://T_ATLAS/C_ATLAS/200.001/200.001/mentions/U_PENG"],
          "source_refs" => [sources["slack://T_ATLAS/C_ATLAS/200.001/200.001"]]
        },
        %{
          "principal_ref" => "principal://run/self",
          "message_ref" => "message://run/m001",
          "message_source_ref" => sources["slack://T_ATLAS/C_ATLAS/200.001/200.001"],
          "selectors" => ["text_token"],
          "source_ref" => sources["slack://T_ATLAS/C_ATLAS/200.001/200.001/mentions/U_BFT"],
          "source_refs" => [sources["slack://T_ATLAS/C_ATLAS/200.001/200.001"]]
        }
      ],
      "principal_refs" => ["principal://run/self", "principal://run/p001"],
      "remember_forbidden_source_refs" =>
        [
          agent_source,
          endpoint_source,
          "principal://run/self",
          "principal://run/p001",
          sources["slack://T_ATLAS/C_ATLAS/200.001/200.001/mentions/U_BFT"],
          sources["slack://T_ATLAS/C_ATLAS/200.001/200.001/mentions/U_PENG"]
        ]
        |> Enum.sort(),
      "source_refs" =>
        [
          agent_source,
          endpoint_source,
          sources["slack://T_ATLAS/C_ATLAS/200.001/200.001"],
          sources["slack://T_ATLAS/C_ATLAS/200.001/200.001/mentions/U_BFT"],
          sources["slack://T_ATLAS/C_ATLAS/200.001/200.001/mentions/U_PENG"]
        ]
        |> Enum.sort()
    }
  end

  defp product_context(project_ref) do
    %{
      "project" => %{
        "key" => "project-atlas",
        "name" => "Atlas",
        "status" => "active",
        "source_ref" => project_ref
      },
      "member_roster" => %{
        "completeness" => "truncated",
        "truncated" => true,
        "limit" => 25,
        "returned_count" => 0
      },
      "members" => [],
      "facts" => [],
      "source_refs" => [project_ref]
    }
  end

  defp sealed_event do
    {:ok, endpoint_revision} = IdentityContract.endpoint_revision_sha256(connect_identity())

    %{
      "event_id" => "Ev1",
      "connect_generation" => "generation-7",
      "message_ts" => "200.001",
      "actor_id" => "U_PENG",
      "actor_kind" => "human",
      "text" => "Who are you?",
      "event_type" => "message",
      "addressing_kind" => "ambient",
      "trigger_kind" => "question_heuristic",
      "fast_path" => true,
      "bucket" => %{
        "workspace_id" => "T_ATLAS",
        "channel_id" => "C_ATLAS",
        "thread_ts" => "200.001"
      },
      "endpoint_provenance" => %{
        "schema" => "comma.slack-endpoint-provenance.v1",
        "captured_at_ms" => 1_780_000_000_000,
        "callback_api_app_id" => "A_BFT",
        "fast_path_bot_user_id" => "U_BFT",
        "endpoint_revision_sha256" => endpoint_revision
      },
      "source_mode" => "historical_thread_reenactment"
    }
  end

  defp source_authority do
    %{
      "connect_id" => "connect-atlas",
      "connect_generation" => "generation-7",
      "workspace_id" => "T_ATLAS",
      "channel_id" => "C_ATLAS",
      "thread_ts" => "200.001"
    }
  end

  defp connect_identity do
    %{
      "provider" => "slack",
      "tenant_id" => "tenant-atlas",
      "group_id" => "project-atlas",
      "connect_id" => "connect-atlas",
      "connect_generation" => "generation-7",
      "workspace_id" => "T_ATLAS",
      "approved_channel_id" => "C_ATLAS",
      "inbound_agent_id" => "agt1_atlas_router",
      "app_id" => "A_BFT",
      "bot_user_id" => "U_BFT",
      "bot_id" => "B_BFT"
    }
  end

  defp product_identity do
    %{
      "project_id" => "project-atlas",
      "project_status" => "active",
      "project_archived_at" => nil,
      "project_salix_group_id" => "project-atlas",
      "agent_id" => "agent-router",
      "agent_project_id" => "project-atlas",
      "salix_agent_id" => "agt1_atlas_router",
      "agent_status" => "active",
      "agent_archived_at" => nil,
      "agent_role" => "router",
      "agent_name" => "BFT"
    }
  end

  defp private_projection(raw_bundle, raw_context, alias_map, projected_context) do
    {:ok, raw_bundle_bytes} = CanonicalJSON.encode(raw_bundle)
    {:ok, raw_context_bytes} = CanonicalJSON.encode(raw_context)
    {:ok, alias_map_bytes} = CanonicalJSON.encode(alias_map)
    {:ok, projected_bytes} = CanonicalJSON.encode(projected_context)

    {:ok, policy_bytes} =
      CanonicalJSON.encode(%{
        "schema" => "comma.triage-identity-projection-policy.v1",
        "target" => "provider_safe_context"
      })

    %{
      "schema" => "comma.triage-private-projection-control.v1",
      "raw_source_bundle_bytes" => raw_bundle_bytes,
      "raw_source_bundle_sha256" => CanonicalJSON.sha256(raw_bundle_bytes),
      "raw_context_sha256" => CanonicalJSON.sha256(raw_context_bytes),
      "alias_map_bytes" => alias_map_bytes,
      "alias_map_sha256" => CanonicalJSON.sha256(alias_map_bytes),
      "projection_policy_sha256" => CanonicalJSON.sha256(policy_bytes),
      "projected_context_sha256" => CanonicalJSON.sha256(projected_bytes),
      "raw_deny_literals" =>
        expected_raw_deny_literals(raw_bundle, identity_profile(raw_bundle, @origin_sha256))
    }
  end

  # One valid single-exchange chain over the same frozen page the v1 fixture
  # binds: the smallest shape that exercises every chain-only validator.
  defp chain_binding_fixture(raw_bundle) do
    {claim, transport_result, anchor} = binding_fixture(raw_bundle)
    page = raw_bundle["slack_page"]
    {:ok, chain_bytes} = CanonicalJSON.encode(%{"schema" => @chain_schema, "pages" => [page]})
    {:ok, page_bytes} = CanonicalJSON.encode(page)

    exchange =
      transport_result["receipt"]
      |> Map.put("request_selector_sha256", page_selector_sha256(raw_bundle, ""))
      |> Map.put("canonical_page_sha256", CanonicalJSON.sha256(page_bytes))

    chain_receipt =
      transport_result["receipt"]
      |> Map.put("schema", "comma.slack-read-receipt-chain.v1")
      |> Map.put("page_budget", 14)
      |> Map.put("canonical_page_chain_sha256", CanonicalJSON.sha256(chain_bytes))
      |> Map.put("rejection", nil)
      |> Map.put("exchanges", [exchange])

    chain_result =
      transport_result
      |> Map.put("schema", "comma.triage-identity-transport-result.v2")
      |> Map.put("receipt", chain_receipt)
      |> Map.put("canonical_page_chain_bytes", chain_bytes)
      |> Map.put("canonical_page_chain_sha256", CanonicalJSON.sha256(chain_bytes))

    {claim, chain_result, anchor}
  end

  defp page_selector_sha256(raw_bundle, cursor) do
    raw_bundle
    |> request_selector()
    |> Map.merge(%{"limit" => 15, "cursor" => cursor})
    |> CanonicalJSON.encode!()
    |> CanonicalJSON.sha256()
  end

  defp binding_fixture(raw_bundle) do
    origin_sha256 = @origin_sha256
    profile = identity_profile(raw_bundle, origin_sha256)
    {:ok, profile_bytes} = CanonicalJSON.encode(profile)
    {:ok, selector_bytes} = CanonicalJSON.encode(request_selector(raw_bundle))
    {:ok, source_observation_bytes} = CanonicalJSON.encode(raw_bundle["source_observation"])
    {:ok, page_bytes} = CanonicalJSON.encode(raw_bundle["slack_page"])
    page_sha256 = CanonicalJSON.sha256(page_bytes)

    classified_messages =
      Enum.map(raw_bundle["slack_page"]["messages"], fn message ->
        Map.put(message, "actor_kind", actor_kind(message, raw_bundle["connect_identity"]))
      end)

    {:ok, classified_bytes} = CanonicalJSON.encode(classified_messages)

    claim = %{
      "schema" => "comma.triage-identity-observation-claim.v1",
      "identity_profile_sha256" => CanonicalJSON.sha256(profile_bytes),
      "request_selector_sha256" => CanonicalJSON.sha256(selector_bytes),
      "slack_api_origin_sha256" => origin_sha256,
      "source_observation_sha256" => CanonicalJSON.sha256(source_observation_bytes)
    }

    receipt = %{
      "schema" => "comma.slack-read-receipt.v1",
      "operation" => "conversations.replies",
      "method" => "GET",
      "request_selector_sha256" => claim["request_selector_sha256"],
      "slack_api_origin_sha256" => origin_sha256,
      "transport_invocation_count" => 1,
      "retry" => false,
      "redirect" => false,
      "outcome" => "success",
      "typed_reason" => nil,
      "http_status" => 200,
      "canonical_page_sha256" => page_sha256,
      "message_count" => length(raw_bundle["slack_page"]["messages"]),
      "next_cursor_empty" => true,
      "slack_request_id_sha256" => nil
    }

    transport_result = %{
      "schema" => "comma.triage-identity-transport-result.v1",
      "kind" => "success",
      "receipt" => receipt,
      "canonical_page_bytes" => page_bytes,
      "canonical_page_sha256" => page_sha256,
      "classified_private_messages_sha256" => CanonicalJSON.sha256(classified_bytes),
      "reason_code" => nil
    }

    winning_source_anchor = %{
      "schema" => "comma.triage-winning-source-anchor.v1",
      "generation" => SalixStore.ULID.generate(),
      "source_mode" => "historical_thread_reenactment",
      "sealed_events" => raw_bundle["sealed_events"],
      "source_authority" => raw_bundle["source_authority"]
    }

    {claim, transport_result, winning_source_anchor}
  end

  defp identity_profile(raw_bundle, origin_sha256) do
    connect = raw_bundle["connect_identity"]
    product = raw_bundle["product_identity"]
    {:ok, endpoint_revision} = IdentityContract.endpoint_revision_sha256(connect)

    %{
      "schema" => "comma.triage-identity-selector.v1",
      "provider" => connect["provider"],
      "operation" => "conversations.replies",
      "tenant_id" => connect["tenant_id"],
      "group_id" => connect["group_id"],
      "connect_id" => connect["connect_id"],
      "connect_generation" => connect["connect_generation"],
      "workspace_id" => connect["workspace_id"],
      "approved_channel_id" => connect["approved_channel_id"],
      "root_ts" => raw_bundle["root_ts"],
      "inbound_agent_id" => connect["inbound_agent_id"],
      "app_id" => connect["app_id"],
      "bot_user_id" => connect["bot_user_id"],
      "bot_id" => connect["bot_id"],
      "endpoint_revision_sha256" => endpoint_revision,
      "project_id" => product["project_id"],
      "project_status" => product["project_status"],
      "agent_id" => product["salix_agent_id"],
      "agent_role" => product["agent_role"],
      "agent_name" => product["agent_name"],
      "self_agent_identity_revision_sha256" =>
        get_in(raw_bundle, ["raw_identity_context", "self_agent", "identity_revision_sha256"]),
      "slack_api_origin_sha256" => origin_sha256
    }
  end

  defp identity_profile_v2(raw_bundle, origin_sha256) do
    raw_bundle
    |> identity_profile(origin_sha256)
    |> Map.put("schema", "comma.triage-identity-selector.v2")
    |> Map.put("operation", "clickhouse.thread_current")
    |> Map.delete("slack_api_origin_sha256")
    |> Map.put("source_origin_sha256", origin_sha256)
  end

  defp clickhouse_binding_fixture(raw_bundle, source_origin_sha256, profile) do
    {:ok, profile_bytes} = CanonicalJSON.encode(profile)
    {:ok, selector_bytes} = CanonicalJSON.encode(clickhouse_request_selector(raw_bundle))
    {:ok, observation_bytes} = CanonicalJSON.encode(raw_bundle["source_observation"])
    {:ok, snapshot_bytes} = CanonicalJSON.encode(raw_bundle["source_snapshot"])
    {:ok, classified_bytes} = CanonicalJSON.encode(raw_bundle["source_snapshot"]["messages"])
    snapshot_sha256 = CanonicalJSON.sha256(snapshot_bytes)

    claim = %{
      "schema" => "comma.triage-source-observation-claim.v2",
      "identity_profile_sha256" => CanonicalJSON.sha256(profile_bytes),
      "request_selector_sha256" => CanonicalJSON.sha256(selector_bytes),
      "source_origin_sha256" => source_origin_sha256,
      "source_observation_sha256" => CanonicalJSON.sha256(observation_bytes)
    }

    receipt = %{
      "schema" => "comma.clickhouse-thread-read-receipt.v1",
      "operation" => "clickhouse.thread_current",
      "request_selector_sha256" => claim["request_selector_sha256"],
      "source_origin_sha256" => source_origin_sha256,
      "outcome" => "success",
      "typed_reason" => nil,
      "canonical_snapshot_sha256" => snapshot_sha256,
      "message_count" => 1,
      "reaction_count" => 1,
      "complete" => true
    }

    result = %{
      "schema" => "comma.triage-source-read-result.v1",
      "kind" => "success",
      "receipt" => receipt,
      "canonical_snapshot_bytes" => snapshot_bytes,
      "canonical_snapshot_sha256" => snapshot_sha256,
      "classified_private_messages_sha256" => CanonicalJSON.sha256(classified_bytes),
      "reason_code" => nil
    }

    anchor = %{
      "schema" => "comma.triage-winning-source-anchor.v1",
      "generation" => SalixStore.ULID.generate(),
      "source_mode" => "clickhouse_etl",
      "sealed_events" => raw_bundle["sealed_events"],
      "source_authority" => raw_bundle["source_authority"]
    }

    {claim, result, anchor}
  end

  defp clickhouse_request_selector(raw_bundle) do
    %{
      "operation" => "clickhouse.thread_current",
      "tenant_id" => raw_bundle["connect_identity"]["tenant_id"],
      "workspace_id" => raw_bundle["connect_identity"]["workspace_id"],
      "channel_id" => raw_bundle["source_authority"]["channel_id"],
      "thread_ts" => raw_bundle["source_authority"]["thread_ts"],
      "limit" => 200,
      "max_bytes" => 1_048_576
    }
  end

  defp request_selector(raw_bundle) do
    %{
      "operation" => "conversations.replies",
      "channel_id" => raw_bundle["source_authority"]["channel_id"],
      "thread_ts" => raw_bundle["source_authority"]["thread_ts"],
      "limit" => 200,
      "cursor" => ""
    }
  end

  defp expected_raw_deny_literals(raw_bundle, identity_profile) do
    [raw_bundle, identity_profile]
    |> collect_private_literals(false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp collect_private_literals(value, sensitive?) when is_map(value) do
    Enum.flat_map(value, fn {key, child} ->
      collect_private_literals(child, sensitive? or private_literal_key?(key))
    end)
  end

  defp collect_private_literals(value, sensitive?) when is_list(value),
    do: Enum.flat_map(value, &collect_private_literals(&1, sensitive?))

  defp collect_private_literals(value, sensitive?) when is_binary(value) do
    if(sensitive?, do: [value], else: []) ++ private_literal_fragments(value)
  end

  defp collect_private_literals(_value, _sensitive?), do: []

  defp private_literal_key?(key) when is_binary(key) do
    key in ~w(key user module checked_at connect_generation) or
      Regex.match?(~r/(?:^|_)(?:id|ids|ref|refs|sha256|ts|timestamps)\z/, key)
  end

  defp private_literal_key?(_key), do: true

  defp private_literal_fragments(value) do
    regexes = [
      @raw_provider_id,
      @raw_uuid,
      @raw_uri,
      @raw_email,
      @raw_path,
      @raw_mention,
      @sha256
    ]

    (regexes ++ @credential_literal_patterns)
    |> Enum.flat_map(fn regex ->
      regex
      |> Regex.scan(value, capture: :first)
      |> Enum.map(&hd/1)
    end)
  end

  defp actor_kind(message, connect) do
    cond do
      present?(message["bot_id"]) or present?(message["app_id"]) or
        present?(message["bot_profile_name"]) or
          (present?(message["user"]) and message["user"] == connect["bot_user_id"]) ->
        "agent"

      present?(message["subtype"]) ->
        "system"

      present?(message["user"]) ->
        "human"

      true ->
        "unknown"
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp ordinal(index), do: index |> Integer.to_string() |> String.pad_leading(3, "0")
end
