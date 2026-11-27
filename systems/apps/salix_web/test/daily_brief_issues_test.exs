defmodule Salix.Bindings.DailyBriefIssuesTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.DailyBriefIssues, as: Issues

  defmodule GitHubStub do
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      ["Bearer " <> token] = get_req_header(conn, "authorization")
      owner = SystemsRuntime.fetch_env!(:salix_web, :daily_brief_issues_test_owner)
      SystemsRuntime.Proc.send(owner, {:github, conn.request_path, token})

      {status, body} =
        case conn.request_path do
          "/repos/acme/app/issues/1" ->
            {200,
             %{"state" => "open", "pull_request" => %{"merged_at" => "2026-11-12T09:00:00Z"}}}

          "/repos/acme/app/issues/2" ->
            {200, %{"state" => "closed"}}

          "/repos/acme/app/issues/3" ->
            {200, %{"state" => "open", "draft" => true, "pull_request" => %{}}}

          "/repos/acme/app/issues/4" ->
            {200, %{"state" => "open", "draft" => false, "pull_request" => %{}}}

          "/repos/acme/app/pulls/4" ->
            {200, %{"mergeable_state" => "dirty"}}

          "/repos/acme/app/issues/5" ->
            {200, %{"state" => "open"}}

          "/search/issues" ->
            {200,
             %{"items" => Salix.Bindings.DailyBriefIssuesTest.Search.items(conn.query_string)}}

          "/orgs/acme/members" ->
            {200, [%{"login" => "bo-gh"}, %{"login" => "carol"}, %{"login" => "dave"}]}

          "/users/bo-gh" ->
            {200, %{"login" => "bo-gh", "name" => "Bo Li"}}

          "/users/carol" ->
            {200, %{"login" => "carol", "name" => nil}}

          "/users/dave" ->
            {200, %{"login" => "dave", "name" => "Dave"}}

          "/repos/acme/app/pulls/7/commits" ->
            {200, [%{"author" => %{"login" => "bo"}}]}

          "/repos/acme/app/pulls/8/commits" ->
            {200, [%{"author" => %{"login" => "bo"}}, %{"author" => %{"login" => "zan"}}]}

          _missing ->
            {404, %{"message" => "Not Found"}}
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end

  defmodule Search do
    def items(query) do
      %{"q" => q} = URI.decode_query(query)
      owner = SystemsRuntime.fetch_env!(:salix_web, :daily_brief_issues_test_owner)
      SystemsRuntime.Proc.send(owner, {:search, q})

      [
        %{
          "repository_url" => "https://api.github.com/repos/acme/app",
          "number" => 7,
          "title" => "iOS 一键连 iMessage",
          "closed_at" => "2026-11-12T09:41:00Z",
          "pull_request" => %{"merged_at" => "2026-11-12T09:41:00Z"}
        },
        %{
          "repository_url" => "https://api.github.com/repos/acme/app",
          "number" => 8,
          "title" => "用量面板",
          "closed_at" => "2026-11-12T10:00:00Z",
          "pull_request" => %{"merged_at" => nil}
        }
      ]
    end
  end

  defmodule OAuthStore do
    def agent_oauth_context("agent"), do: {:ok, %{tenant: "tenant", group_id: "group"}}
    def agent_oauth_context(_other), do: {:error, :not_found}

    def bindings_for_group("group") do
      {:ok,
       [
         %{
           "provider" => "github",
           "alias" => "mine",
           "connection_id" => "gh-owned",
           "owner" => "someone"
         },
         %{"provider" => "github", "alias" => "team", "connection_id" => "gh-team"}
       ]}
    end
  end

  setup do
    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_store = SystemsRuntime.get_env(:salix_agent, :oauth_store_mod)
    prev_overrides = SystemsRuntime.get_env(:salix_store, :oauth_endpoint_overrides)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :oauth_store_mod, OAuthStore)
    SystemsRuntime.put_env(:salix_web, :daily_brief_issues_test_owner, SystemsRuntime.Proc.self())

    bandit =
      start_supervised!(
        {Bandit, plug: GitHubStub, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    SystemsRuntime.put_env(:salix_store, :oauth_endpoint_overrides, %{
      "github" => %{"api_url" => "http://127.0.0.1:#{port}"}
    })

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_backend)
      SystemsRuntime.put_env(:salix_store, :oauth_endpoint_overrides, prev_overrides)

      if prev_store,
        do: SystemsRuntime.put_env(:salix_agent, :oauth_store_mod, prev_store),
        else: SystemsRuntime.delete_env(:salix_agent, :oauth_store_mod)

      SystemsRuntime.delete_env(:salix_web, :daily_brief_issues_test_owner)
    end)

    for {id, token} <- [{"gh-owned", "owned-token"}, {"gh-team", "team-token"}] do
      :ok =
        SalixStore.OAuth.put(id, %{
          "connection_id" => id,
          "provider" => "github",
          "access_token" => token,
          "status" => "active"
        })
    end

    :ok
  end

  test "reads each pull request's state with the group's shared GitHub account" do
    issues = for n <- ~w(1 2 3 4 5 6), do: %{repo: "acme/app", number: n}

    assert {:ok, states} = Issues.states(%{agent_id: "agent", issues: issues})

    assert states == %{
             "acme/app#1" => "merged",
             "acme/app#2" => "closed",
             "acme/app#3" => "draft",
             "acme/app#4" => "open, conflicts with its base",
             "acme/app#5" => "open"
           }

    assert_received {:github, "/repos/acme/app/issues/1", "team-token"}
    refute_received {:github, _path, "owned-token"}
  end

  test "lists the pull requests a login closed in the window, with their other authors" do
    assert {:ok, [mine, theirs]} =
             Issues.member_pulls(%{
               agent_id: "agent",
               login: "bo",
               since: "2026-11-12",
               until: "2026-11-13"
             })

    assert_received {:search, "author:bo is:pr closed:2026-11-12..2026-11-13"}

    assert %{repo: "acme/app", number: "7", state: "merged", others: []} = mine
    assert %{number: "8", state: "closed", others: ["zan"]} = theirs
  end

  test "finds a member's login by their name among the organization's members" do
    assert {:ok, "bo-gh"} =
             Issues.member_login(%{agent_id: "agent", orgs: ["acme"], names: ["bo li"]})

    assert {:ok, "carol"} =
             Issues.member_login(%{agent_id: "agent", orgs: ["acme"], names: ["Carol"]})

    assert {:ok, nil} =
             Issues.member_login(%{agent_id: "agent", orgs: ["acme"], names: ["Eve"]})
  end

  test "a group without a GitHub account answers no states" do
    assert {:ok, %{}} =
             Issues.states(%{agent_id: "other", issues: [%{repo: "acme/app", number: "1"}]})

    refute_received {:github, _path, _token}
  end
end
