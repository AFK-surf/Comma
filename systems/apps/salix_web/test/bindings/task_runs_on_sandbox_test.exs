defmodule Salix.Bindings.TaskRunsOnSandboxTest do
  @moduledoc """
  A coding Task's place (`runs_on {kind: sandbox}`) through
  `Salix.Bindings.AgentConversations.runs_on/2`: the repository must be well
  formed and one the Group's GitHub account reads, the Group under its limit
  of sandboxes, and coding sandboxes set up. GitHub is a fake.
  """
  use SystemsClock.Case, async: false

  alias Salix.Bindings.AgentConversations
  alias SalixStore.CodingSandboxes

  defmodule GitHub do
    @moduledoc false
    def token(_tenant, group) do
      if group == SystemsRuntime.get_env(:salix_web, :sandbox_test_unconnected),
        do: {:error, :github_not_connected},
        else: {:ok, %{token: "ghu_x", expires_at: nil}}
    end

    def repo(_token, "acme", "api"),
      do: {:ok, %{full_name: "acme/api", default_branch: "trunk", private: false, push: true}}

    def repo(_token, _owner, _name), do: {:error, :not_found}

    def pull_request_refs(_token, "acme", "api", 7),
      do: {:ok, %{state: "open", head_ref: "fix/login", head_repo: "acme/api", base_ref: "trunk"}}

    def pull_request_refs(_token, "acme", "api", 8),
      do: {:ok, %{state: "merged", head_ref: "fix/old", head_repo: "acme/api", base_ref: "trunk"}}

    def pull_request_refs(_token, "acme", "api", 9),
      do: {:ok, %{state: "open", head_ref: "main", head_repo: "someone/api", base_ref: "trunk"}}

    def pull_request_refs(_token, "acme", "api", 10),
      do: {:ok, %{state: "open", head_ref: "gone", head_repo: nil, base_ref: "trunk"}}

    def pull_request_refs(_token, "acme", "api", 11), do: {:error, {:github, 503}}

    def pull_request_refs(_token, _owner, _name, _number), do: {:error, :not_found}
  end

  defmodule Signer do
    @moduledoc false
    def sign(claims), do: {:ok, claims}
  end

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Sandbox runs_on"})

    {:ok, group} =
      Salix.Control.Groups.create(%{"name" => "Sandbox runs_on"}, tenant["tenant_id"])

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Worker", "role" => "worker"},
        tenant["tenant_id"]
      )

    SystemsRuntime.put_env(:salix_web, :l4es, url: "https://l4es.test", max_sandboxes: 2)
    SystemsRuntime.put_env(:salix_web, :l4es_assertion_signer, Signer)
    SystemsRuntime.put_env(:salix_web, :coding_github, GitHub)

    on_exit(fn ->
      for key <- [:l4es, :l4es_assertion_signer, :coding_github, :sandbox_test_unconnected],
          do: SystemsRuntime.delete_env(:salix_web, key)
    end)

    {:ok,
     scope: %{
       tenant_id: tenant["tenant_id"],
       group_id: group["group_id"],
       agent_id: worker["agent_id"]
     }}
  end

  defp live(scope, conversations) do
    for c <- conversations do
      {:ok, _} =
        CodingSandboxes.create(%{
          tenant_id: scope.tenant_id,
          group_id: scope.group_id,
          conversation_id: c,
          workspace: "comma:" <> scope.group_id,
          repo: %{"owner" => "acme", "name" => "api"}
        })
    end
  end

  defp sandbox(scope, repo),
    do: AgentConversations.runs_on(scope, %{"kind" => "sandbox", "repo" => repo})

  test "a readable repository is accepted, starting from its default branch unless one is named",
       %{scope: scope} do
    assert sandbox(scope, %{"owner" => "acme", "name" => "api"}) ==
             {:ok,
              %{
                "kind" => "sandbox",
                "repo" => %{"owner" => "acme", "name" => "api", "base_ref" => "trunk"}
              }}

    assert {:ok, %{"repo" => %{"base_ref" => "release/2.1", "branch" => "fix/retry"}}} =
             sandbox(scope, %{
               "owner" => "acme",
               "name" => "api",
               "base_ref" => "release/2.1",
               "branch" => "fix/retry"
             })
  end

  test "a Task that continues an open pull request works on its head branch, into its base",
       %{scope: scope} do
    assert sandbox(scope, %{"owner" => "acme", "name" => "api", "pull_request" => 7}) ==
             {:ok,
              %{
                "kind" => "sandbox",
                "repo" => %{
                  "owner" => "acme",
                  "name" => "api",
                  "base_ref" => "trunk",
                  "branch" => "fix/login",
                  "pull_request" => 7
                }
              }}
  end

  test "a pull request that is not open, from a fork, without a usable head, unknown, unreadable, or with branches named, is refused",
       %{scope: scope} do
    pr = &sandbox(scope, Map.merge(%{"owner" => "acme", "name" => "api"}, &1))

    assert pr.(%{"pull_request" => 8}) == {:error, {:pull_request_not_open, 8, "merged"}}
    assert pr.(%{"pull_request" => 9}) == {:error, {:pull_request_from_fork, 9}}
    assert pr.(%{"pull_request" => 10}) == {:error, {:pull_request_branch_unusable, 10}}
    assert pr.(%{"pull_request" => 404}) == {:error, {:pull_request_not_found, "acme/api#404"}}
    assert pr.(%{"pull_request" => 11}) == {:error, {:pull_request_unreadable, "acme/api#11"}}
    assert pr.(%{"pull_request" => 7, "branch" => "x"}) == {:error, :invalid_repo}
    assert pr.(%{"pull_request" => "7"}) == {:error, :invalid_repo}
  end

  test "a repository GitHub does not show, or a malformed one, is refused", %{scope: scope} do
    assert sandbox(scope, %{"owner" => "acme", "name" => "secret"}) ==
             {:error, {:repo_not_found, "acme/secret"}}

    for bad <- [
          %{"owner" => "acme"},
          %{"owner" => "acme", "name" => "api;rm"},
          %{"owner" => "acme", "name" => "api", "base_ref" => "../x"},
          %{"owner" => "acme", "name" => "api", "branch" => "x.lock"},
          %{"owner" => "acme", "name" => "api", "extra" => "y"}
        ],
        do: assert(sandbox(scope, bad) == {:error, :invalid_repo}, inspect(bad))
  end

  test "a Group without a connected GitHub account is refused", %{scope: scope} do
    SystemsRuntime.put_env(:salix_web, :sandbox_test_unconnected, scope.group_id)

    assert sandbox(scope, %{"owner" => "acme", "name" => "api"}) ==
             {:error, :github_not_connected}
  end

  test "a Group at its limit of live sandboxes is refused", %{scope: scope} do
    live(scope, ["cnv_1", "cnv_2"])
    assert sandbox(scope, %{"owner" => "acme", "name" => "api"}) == {:error, {:sandbox_limit, 2}}
  end

  test "a Workspace's own limit replaces the default in the check and the assertion",
       %{scope: scope} do
    live(scope, ["cnv_1", "cnv_2"])
    assert sandbox(scope, %{"owner" => "acme", "name" => "api"}) == {:error, {:sandbox_limit, 2}}
    assert {:ok, %{max_sandboxes: 2}} = SalixWeb.L4ES.assertion(scope.group_id)

    assert SalixWeb.L4ES.put_sandbox_limit(scope.tenant_id, 3) ==
             {:ok, %{"override" => 3, "default" => 2, "effective" => 3}}

    assert {:ok, _} = sandbox(scope, %{"owner" => "acme", "name" => "api"})
    assert {:ok, %{max_sandboxes: 3}} = SalixWeb.L4ES.assertion(scope.group_id)
    live(scope, ["cnv_3"])
    assert sandbox(scope, %{"owner" => "acme", "name" => "api"}) == {:error, {:sandbox_limit, 3}}

    assert {:ok, %{"override" => nil, "effective" => 2}} =
             SalixWeb.L4ES.put_sandbox_limit(scope.tenant_id, nil)

    assert {:ok, %{max_sandboxes: 2}} = SalixWeb.L4ES.assertion(scope.group_id)
  end

  test "a Workspace limit must be an integer from 1 to 100", %{scope: scope} do
    for bad <- [0, 101, "3", 2.5],
        do:
          assert(
            {:error, {:bad_request, _}} = SalixWeb.L4ES.put_sandbox_limit(scope.tenant_id, bad)
          )

    assert {:ok, %{"override" => nil}} = SalixWeb.L4ES.sandbox_limit(scope.tenant_id)
  end

  test "without L4ES, coding sandboxes are not available", %{scope: scope} do
    SystemsRuntime.delete_env(:salix_web, :l4es)
    assert sandbox(scope, %{"owner" => "acme", "name" => "api"}) == {:error, :sandbox_unavailable}
  end
end
