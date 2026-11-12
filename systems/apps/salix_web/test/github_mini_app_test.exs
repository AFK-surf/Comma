defmodule SalixWeb.GitHubMiniAppTest do
  use ExUnit.Case, async: false

  alias SalixWeb.GitHub

  # GitHub's REST answers by method and path; each request is recorded for the test to read.
  defp stub(routes) do
    test = self()

    SystemsRuntime.put_env(:salix_web, :github_http_options,
      plug: fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = if raw == "", do: nil, else: Jason.decode!(raw)
        send(test, {:github, conn.method, conn.request_path, body})

        {status, answer} =
          Map.get(routes, {conn.method, conn.request_path}, {404, %{"message" => "Not Found"}})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(answer))
      end
    )

    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :github_http_options) end)
  end

  test "repository selection pages organizations and searches only the chosen owner" do
    test = self()

    SystemsRuntime.put_env(:salix_web, :github_http_options,
      plug: fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test, {:repo_read, conn.request_path, conn.query_params})

        result =
          case conn.request_path do
            "/user" ->
              %{
                "login" => "ann",
                "id" => 1,
                "avatar_url" => "https://avatars.githubusercontent.com/u/1?v=4"
              }

            "/user/orgs" ->
              [
                %{
                  "login" => "acme",
                  "avatar_url" => "https://avatars.githubusercontent.com/u/2?v=4"
                }
              ]

            "/search/repositories" ->
              %{
                "total_count" => 1001,
                "incomplete_results" => false,
                "items" => [
                  %{"owner" => %{"login" => "acme"}, "name" => "ios", "private" => true},
                  %{"owner" => %{"login" => "other"}, "name" => "leaked"}
                ]
              }

            "/orgs/acme/repos" ->
              [%{"owner" => %{"login" => "acme"}, "name" => "api", "default_branch" => "main"}]
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(result))
      end
    )

    on_exit(fn -> SystemsRuntime.delete_env(:salix_web, :github_http_options) end)

    assert {:ok,
            %{
              owners: [
                %{
                  login: "ann",
                  kind: "user",
                  avatar_url: "https://avatars.githubusercontent.com/u/1?v=4"
                },
                %{
                  login: "acme",
                  kind: "organization",
                  avatar_url: "https://avatars.githubusercontent.com/u/2?v=4"
                }
              ],
              has_more: false
            }} = GitHub.repo_owners("t", 1)

    assert {:ok, %{owners: [%{login: "acme"}]}} = GitHub.repo_owners("t", 2)

    assert {:ok, %{repos: [%{owner: "acme", name: "api"}], has_more: false}} =
             GitHub.repo_search("t", "acme", "organization", "", 2)

    assert {:ok,
            %{
              repos: [%{owner: "acme", name: "ios", private: true}],
              has_more: true,
              limited: true
            }} = GitHub.repo_search("t", "acme", "organization", "ios org:other", 2)

    assert_received {:repo_read, "/orgs/acme/repos", %{"page" => "2", "per_page" => "100"}}

    assert_received {:repo_read, "/search/repositories",
                     %{"q" => "user:acme in:name fork:true ios org other", "page" => "2"}}

    assert {:ok, %{has_more: false}} = GitHub.repo_search("t", "acme", "organization", "ios", 10)
  end

  test "a commit is on the branch when the branch is at it or ahead of it" do
    stub(%{
      {"GET", "/repos/ann/app/compare/aaa...comma%2Fx"} => {200, %{"status" => "ahead"}},
      {"GET", "/repos/ann/app/compare/bbb...comma%2Fx"} => {200, %{"status" => "diverged"}}
    })

    assert :ok = GitHub.commit_on_branch("t", "ann", "app", "aaa", "comma/x")

    assert {:error, :commit_not_on_branch} =
             GitHub.commit_on_branch("t", "ann", "app", "bbb", "comma/x")

    assert {:error, :commit_not_on_branch} =
             GitHub.commit_on_branch("t", "ann", "app", "ccc", "comma/x")
  end

  test "a remix repository gets the source as one commit on main" do
    git = "/repos/ann/comma-app-x/git"

    stub(%{
      {"POST", "/user/repos"} =>
        {201,
         %{"name" => "comma-app-x", "owner" => %{"login" => "ann"}, "default_branch" => "main"}},
      {"GET", git <> "/ref/heads/main"} => {200, %{"object" => %{"sha" => "init"}}},
      {"POST", git <> "/blobs"} => {201, %{"sha" => "blob"}},
      {"POST", git <> "/trees"} => {201, %{"sha" => "tree"}},
      {"POST", git <> "/commits"} => {201, %{"sha" => "commit"}},
      {"PATCH", git <> "/refs/heads/main"} => {200, %{"ref" => "refs/heads/main"}}
    })

    assert {:ok, %{owner: "ann", name: "comma-app-x", default_branch: "main"}} =
             GitHub.create_repo_with_files(
               "t",
               "comma-app-x",
               [{"index.html", "<p>", false}, {"run.sh", "#!/bin/sh", true}],
               "Remix"
             )

    assert_received {:github, "POST", "/user/repos", %{"private" => true, "auto_init" => true}}
    assert_received {:github, "POST", _, %{"tree" => tree}}

    assert [
             %{"path" => "index.html", "mode" => "100644"},
             %{"path" => "run.sh", "mode" => "100755"}
           ] =
             tree

    assert_received {:github, "POST", _, %{"tree" => "tree", "parents" => ["init"]}}
    assert_received {:github, "PATCH", _, %{"sha" => "commit", "force" => true}}

    # Too many files: nothing is made.
    files = for n <- 1..501, do: {"f#{n}", "x", false}
    assert {:error, {:too_large, _}} = GitHub.create_repo_with_files("t", "y", files, "Remix")
  end

  test "an app repository is generated private from the template" do
    stub(%{
      {"POST", "/repos/AFK-surf/comma-app-template/generate"} =>
        {201,
         %{"name" => "comma-app-x", "owner" => %{"login" => "ann"}, "default_branch" => "main"}}
    })

    assert {:ok, %{owner: "ann", name: "comma-app-x"}} =
             GitHub.generate_from_template(
               "t",
               "AFK-surf/comma-app-template",
               "ann",
               "comma-app-x"
             )

    assert_received {:github, "POST", _,
                     %{"owner" => "ann", "name" => "comma-app-x", "private" => true}}
  end
end
