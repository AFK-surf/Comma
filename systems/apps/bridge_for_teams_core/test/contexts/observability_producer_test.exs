defmodule BridgeForTeams.Observability.ProducerTest do
  use ExUnit.Case, async: true

  import BridgeForTeams.ObservabilityCase

  alias BridgeForTeams.Observability.Producer
  alias BridgeForTeams.Observability.{SalixIMSink, SalixScheduleSink}

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

  test "asserts expected producer contract keys from shared test helper" do
    assert_observability_contract!(ExampleProducer, %{
      producer: :example_feature,
      records: [:event, :audit_log]
    })
  end

  test "validates the shipped runtime sink producer contracts" do
    assert_observability_contract!(SalixIMSink, %{
      producer: :salix_im_diagnostics,
      records: [:event],
      sources: ["salix.im"]
    })

    assert_observability_contract!(SalixScheduleSink, %{
      producer: :salix_schedule_diagnostics,
      records: [:event],
      sources: ["salix.schedule"]
    })
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
