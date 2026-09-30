defmodule AlertRouter.GitHubHMACTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias AlertRouter.Web.GitHubHMAC

  @secret "alert-router-github-webhook-test-secret"
  @body ~s({"action":"completed"})

  test "accepts the GitHub raw-body signature and required event headers" do
    assert {:ok, "workflow_run"} = GitHubHMAC.verify(signed_conn(@body), @body)
    assert {:ok, "ping"} = GitHubHMAC.verify(signed_conn(@body, "ping"), @body)
  end

  test "rejects body tampering, wrong event type, and missing delivery identity" do
    assert {:error, :invalid_signature} =
             GitHubHMAC.verify(signed_conn(@body), @body <> " ")

    wrong_event =
      signed_conn(@body)
      |> delete_req_header("x-github-event")
      |> put_req_header("x-github-event", "push")

    assert {:error, :invalid_github_event} = GitHubHMAC.verify(wrong_event, @body)

    missing_delivery = signed_conn(@body) |> delete_req_header("x-github-delivery")
    assert {:error, :missing_signature_header} = GitHubHMAC.verify(missing_delivery, @body)
  end

  defp signed_conn(body, event \\ "workflow_run") do
    signature =
      :crypto.mac(:hmac, :sha256, @secret, body)
      |> Base.encode16(case: :lower)

    conn(:post, "/v1/events/github", body)
    |> put_req_header("x-hub-signature-256", "sha256=" <> signature)
    |> put_req_header("x-github-event", event)
    |> put_req_header("x-github-delivery", "72d3162e-cc78-11e3-81ab-4c9367dc0958")
  end
end
