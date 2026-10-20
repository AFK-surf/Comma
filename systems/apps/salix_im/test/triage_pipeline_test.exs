defmodule SalixIM.Triage.PipelineTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Triage.{IdentityFenceHandle, Pipeline}

  defmodule CompatibilityEvaluator do
    def evaluate(input, opts) do
      SystemsRuntime.Proc.send(opts[:test_pid], {:compatibility_evaluated, input})
      {:ok, %{"action" => "silence"}, %{"evaluator" => "compatibility-stub"}}
    end
  end

  test "identity run rejects a non-capability authority before invoking ports" do
    input = %{
      "schema" => "comma.triage-input-snapshot.v2",
      "source_mode" => "callback",
      "events" => []
    }

    assert {:error, :identity_projection_invalid} =
             Pipeline.run_identity(input, nil, nil, :none, :caller_authority)
  end

  test "provider rejection settles as transport indeterminate without private error details" do
    terminal =
      Pipeline.terminal_from_result(
        {:error, {:provider_error, %{status: 502, body: "PRIVATE_PROVIDER_BODY"}}},
        :identity,
        123
      )

    assert terminal["status"] == "failed"
    assert terminal["decision"]["reason"] == "identity_diagnostic_indeterminate_transport"
    assert terminal["evaluator"] == %{}
    refute inspect(terminal) =~ "PRIVATE_PROVIDER_BODY"

    assert SalixIM.Triage.RunFence.valid_terminal?(
             Map.put(terminal, "terminal_id", SalixStore.ULID.generate())
           )
  end
end
