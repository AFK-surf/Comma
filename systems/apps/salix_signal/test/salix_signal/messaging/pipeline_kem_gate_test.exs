defmodule SalixSignal.Messaging.PipelineKemGateTest do
  # Owner KEM decision: an account's pipeline decapsulates pre-key messages,
  # so it does not start on a node without constant-time KEM support. Not
  # async: it changes the application environment that other tests rely on.
  use ExUnit.Case, async: false

  alias SalixSignal.Messaging.Pipeline
  alias SalixSignalProto.KemBackend

  @tag skip: KemBackend.constant_time?() && "this node has constant-time KEM support"
  test "the pipeline refuses to start without constant-time KEM support" do
    Application.put_env(:salix_signal_proto, :plain_kem_in_tests, false)
    on_exit(fn -> Application.put_env(:salix_signal_proto, :plain_kem_in_tests, true) end)

    assert Pipeline.new(account: %{}, store: nil, epoch: 1, transport: %{}) ==
             {:error, :kem_unsupported}
  end
end
