defmodule BridgeForTeams.Observability.AdapterDiagnosticTest do
  use ExUnit.Case, async: true

  alias BridgeForTeams.Observability.AdapterDiagnostic

  test "value reads atom and string keys without dropping false values" do
    diagnostic = %{
      "request_id" => "req-1",
      session_id_configured: false
    }

    assert AdapterDiagnostic.value(diagnostic, :request_id) == "req-1"
    assert AdapterDiagnostic.value(diagnostic, :session_id_configured) == false
  end

  test "take_evidence keeps only allowlisted nonblank diagnostic keys" do
    diagnostic = %{
      :provider => "feishu",
      "request_id" => "req-1",
      :session_id_configured => false,
      :empty => "",
      :message_body => "private message",
      :token => "private token"
    }

    assert AdapterDiagnostic.take_evidence(diagnostic, [
             :provider,
             :request_id,
             :session_id_configured,
             :empty
           ]) == %{
             "provider" => "feishu",
             "request_id" => "req-1",
             "session_id_configured" => false
           }
  end

  test "first_value skips blanks and normalizes atoms" do
    diagnostic = %{
      correlation_id: "",
      request_id: :req_atom
    }

    assert AdapterDiagnostic.first_value(diagnostic, [:correlation_id, :request_id]) ==
             "req_atom"
  end

  test "correlation_id uses common adapter keys before fallback" do
    assert AdapterDiagnostic.correlation_id(%{request_id: "req-1"}, "fallback") == "req-1"

    assert AdapterDiagnostic.correlation_id(%{client_request_id: "client-1"}, "fallback") ==
             "client-1"

    assert AdapterDiagnostic.correlation_id(%{invocation_id: "inv-1"}, "fallback") == "inv-1"
    assert AdapterDiagnostic.correlation_id(%{correlation_id: "corr-1"}, "fallback") == "corr-1"
    assert AdapterDiagnostic.correlation_id(%{}, "fallback") == "fallback"
  end

  test "blank_to_nil preserves nil and boolean values" do
    assert AdapterDiagnostic.blank_to_nil(nil) == nil
    assert AdapterDiagnostic.blank_to_nil(false) == false
    assert AdapterDiagnostic.blank_to_nil(:missing_scope) == "missing_scope"
  end
end
