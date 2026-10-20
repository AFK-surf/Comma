defmodule BridgeForTeams.Observability.ProducerTest do
  use SystemsClock.Case, async: true

  alias BridgeForTeams.Observability.Producer

  defmodule ExampleProducer do
    use Producer,
      producer: :example_feature,
      records: [:event, :audit_log],
      domains: ["project"],
      sources: ["bft.dashboard"],
      resource_types: ["project"],
      evidence_allowlist: ["request_id", "status"],
      permissions: :org_admin
  end

  defmodule MissingContractProducer do
  end

  defmodule InvalidRecordProducer do
    def observability_contract do
      %{
        producer: :invalid_record,
        records: [:unknown],
        domains: ["project"],
        sources: ["bft.dashboard"],
        resource_types: ["project"],
        evidence_allowlist: ["request_id"],
        permissions: :org_admin,
        redaction: :required
      }
    end
  end

  test "validates a producer contract declared with the shared macro" do
    assert %{
             producer: :example_feature,
             records: [:event, :audit_log],
             domains: ["project"],
             sources: ["bft.dashboard"],
             resource_types: ["project"],
             evidence_allowlist: ["request_id", "status"],
             permissions: :org_admin,
             redaction: :required
           } = Producer.validate_contract!(ExampleProducer)
  end

  test "rejects modules without a declared producer contract" do
    assert_raise ArgumentError, ~r/does not define observability_contract\/0/, fn ->
      Producer.validate_contract!(MissingContractProducer)
    end
  end

  test "rejects unknown shared record types" do
    assert_raise ArgumentError, ~r/unknown records: \[:unknown\]/, fn ->
      Producer.validate_contract!(InvalidRecordProducer)
    end
  end
end
