defmodule CommaWeb.CommaSystemFilesTest do
  @moduledoc """
  Drive's System Files space over the real Router VFS: what the Workspace
  owner may see and change, and the audience check for scoped memory notes.
  """
  use Comma.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  @moduletag :capture_log

  alias SalixAgent.AgentWorkspace

  @admin_token "test-token"

  # The information-flow facts seam, answering from the test's own table.
  defmodule Facts do
    @moduledoc false
    def mode(_tenant_id, _group_id), do: "enforce"

    def resolve(request) do
      members = SystemsRuntime.get_env(:comma_web, :system_files_test_members, %{})

      {:ok,
       %{
         "mode" => "enforce",
         "scopes" => %{},
         "membership" =>
           for(
             atom <- request["atoms"],
             Map.has_key?(members, atom),
             into: %{},
             do: {atom, %{"members" => members[atom], "revision" => 1}}
           ),
         "placements" => %{},
         "receipts" => [],
         "policy" => %{},
         "now" => request["now"]
       }}
    end
  end

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner) end)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:comma_core, :salix_client},
            {:comma_web, :api_token},
            {:salix_agent, :ifc_facts_mod},
            {:salix_agent, :storage_authorization_mod},
            {:comma_web, :system_files_test_members}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_platform_models!()
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)
    # Storage billing has its own tests; these files are not about credits.
    SystemsRuntime.put_env(
      :salix_agent,
      :storage_authorization_mod,
      SalixAgent.StorageAuthorization.Noop
    )

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    owner = create_user!("system-files")
    workspace = create_ready_workspace!(owner["id"], %{"name" => "Memory"})

    %{
      owner: owner,
      token: session!(owner),
      workspace: workspace,
      router: workspace["router_agent_id"],
      base: "/v1/comma/groups/#{workspace["default_group_id"]}/system-files"
    }
  end

  test "the owner reads memory, imports and Comma's files, edits memory, and nobody else gets in",
       c do
    seed!(c.router, "/memory/semantic/user.md", "Likes tea.\n")
    seed!(c.router, "/memory/episodes/2026-01-02.md", "Old day.\n")
    seed!(c.router, "/imports/openclaw/1760000000/REPORT.md", "# Import\n")
    seed!(c.router, "/Comma/Notebook.md", "# Notebook\n")
    seed!(c.router, "/notes/private.md", "Not part of the space.\n")

    assert %{"files" => files, "next_cursor" => nil} =
             get!(c, "?path=/memory") |> ok_body()

    assert Enum.map(files, & &1["path"]) ==
             ["/memory/episodes/2026-01-02.md", "/memory/semantic/user.md"]

    get!(c, "?path=/notes") |> expect_status(404)
    get!(c, "/content?path=/notes/private.md") |> expect_status(404)

    assert %{"content" => "# Import\n"} =
             get!(c, "/content?path=/imports/openclaw/1760000000/REPORT.md") |> ok_body()

    # The proactive notebook shows without a Drive device.
    assert %{"files" => [%{"path" => "/Comma/Notebook.md"}]} =
             get!(c, "?path=/Comma") |> ok_body()

    assert %{"content" => "# Notebook\n"} =
             get!(c, "/content?path=/Comma/Notebook.md") |> ok_body()

    # One page at a time, in path order.
    assert %{"files" => [first], "next_cursor" => cursor} =
             get!(c, "?path=/memory/&limit=1") |> ok_body()

    assert %{"files" => [second], "next_cursor" => nil} =
             get!(c, "?path=/memory/&limit=1&cursor=#{cursor}") |> ok_body()

    assert [first["path"], second["path"]] == Enum.map(files, & &1["path"])

    # Any day's episode is the user's to rewrite, not only today's.
    put!(c, "/memory/episodes/2026-01-02.md", "Rewritten.\n") |> ok_body()
    assert {:ok, "Rewritten.\n"} = AgentWorkspace.read(c.router, "/memory/episodes/2026-01-02.md")

    # Only the memory layout is writable; the import archive and Comma's
    # files stay as they were.
    put!(c, "/memory/notes.md", "x") |> expect_status(403)
    put!(c, "/Comma/Notebook.md", "x") |> expect_status(403)
    put!(c, "/imports/openclaw/1760000000/REPORT.md", "x") |> expect_status(403)
    delete!(c, "/imports/openclaw/1760000000/REPORT.md") |> expect_status(403)

    assert {:ok, "# Import\n"} =
             AgentWorkspace.read(c.router, "/imports/openclaw/1760000000/REPORT.md")

    delete!(c, "/memory/semantic/user.md") |> ok_body()
    get!(c, "/content?path=/memory/semantic/user.md") |> expect_status(404)

    {:ok, _router} =
      SalixAgent.Control.configure(
        c.router,
        %{"router_system_prompt" => "Answer briefly."},
        c.workspace["salix_tenant_id"]
      )

    assert %{"content" => "Answer briefly."} = get!(c, "/instructions") |> ok_body()

    # Another account and a restricted session of the owner get nothing.
    outsider = %{c | token: session!(create_user!("system-files-outsider"))}
    get!(outsider, "?path=/memory") |> expect_status(404)
    put!(outsider, "/memory/episodes/2026-01-02.md", "taken") |> expect_status(404)
    get!(outsider, "/instructions") |> expect_status(404)

    restricted = %{
      c
      | token:
          session!(c.owner, %{
            "restricted" => true,
            "group_id" => c.workspace["default_group_id"]
          })
    }

    get!(restricted, "?path=/memory") |> expect_status(403)
    delete!(restricted, "/memory/episodes/2026-01-02.md") |> expect_status(403)
    assert {:ok, "Rewritten.\n"} = AgentWorkspace.read(c.router, "/memory/episodes/2026-01-02.md")
  end

  test "the owner replaces the Router's instructions; a stale edit or one only the shared prompt would answer is refused",
       c do
    tenant = c.workspace["salix_tenant_id"]

    assert %{"content" => "", "hash" => empty} = get!(c, "/instructions") |> ok_body()

    assert %{"content" => "Answer briefly.", "hash" => saved} =
             put_instructions!(c, "Answer briefly.", empty) |> ok_body()

    assert {:ok, %{"router_system_prompt" => "Answer briefly."}} =
             SalixAgent.Control.get(c.router, tenant)

    assert %{"content" => "Answer briefly.", "hash" => ^saved} =
             get!(c, "/instructions") |> ok_body()

    # An edit based on the read before the save does not overwrite it.
    put_instructions!(c, "Answer at length.", empty) |> expect_status(409)

    # Clearing them leaves the Router with none.
    assert %{"content" => ""} = put_instructions!(c, "", saved) |> ok_body()

    # With a shared prompt, clearing would only bring it back.
    {:ok, _router} =
      SalixAgent.Control.configure(c.router, %{"system_prompt" => "Shared rules."}, tenant)

    assert %{"content" => "Shared rules."} = get!(c, "/instructions") |> ok_body()
    put_instructions!(c, "Own rules.") |> ok_body()
    put_instructions!(c, " ") |> expect_status(400)
    assert %{"content" => "Own rules."} = get!(c, "/instructions") |> ok_body()

    # Only the owner's full session writes them.
    outsider = %{c | token: session!(create_user!("instructions-outsider"))}
    put_instructions!(outsider, "Taken.") |> expect_status(404)

    restricted = %{
      c
      | token:
          session!(c.owner, %{"restricted" => true, "group_id" => c.workspace["default_group_id"]})
    }

    put_instructions!(restricted, "Taken.") |> expect_status(403)
    assert %{"content" => "Own rules."} = get!(c, "/instructions") |> ok_body()
  end

  test "with the check on, a scoped note is visible only to its readers and keeps its label", c do
    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, Facts)

    SystemsRuntime.put_env(:comma_web, :system_files_test_members, %{
      "conversation|c_mine" => ["comma_user|" <> c.owner["id"]],
      "conversation|c_theirs" => ["comma_user|someone-else"]
    })

    seed!(c.router, "/memory/scoped/mine.md", "From my DM.\n", ["conversation|c_mine"])
    seed!(c.router, "/memory/scoped/theirs.md", "From their DM.\n", ["conversation|c_theirs"])
    # Written before the check: no label, so agent-private.
    seed!(c.router, "/memory/scoped/unlabelled.md", "Old note.\n")

    assert %{"files" => [%{"path" => "/memory/scoped/mine.md"}]} =
             get!(c, "?path=/memory/scoped") |> ok_body()

    for path <- ["/memory/scoped/theirs.md", "/memory/scoped/unlabelled.md"] do
      get!(c, "/content?path=#{path}") |> expect_status(404)
      put!(c, path, "overwritten") |> expect_status(404)
      delete!(c, path) |> expect_status(404)
    end

    assert {:ok, "From their DM.\n"} = AgentWorkspace.read(c.router, "/memory/scoped/theirs.md")

    assert %{"content" => "From my DM.\n"} =
             get!(c, "/content?path=/memory/scoped/mine.md") |> ok_body()

    put!(c, "/memory/scoped/mine.md", "Edited.\n") |> ok_body()
    assert {:ok, "Edited.\n"} = AgentWorkspace.read(c.router, "/memory/scoped/mine.md")
    assert AgentWorkspace.label(c.router, "/memory/scoped/mine.md") == ["conversation|c_mine"]

    # A new scoped note would have no label and vanish from its author. It is
    # refused the way a hidden one is, so a guessed name reveals nothing.
    assert put!(c, "/memory/scoped/new.md", "New.\n") |> expect_status(404) |> Map.fetch!(:body) ==
             put!(c, "/memory/scoped/theirs.md", "New.\n")
             |> expect_status(404)
             |> Map.fetch!(:body)
  end

  test "an edit or delete based on an older read is refused, not applied", c do
    seed!(c.router, "/memory/semantic/user.md", "Likes tea.\n")
    path = "/memory/semantic/user.md"

    assert %{"hash" => seen} = get!(c, "/content?path=#{path}") |> ok_body()

    # The Router rewrites the file after the user opened it.
    seed!(c.router, path, "Likes coffee now.\n")

    put!(c, path, "Likes tea and cake.\n", seen) |> expect_status(409)
    delete!(c, path, seen) |> expect_status(409)
    assert {:ok, "Likes coffee now.\n"} = AgentWorkspace.read(c.router, path)

    # Reading again names the current content; that edit goes through, and
    # the hash it answers is the one the next edit names.
    assert %{"hash" => current} = get!(c, "/content?path=#{path}") |> ok_body()
    assert %{"hash" => saved} = put!(c, path, "Likes both.\n", current) |> ok_body()
    assert saved == SalixStore.Crypto.hex("Likes both.\n")
    assert {:ok, "Likes both.\n"} = AgentWorkspace.read(c.router, path)
    put!(c, path, "Again.\n", current) |> expect_status(409)
    delete!(c, path, saved) |> ok_body()

    # A file that is gone never matches what the user saw.
    put!(c, path, "Back.\n", saved) |> expect_status(409)
    assert {:error, :not_found} = AgentWorkspace.read(c.router, path)
  end

  defp seed!(agent_id, path, body, label \\ nil) do
    opts = if label, do: [ifc_label: label], else: []
    assert {:ok, _result} = SalixAgent.Workspace.write(agent_id, path, body, opts)
  end

  defp create_user!(prefix) do
    admin_req(:post, "/v1/comma/admin/users",
      json: %{
        "email" => "#{prefix}-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.com"
      }
    )
    |> expect_status(201)
    |> Map.fetch!(:body)
  end

  defp session!(user, attrs \\ %{}) do
    admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: attrs)
    |> expect_status(201)
    |> get_in([Access.key!(:body), "token"])
  end

  defp get!(c, suffix), do: user_req(c.token, :get, c.base <> suffix)

  defp put!(c, path, content, expected_hash \\ nil) do
    body = %{"path" => path, "content" => content}
    body = if expected_hash, do: Map.put(body, "expected_hash", expected_hash), else: body
    user_req(c.token, :put, c.base <> "/content", json: body)
  end

  defp put_instructions!(c, content, expected_hash \\ nil) do
    body = %{"content" => content}
    body = if expected_hash, do: Map.put(body, "expected_hash", expected_hash), else: body
    user_req(c.token, :put, c.base <> "/instructions", json: body)
  end

  defp delete!(c, path, expected_hash \\ nil) do
    params = if expected_hash, do: [path: path, expected_hash: expected_hash], else: [path: path]
    user_req(c.token, :delete, c.base <> "/content?" <> URI.encode_query(params))
  end

  defp ok_body(resp), do: resp |> expect_status(200) |> Map.fetch!(:body)

  defp admin_req(method, path, opts),
    do: req([{"authorization", "Bearer " <> @admin_token}], method, path, opts)

  defp user_req(token, method, path, opts \\ []),
    do: req([{"authorization", "Bearer " <> token}], method, path, opts)

  defp req(headers, method, path, opts) do
    Req.request!(
      [
        method: method,
        url: CommaWeb.Application.base_url() <> path,
        headers: headers,
        retry: false
      ] ++ opts
    )
  end

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp
  end
end
