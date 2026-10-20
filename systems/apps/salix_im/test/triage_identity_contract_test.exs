defmodule SalixIM.TriageIdentityContractTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  import SalixIM.TriageEngineFixtures

  alias SalixIM.Triage
  alias SalixIM.Triage.{CanonicalJSON, IdentityContract, Runtime}
  alias SalixStore.{CasRecord, ULID}

  defmodule ForbiddenContext do
    @moduledoc false
    def freeze(_input, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), :identity_context_called)
      {:error, :must_not_run}
    end
  end

  defmodule ForbiddenEvaluator do
    @moduledoc false
    @behaviour SalixIM.Ports.TriageEvaluator

    @impl true
    def evaluate(_input, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), :identity_evaluator_called)
      {:error, :must_not_run}
    end
  end

  defmodule SourceModeContext do
    @moduledoc false
    def freeze(input, opts) do
      SystemsRuntime.Proc.send(Keyword.fetch!(opts, :test_pid), {:identity_context_input, input})

      identity_context =
        opts
        |> Keyword.fetch!(:identity_context)
        |> Map.put("source_mode", input["source_mode"])

      {:ok,
       %{
         "slack_context" => %{"messages" => [], "source_refs" => []},
         "team_project_memory" => %{"source_refs" => []},
         "answered_recheck" => %{
           "answered" => false,
           "checked_at" => "2026-08-14T12:00:00Z",
           "source_refs" => []
         },
         "identity_context" => identity_context
       }}
    end
  end

  defmodule SourceModeEvaluator do
    @moduledoc false
    @behaviour SalixIM.Ports.TriageEvaluator

    @impl true
    def evaluate(model_input, opts) do
      SystemsRuntime.Proc.send(
        Keyword.fetch!(opts, :test_pid),
        {:identity_evaluator_input, model_input}
      )

      {:error, :must_not_run}
    end
  end

  # The receipt-persistence cases from the source branch describe that branch's
  # `ProviderReceipts.record_slack_triage/2,3`, which main replaced with the
  # strict verified-root writer covered by `slack_triage_receipt_test.exs`, so
  # they do not port. Deliberately not ported:
  #   "new callback receipts retain outer v1 and freeze exact endpoint provenance"
  #   "only provenanced receipts freeze one closed source mode"
  #   "callback app mismatch fails before receipt persistence"
  #   "legacy incomplete connect fixture remains mechanically readable despite callback app id"
  #   "provenanced duplicate drift fails but a legacy receipt is never rewritten"
  #   "duplicate recovery preserves a sanctioned blank-to-known bot identity receipt"

  test "endpoint revision accepts an explicitly blank backfill bot user id only" do
    endpoint = endpoint_identity("U_BFT")

    assert {:ok, _revision} =
             endpoint
             |> Map.put("bot_user_id", "")
             |> IdentityContract.endpoint_revision_sha256()

    assert {:ok, _same_revision} =
             endpoint
             |> Map.put("bot_id", "")
             |> IdentityContract.endpoint_revision_sha256()
  end

  test "authorized tool text retains identities and refs but withholds credentials" do
    original =
      "mail ops@example.test about link://run/l001 and " <>
        "id 123e4567-e89b-12d3-a456-426614174000 at /var/secrets/key for <@U0123ABCD>"

    assert IdentityContract.redact_untrusted_text(original) == original

    for secret <- [
          "Bearer fixture-secret",
          "Bearer QUJDREVGRw",
          "Bearer YWJjZGVmZw==",
          "Bearer mF_9.B5f-4.1JqM",
          "Bearer abc123",
          "Bearer Token，且仅公开只读工具",
          "access_token=fixture-secret",
          "xoxb-fixture-secret",
          "https://user:fixture-password@example.test/file",
          "https://example.test/file?X-Amz-Signature=fixture-signature",
          "https://example.test/file?X-Goog-Signature=fixture-signature",
          "https://example.test/file?%74oken=fixture-token",
          "https://example.test/file#refresh_token=fixture-token",
          "https://example.test/file?pub_secret=fixture-secret"
        ] do
      result = IdentityContract.redact_untrusted_text(original <> " " <> secret)
      refute result =~ secret
      assert result == "[Credential-bearing source text withheld]"
    end

    ordinary = "https://example.test/file?project=123&view=token#section"
    assert IdentityContract.redact_untrusted_text(ordinary) == ordinary

    assert IdentityContract.withhold_bearer_credentials("先看 Bearer QUJDREVGRw 再说") ==
             "先看 [Bearer-credential withheld] 再说"

    withheld = IdentityContract.withhold_bearer_credentials("Authorization: Bearer abc123")
    assert IdentityContract.redact_untrusted_text(withheld) != withheld

    for co_located <- [
          "Bearer xoxb-catalogue-canary123",
          "Bearer Token and xoxb-catalogue-canary123",
          "Bearer -----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg\n-----END PRIVATE KEY-----"
        ] do
      assert IdentityContract.withhold_bearer_credentials(co_located) == co_located
      assert IdentityContract.redact_untrusted_text(co_located) != co_located
    end
  end

  defp endpoint_identity(bot_user_id) do
    %{
      "provider" => "slack",
      "tenant_id" => "tenant-atlas",
      "group_id" => "project-atlas",
      "connect_id" => "connect-atlas",
      "connect_generation" => "generation-7",
      "workspace_id" => "T_ATLAS",
      "inbound_agent_id" => "agt1_atlas_router",
      "app_id" => "A_BFT",
      "bot_user_id" => bot_user_id,
      "bot_id" => "B_BFT"
    }
  end

  defp identity_context do
    identity = %{
      "source_ref" => "bft://projects/project-atlas/agents/agent-router",
      "principal_ref" => "comma-agent://agt1_atlas_router",
      "agent_id" => "agt1_atlas_router",
      "role" => "router",
      "display_name" => "BFT",
      "persona_revision_sha256" => String.duplicate("a", 64)
    }

    {:ok, identity_revision} = IdentityContract.identity_revision_sha256(identity)

    %{
      "schema" => "comma.triage-identity-context.v1",
      "source_mode" => "callback",
      "self_agent" => Map.put(identity, "identity_revision_sha256", identity_revision),
      "self_endpoint" => %{
        "source_ref" => "slack-endpoint://T_ATLAS/connect-atlas@generation-7",
        "provider" => "slack",
        "workspace_id" => "T_ATLAS",
        "connect_id" => "connect-atlas",
        "connect_generation" => "generation-7",
        "provider_app_id" => "A_BFT",
        "bot_user_id" => "U_BFT",
        "bot_id" => "B_BFT",
        "display_aliases" => ["BFT"],
        "represents_principal_ref" => "comma-agent://agt1_atlas_router",
        "revision_sha256" => String.duplicate("b", 64),
        "revision_status" => "exact"
      },
      "observed_principals" => [],
      "mention_evidence" => [],
      "principal_refs" => ["comma-agent://agt1_atlas_router"],
      "remember_forbidden_source_refs" => [
        "bft://projects/project-atlas/agents/agent-router",
        "comma-agent://agt1_atlas_router",
        "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
      ],
      "source_refs" => [
        "bft://projects/project-atlas/agents/agent-router",
        "slack-endpoint://T_ATLAS/connect-atlas@generation-7"
      ]
    }
  end
end
