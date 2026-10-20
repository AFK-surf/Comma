defmodule BridgeForTeams.Observability.AdapterDiagnosticTest do
  use SystemsClock.Case, async: true

  alias BridgeForTeams.Observability.AdapterDiagnostic

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
end
