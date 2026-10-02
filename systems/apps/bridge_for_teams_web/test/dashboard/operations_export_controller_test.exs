defmodule BridgeForTeamsWeb.Dashboard.OperationsExportControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{Memberships, Observability}

  setup :register_and_log_in_user

  test "exports filtered audit logs to an owner as redacted CSV and audits the export",
       %{conn: conn, org: org, user: user} do
    {:ok, exported} =
      Observability.record_audit(%{
        org_id: org.id,
        actor_user_id: user.id,
        actor_label: "private-admin@example.com",
        action: "settings.sso.updated",
        resource_type: "sso",
        resource_id: org.id,
        resource_label: "=IMPORTDATA(secret)",
        result: "ok",
        request_id: "req_export_sso",
        metadata: %{"submitted_secret" => "sk-export-secret"}
      })

    {:ok, _other} =
      Observability.record_audit(%{
        org_id: org.id,
        actor_user_id: user.id,
        action: "settings.model.updated",
        resource_type: "model_settings",
        resource_id: org.id,
        result: "ok"
      })

    conn =
      get(conn, ~p"/orgs/#{org.slug}/operations/audit.csv", %{"action" => "settings.sso.updated"})

    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/csv"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(filename="bft-audit-#{org.slug}.csv")

    csv = response(conn, 200)
    assert csv =~ exported.id
    assert csv =~ "req_export_sso"
    assert csv =~ "'=IMPORTDATA(secret)"
    refute csv =~ "settings.model.updated"
    refute csv =~ "private-admin@example.com"
    refute csv =~ "sk-export-secret"

    assert [%{actor_user_id: actor_id, result: "ok"}] =
             Observability.list_audit_logs(org.id, action: "audit_log.exported")

    assert actor_id == user.id
  end

  test "refuses the export to an ordinary member", %{conn: conn, org: org} do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")

    conn = conn |> log_in_user(member) |> get(~p"/orgs/#{org.slug}/operations/audit.csv")

    assert response(conn, 403) == "forbidden"
  end
end
