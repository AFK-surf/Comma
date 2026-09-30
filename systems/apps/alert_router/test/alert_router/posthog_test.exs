defmodule AlertRouter.PostHogTest do
  use AlertRouter.DataCase, async: false
  import Plug.Conn
  import Plug.Test
  alias AlertRouter.Adapters.PostHog
  alias AlertRouter.Data.{EventRecord, Incident}

  @secret "alert-router-posthog-webhook-test-secret"
  @issue_id "019a9b08-3333-7777-8888-222222222222"

  setup do
    previous = Application.fetch_env!(:alert_router, :posthog_webhook)
    on_exit(fn -> Application.put_env(:alert_router, :posthog_webhook, previous) end)
    :ok
  end

  test "authenticated critical issue reaches the durable lifecycle and Slack renderer once" do
    assert %{status: 202, resp_body: body} = post(payload())
    assert Jason.decode!(body) == %{"disposition" => "accepted"}
    assert %{status: 202, resp_body: body} = post(payload())
    assert Jason.decode!(body) == %{"disposition" => "duplicate"}
    assert [incident] = Repo.all(Incident)
    assert [record] = Repo.all(EventRecord)
    assert incident.state == "firing"
    assert incident.priority == "P2"
    assert incident.environment == "staging"
    assert incident.recovery_status == "not_applicable"
    rendered = AlertRouter.Slack.Renderer.root(incident, 1, lifecycle_events: [record])
    text = Jason.encode!(rendered)
    assert text =~ "PostHog"
    assert text =~ "/error_tracking/#{@issue_id}"
    assert text =~ "issue_created"
    refute text =~ "<!channel>"
    refute text =~ "private"
    refute Jason.encode!(record.canonical_payload) =~ "private"
  end

  test "server owns project, environment, priority and copy" do
    assert %{status: 422} = post(Map.put(payload(), "project_id", "999"))
    {:ok, event} = PostHog.normalize(payload())
    assert event.priority == "P2"
    assert event.environment == "staging"
    assert event.source_account == "https://us.posthog.com/project/123"
    refute event.summary =~ "private"

    assert event.links["incident"] ==
             "https://us.posthog.com/project/123/error_tracking/#{@issue_id}"
  end

  test "login unavailable creates one P1 incident through the existing destination" do
    login = Map.put(payload(), "error_kind", "login_unavailable")
    assert %{status: 202} = post(login)
    assert %{status: 202, resp_body: body} = post(login)
    assert Jason.decode!(body) == %{"disposition" => "duplicate"}
    assert [incident] = Repo.all(Incident)
    assert incident.priority == "P1"
    assert incident.summary == "Comma Google 登录失败"
    assert [record] = Repo.all(EventRecord)
    rendered = AlertRouter.Slack.Renderer.root(incident, 1, lifecycle_events: [record])
    assert Jason.encode!(rendered) =~ "P1"
    refute Jason.encode!(record.canonical_payload) =~ "private"
  end

  test "missing, wrong and duplicate credentials fail before ingestion; absent configuration fails closed" do
    for auth <- [nil, "Bearer wrong"] do
      assert %{status: 401} = post(payload(), auth)
    end

    conn = conn(:post, "/v1/events/posthog", Jason.encode!(payload()))

    conn = %{
      conn
      | req_headers: [
          {"authorization", "Bearer " <> @secret},
          {"authorization", "Bearer " <> @secret}
        ]
    }

    assert %{status: 401} = AlertRouter.Web.Router.call(conn, [])
    Application.delete_env(:alert_router, :posthog_webhook)
    assert %{status: 503} = post(payload())
    assert Repo.all(Incident) == []
  end

  test "ordinary errors are ignored and close or silence cannot manufacture recovery" do
    assert %{status: 202, resp_body: body} = post(Map.put(payload(), "severity", "error"))
    assert Jason.decode!(body) == %{"disposition" => "ignored"}
    assert %{status: 202} = post(Map.put(payload(), "error_kind", "unhandled_error"))

    for action <- ["issue_resolved", "issue_suppressed", "issue_updated"] do
      assert %{status: 422} = post(Map.put(payload(), "event", action))
    end

    assert Repo.all(EventRecord) == []
  end

  test "reopening at a new source occurrence creates a distinct firing generation" do
    assert %{status: 202} = post(payload())

    reopened =
      payload()
      |> Map.put("event", "issue_reopened")
      |> Map.put("occurred_at", "2026-09-04T03:00:00Z")

    assert %{status: 202} = post(reopened)
    assert %{status: 202} = post(reopened)
    assert length(Repo.all(Incident)) == 2
    assert length(Repo.all(EventRecord)) == 2
  end

  test "malformed identifiers, schema, JSON and oversized input do not create incidents" do
    for {key, value} <- [
          {"issue_id", "private<script>"},
          {"occurred_at", "invalid"},
          {"schema_version", 2}
        ] do
      assert %{status: 422} = post(Map.put(payload(), key, value))
    end

    assert %{status: 400} = request("[")
    assert %{status: 422} = request(String.duplicate("x", 1_048_577))
    assert Repo.all(Incident) == []
  end

  defp payload do
    %{
      "schema_version" => 1,
      "project_id" => "123",
      "issue_id" => @issue_id,
      "event" => "issue_created",
      "occurred_at" => "2026-09-04T02:00:00Z",
      "severity" => "critical",
      "error_kind" => "react_uncaught",
      "environment" => "production",
      "priority" => "P0",
      "summary" => "private <!channel>",
      "url" => "https://private.test",
      "exception" => "private token"
    }
  end

  defp post(payload, auth \\ "Bearer " <> @secret), do: request(Jason.encode!(payload), auth)

  defp request(body, auth \\ "Bearer " <> @secret) do
    conn =
      conn(:post, "/v1/events/posthog", body)
      |> put_req_header("content-type", "application/json")

    conn = if auth, do: put_req_header(conn, "authorization", auth), else: conn
    AlertRouter.Web.Router.call(conn, [])
  end
end
