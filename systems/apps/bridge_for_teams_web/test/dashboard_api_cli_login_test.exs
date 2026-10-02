defmodule BridgeForTeamsWeb.DashboardAPICLILoginTest do
  @moduledoc """
  The BFT CLI device-login approval page (`/cli/device-login`) and its API:
  the page and its login redirect, the owner/admin rule with its redirect and
  flash, reading a request by code, approving it for chosen organizations,
  denying it, refusing finished or expired requests, CSRF protection, and a
  query count that does not grow with the approver's organizations.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.{CLI.Login, Memberships, Repo}
  alias BridgeForTeams.Schema.CliDeviceAuthorization

  setup :register_and_log_in_user

  setup do
    {:ok, %{device_code: device_code, authorization: authorization}} =
      Login.start_device_authorization(%{client_name: "agent laptop"})

    %{device_code: device_code, code: authorization.user_code}
  end

  describe "the page" do
    test "serves the React app with and without a code, before onboarding too", %{code: code} do
      %{user: owner} = org_with_owner_fixture()
      conn = log_in_user(build_conn(), owner, onboarded: false)

      for path <- [~p"/cli/device-login", ~p"/cli/device-login/#{code}"] do
        assert conn |> get(path) |> html_response(200) =~ ~s(<div id="root"></div>)
      end
    end

    test "sends a logged-out visitor through login and back to the code", %{code: code} do
      conn = build_conn() |> init_test_session(%{}) |> get(~p"/cli/device-login/#{code}")
      location = redirected_to(conn)

      assert location =~ "/login?"

      assert %{"return_to" => return_to} =
               location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert return_to == "/cli/device-login/#{code}"
    end

    test "sends a member who manages no organization to /orgs with an error",
         %{org: org, code: code} do
      conn = build_conn() |> log_in_user(add_member(org)) |> get(~p"/cli/device-login/#{code}")
      assert redirected_to(conn) == "/orgs"

      html = conn |> recycle() |> get("/orgs") |> html_response(200)

      assert html =~
               ~s(<meta name="bft-flash" data-kind="error" content="You do not have permission to approve CLI login requests." />)
    end
  end

  describe "GET /dashboard/api/v1/cli/device-login/:code" do
    test "shows the request and the organizations the approver manages",
         %{conn: conn, org: org, code: code} do
      data = conn |> get(login_path(code)) |> json_response(200) |> data()

      assert %{
               "user_code" => ^code,
               "status" => "pending",
               "client_name" => "agent laptop",
               "granted_orgs" => []
             } = data["request"]

      assert data["request"]["created_at"]
      assert data["request"]["expires_at"]
      assert data["orgs"] == [%{"id" => org.id, "slug" => org.slug, "name" => org.name}]
    end

    test "normalizes the typed code and answers an unknown one without a request",
         %{conn: conn, code: code} do
      typed = code |> String.downcase() |> String.split_at(4) |> Tuple.to_list() |> Enum.join("-")

      assert %{"request" => %{"user_code" => ^code}} =
               conn |> get(login_path(typed)) |> json_response(200) |> data()

      assert %{"request" => nil, "orgs" => [_]} =
               conn |> get(login_path("NOPE0000")) |> json_response(200) |> data()
    end

    test "costs the same queries however many organizations the approver manages",
         %{conn: conn, user: user, code: code} do
      small = query_count(conn, login_path(code))

      for _ <- 1..3 do
        {:ok, _} = Memberships.put_org_member(org_fixture().id, user.id, "admin")
      end

      assert query_count(conn, login_path(code)) == small
    end
  end

  describe "approve and deny" do
    test "approve grants only the chosen organizations and the CLI receives them",
         %{conn: conn, org: org, user: user, code: code, device_code: device_code} do
      other = org_fixture()
      {:ok, _} = Memberships.put_org_member(other.id, user.id, "owner")

      data =
        conn
        |> post(login_path(code, "approve"), %{"org_ids" => [org.id]})
        |> json_response(200)
        |> data()

      assert data["request"]["status"] == "approved"

      assert data["request"]["granted_orgs"] == [
               %{"id" => org.id, "slug" => org.slug, "name" => org.name}
             ]

      assert {:ok, %{status: "approved", granted_orgs: [granted]}} =
               Login.poll_device_authorization(device_code)

      assert granted.id == org.id
    end

    test "approve needs at least one organization", %{conn: conn, code: code} do
      for body <- [%{}, %{"org_ids" => []}, %{"org_ids" => [%{}]}] do
        assert %{
                 "error" => %{
                   "code" => "missing_org_grants",
                   "message" => "Select at least one organization."
                 }
               } =
                 conn
                 |> put_req_header("content-type", "application/json")
                 |> post(login_path(code, "approve"), Jason.encode!(body))
                 |> json_response(422)
      end

      assert {:ok, %{status: "pending"}} = Login.get_device_authorization(code)
    end

    test "deny cancels the request and the CLI gets no session",
         %{conn: conn, code: code, device_code: device_code} do
      assert %{"request" => %{"status" => "cancelled"}} =
               conn |> post(login_path(code, "deny")) |> json_response(200) |> data()

      assert {:ok, %{status: "cancelled"} = poll} = Login.poll_device_authorization(device_code)
      refute Map.has_key?(poll, :token)
    end

    test "a finished or expired request is refused with its reason", %{
      conn: conn,
      org: org,
      code: code
    } do
      conn |> post(login_path(code, "deny")) |> json_response(200)

      assert %{
               "error" => %{
                 "code" => "cli_login_cancelled",
                 "message" => "This CLI login was already cancelled."
               }
             } =
               conn
               |> post(login_path(code, "approve"), %{"org_ids" => [org.id]})
               |> json_response(409)

      {:ok, %{authorization: expiring}} = Login.start_device_authorization(%{})

      expiring
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60))
      |> Repo.update!()

      assert %{
               "error" => %{
                 "code" => "cli_login_expired",
                 "message" => "This CLI login has expired."
               }
             } =
               conn
               |> post(login_path(expiring.user_code, "approve"), %{"org_ids" => [org.id]})
               |> json_response(409)

      assert %{"request" => %{"status" => "expired"}} =
               conn |> get(login_path(expiring.user_code)) |> json_response(200) |> data()

      assert %{"error" => %{"code" => "cli_login_not_found"}} =
               conn |> post(login_path("NOPE0000", "deny")) |> json_response(404)
    end

    test "members who manage no organization cannot read, approve or deny",
         %{org: org, code: code, device_code: device_code} do
      conn = log_in_user(build_conn(), add_member(org))

      assert %{"error" => %{"code" => "forbidden"}} =
               conn |> get(login_path(code)) |> json_response(403)

      assert %{"error" => %{"code" => "forbidden"}} =
               conn
               |> post(login_path(code, "approve"), %{"org_ids" => [org.id]})
               |> json_response(403)

      assert %{"error" => %{"code" => "forbidden"}} =
               conn |> post(login_path(code, "deny")) |> json_response(403)

      assert {:ok, %{status: "pending"}} = Login.poll_device_authorization(device_code)
    end

    test "writes need the page's CSRF token", %{conn: conn, org: org, code: code} do
      conn = get(conn, ~p"/cli/device-login/#{code}")

      [_, token] =
        Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, html_response(conn, 200))

      conn = conn |> recycle() |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent(403, fn ->
        post(conn, login_path(code, "approve"), %{"org_ids" => [org.id]})
      end)

      assert Repo.get_by!(CliDeviceAuthorization, user_code: code).status == "pending"

      assert %{"ok" => true} =
               conn
               |> put_req_header("x-csrf-token", token)
               |> post(login_path(code, "approve"), %{"org_ids" => [org.id]})
               |> json_response(200)
    end
  end

  defp login_path(code), do: "/dashboard/api/v1/cli/device-login/#{code}"
  defp login_path(code, action), do: "/dashboard/api/v1/cli/device-login/#{code}/#{action}"
  defp data(%{"data" => data}), do: data

  defp add_member(org) do
    member = user_fixture()
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    member
  end

  defp query_count(conn, path) do
    test_pid = self()
    handler = "cli-login-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:bridge_for_teams, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      conn |> get(path) |> json_response(200)
      count_messages(0)
    after
      :telemetry.detach(handler)
    end
  end

  defp count_messages(count) do
    receive do
      :repo_query -> count_messages(count + 1)
    after
      0 -> count
    end
  end
end
