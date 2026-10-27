defmodule CommaWeb.MiniAppsTest do
  use SystemsClock.Case, async: false

  @moduletag :capture_log
  @moduletag :tmp_dir

  import Ecto.Query

  alias Comma.{Accounts, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.MiniApps.Version
  alias SalixAgent.DecideFixture
  alias SalixStore.Ids

  @branch_head "0123456789abcdef0123456789abcdef01234567"
  @other_commit "89abcdef0123456789abcdef0123456789abcdef"

  # The connected GitHub account as Mini Apps see it; every write is recorded.
  defmodule GitHub do
    @moduledoc false
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> %{calls: [], pr: nil, refuse: nil} end, name: __MODULE__)

    def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    def put_pr(pr), do: Agent.update(__MODULE__, &%{&1 | pr: pr})
    def refuse(reason), do: Agent.update(__MODULE__, &%{&1 | refuse: reason})
    defp record(call), do: Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})

    def pull_request("ghu_x", _owner, _name, "comma/app"),
      do: {:ok, Agent.get(__MODULE__, & &1.pr)}

    # Opens the branch's pull request at what the branch holds (its head is the deployed commit).
    def create_pull_request("ghu_x", owner, name, %{"head" => "comma/app"} = pr) do
      record({:create_pr, pr["base"], pr["title"]})
      url = "https://github.com/#{owner}/#{name}/pull/7"

      put_pr(%{
        url: url,
        number: 7,
        title: pr["title"],
        body: pr["body"],
        head_sha: "0123456789abcdef0123456789abcdef01234567",
        state: "open",
        mergeable: "mergeable",
        checks: nil,
        new_commits: false
      })

      {:ok, %{url: url, number: 7, title: pr["title"]}}
    end

    # As GitHub does: a refusal comes back as it says it; a moved head is refused.
    def merge_pull_request("ghu_x", _owner, _name, number, method, sha) do
      case Agent.get(__MODULE__, & &1) do
        %{refuse: refusal} when not is_nil(refusal) ->
          {:error, refusal}

        %{pr: %{head_sha: ^sha, number: ^number}} ->
          record({:merge, number, method, sha})
          Agent.update(__MODULE__, fn s -> %{s | pr: %{s.pr | state: "merged"}} end)
          :ok

        _ ->
          {:error, {:github, 409, "Head branch was modified."}}
      end
    end

    def token(_tenant, _group), do: {:ok, %{token: "ghu_x", expires_at: nil}}
    def user("ghu_x"), do: {:ok, %{login: "ann", id: 1, email: "1+ann@users.noreply.github.com"}}

    def generate_from_template("ghu_x", template, owner, name) do
      record({:generate, template, owner, name})
      {:ok, %{owner: owner, name: name, default_branch: "main"}}
    end

    def file_exists("ghu_x", "acme", "has-manifest", "comma-app.json"), do: :ok
    def file_exists("ghu_x", _owner, _name, _path), do: {:error, :not_found}

    # Only the branch head is on the session branch.
    def commit_on_branch("ghu_x", _owner, _name, sha, "comma/app") do
      if sha == "0123456789abcdef0123456789abcdef01234567",
        do: :ok,
        else: {:error, :commit_not_on_branch}
    end

    def create_repo_with_files("ghu_x", name, files, _message) do
      record({:create_repo, name, Enum.map(files, &elem(&1, 0))})
      {:ok, %{owner: "ann", name: name, default_branch: "main"}}
    end

    def merge_method(_token, _owner, _name), do: record(:merge_method) && {:ok, "squash"}
  end

  # The stations a remix Task is given to: none runs here.
  defmodule Stations do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskStations

    @impl true
    def invite(_invitation), do: {:ok, "ember:c-1"}
    @impl true
    def joined(_row), do: :ok
    @impl true
    def moved(_move), do: :ok
    @impl true
    def sessions(_group_id, _conversation_id), do: {:ok, %{}}
    @impl true
    def sandbox(_reservation), do: :ok
    @impl true
    def task_status(_group_id, _conversation_id, _status), do: :ok
    @impl true
    def appended(_group_id, _conversation_id), do: :ok
    @impl true
    def standing(_group_id, _conversation_id), do: :not_station
    @impl true
    def session_status(_group_id, _conversation_id), do: :unknown
  end

  # The product's place checks, taken as asked (no L4ES here).
  defmodule Places do
    @moduledoc false
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(group_id, delegator, target, attrs),
      do:
        Salix.Bindings.AgentConversations.create_task_conversation(
          group_id,
          delegator,
          target,
          attrs
        )

    @impl true
    def runs_on(_scope, request), do: {:ok, request}
    @impl true
    def session_model(_scope, choice), do: {:ok, choice}

    # The Group's Worker the test made.
    @impl true
    def task_worker(_scope),
      do: {:ok, SystemsRuntime.fetch_env!(:comma_web, :mini_app_test_worker)}
  end

  # A Group's Comma Drive as `SalixAgent.Drive` implementations answer.
  defmodule Drive do
    @moduledoc false
    use Agent

    def start_link(_), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def files, do: Agent.get(__MODULE__, & &1)

    def list(group, dir) do
      prefix = dir <> "/"

      entries =
        for {{^group, path}, body} <- files(), String.starts_with?(path, prefix) do
          %{
            path: path,
            name: Path.basename(path),
            kind: "file",
            size: byte_size(body),
            modified_at: 1_790_000_000
          }
        end

      if entries == [], do: {:error, :not_found}, else: {:ok, entries}
    end

    def read(group, path, max) do
      case files()[{group, path}] do
        nil -> {:error, :not_found}
        body -> {:ok, binary_part(body, 0, min(max, byte_size(body))), byte_size(body) > max}
      end
    end

    def write(group, path, body, size) do
      Agent.update(__MODULE__, &Map.put(&1, {group, path}, IO.iodata_to_binary(body)))
      {:ok, %{size: size, root: nil}}
    end

    def delete(group, path) do
      Agent.update(__MODULE__, &Map.delete(&1, {group, path}))
      {:ok, %{withdrawn: true, still_published: false}}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo), do: start_supervised!(BillingCore.Repo)
    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    start_supervised!(GitHub)
    SystemsRuntime.put_env(:salix_web, :coding_github, GitHub)

    SystemsRuntime.put_env(:comma_core, :mini_app_rate_limit,
      peer: [burst: 100_000, rate: 10_000.0],
      app: [burst: 100_000, rate: 10_000.0]
    )

    test = self()

    SystemsRuntime.put_env(:comma_core, :mini_apps_cloudflare_http_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        send(test, {:cloudflare, conn.method, conn.request_path, body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"success":true,"result":{}}))
      end
    )

    SystemsRuntime.put_env(:comma_web, :mini_app_dispatch_http_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        send(
          test,
          {:dispatch, conn.method, conn.request_path, conn.query_string, conn.req_headers, body}
        )

        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(201, "made " <> body)
      end
    )

    SalixAgent.TestSupport.configure_control_fixtures!()
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Mini Apps"})
    other_tenant = SalixAgent.TestSupport.new_tenant_id()
    other_group = Ids.new_group_id(other_tenant)
    SalixAgent.TestSupport.create_control_group!(other_group, %{"name" => "Other team"})

    on_exit(fn ->
      for {app, key} <- [
            {:salix_web, :coding_github},
            {:comma_core, :mini_app_rate_limit},
            {:comma_core, :mini_apps_cloudflare_http_options},
            {:comma_web, :mini_app_dispatch_http_options}
          ],
          do: SystemsRuntime.delete_env(app, key)

      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
      CommaWeb.TestRepoSandbox.stop_owner(owner)
    end)

    {ann, ann_session} = user!()
    {bob, bob_session} = user!()
    {cat, cat_session} = user!()
    workspace = workspace!(ann, tenant, group)
    member!(workspace, bob, "member")
    other = workspace!(cat, other_tenant, other_group)

    server =
      start_supervised!(
        {Bandit, plug: CommaWeb.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    %{
      base: "http://127.0.0.1:#{port}",
      tmp: tmp_dir,
      workspace: workspace,
      other: other,
      ann: {ann, ann_session},
      bob: {bob, bob_session},
      cat: {cat, cat_session}
    }
  end

  test "a backend manifest provisions namespaced storage and appears in the app view", ctx do
    classes = start_supervised!({Agent, fn -> MapSet.new() end})

    SystemsRuntime.put_env(:comma_core, :mini_apps_cloudflare_http_options,
      plug: fn conn ->
        conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart]))
        metadata = conn.body_params["metadata"].path |> File.read!() |> Jason.decode!()

        [_, namespace, script] =
          Regex.run(~r|/dispatch/namespaces/([^/]+)/scripts/([^/]+)$|, conn.request_path)

        for class <- get_in(metadata, ["migrations", "new_sqlite_classes"]) || [] do
          Agent.update(classes, &MapSet.put(&1, {namespace, script, class}))
        end

        bound? =
          Enum.all?(metadata["bindings"] || [], fn
            %{"type" => "durable_object_namespace"} = binding ->
              target =
                {binding["dispatch_namespace"], binding["script_name"], binding["class_name"]}

              Agent.get(classes, &MapSet.member?(&1, target))

            _ ->
              true
          end)

        {status, body} =
          if bound?,
            do: {200, %{"success" => true, "result" => %{}}},
            else:
              {400,
               %{
                 "errors" => [
                   %{
                     "message" => "Cannot create binding for class in script that does not exist."
                   }
                 ]
               }}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end
    )

    app = create_app!(ctx)
    assert app["has_backend"] == false
    assert app["storage"] == []
    assert app["egress"] == []
    files = files!(ctx.tmp, backend?: true)

    assert {:ok, %{"version" => 1}} =
             CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "backend-first"), files)

    assert %{status: 200, body: view} =
             req(ctx, :get, "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}", ctx.ann)

    assert view["has_backend"] == true
    assert view["storage"] == ["app", "user", "device"]
    assert view["egress"] == ["api.open-meteo.com"]

    # The existing data script remains the target of subsequent Versions.
    assert {:ok, %{"version" => 2}} =
             CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "backend-second"), files)
  end

  test "deploy checks the commit and files, stores the Version once per key, and uploads its backend",
       ctx do
    app = create_app!(ctx)
    files = files!(ctx.tmp, backend?: true)

    # A commit that is not on the pushed session branch makes no Version.
    assert {:error, :commit_not_on_branch} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-other-commit", @other_commit),
               files
             )

    # A manifest the schema refuses comes back as every problem it has.
    bad = %{
      files
      | manifest: Jason.encode!(%{"name" => "", "capabilities" => ["camera"], "x" => 1})
    }

    assert {:error, {:invalid, errors}} =
             CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-bad-manifest"), bad)

    assert "unknown field x" in errors
    assert Enum.any?(errors, &(&1 =~ "capabilities"))
    assert Repo.aggregate(from(v in Version, where: v.app_id == ^app["id"]), :count) == 0

    assert {:ok, result} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-first"), files)

    assert result == %{
             "app_id" => app["id"],
             "version" => 1,
             "state" => "ready",
             "name" => "Habit tracker",
             "summary" => "Habit tracker — preview version 1"
           }

    # The storage script once, then the Version script bound to it, with its secret.
    assert_received {:cloudflare, "PUT", data_path, data_body}

    assert data_path =~
             ~r|/accounts/test-account/workers/dispatch/namespaces/comma-miniapps-test/scripts/app-[a-z0-9]{8}-data$|

    assert data_body =~ ~s("new_sqlite_classes":["AppStorage"])

    assert_received {:cloudflare, "PUT", version_path, version_body}
    assert version_path =~ ~r|/scripts/app-#{app["slug"]}-v1$|
    assert version_body =~ ~s("script_name":"app-#{app["slug"]}-data")
    assert version_body =~ ~s("class_name":"AppStorage")
    assert version_body =~ ~s("cpu_ms":50)
    assert version_body =~ "export default"

    # The same key again: the same Version, nothing uploaded again.
    assert {:ok, ^result} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-first"), files)
    refute_received {:cloudflare, _, _, _}
    assert Repo.aggregate(from(v in Version, where: v.app_id == ^app["id"]), :count) == 1

    # A second deploy is Version 2; the storage script is not uploaded again.
    assert {:ok, %{"version" => 2}} =
             CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-second"), files)

    assert_received {:cloudflare, "PUT", second_path, _}
    assert second_path =~ ~r|-v2$|
    refute_received {:cloudflare, _, _, _}

    # A deploy into another Group's app is refused.
    assert {:error, :not_found} =
             CommaWeb.MiniAppPort.deploy(
               %{deploy_ctx(ctx, app, "key-wrong-group") | group_id: ctx.other.salix_group_id},
               files
             )
  end

  # The gallery shows each app's cover: a small screenshot a deploy checks and every viewer reads once.
  test "a deploy keeps a small cover, refuses a large one, and viewers read it from the app view",
       ctx do
    app = create_app!(ctx)
    ws = ctx.workspace.id
    via = [{"x-comma-app-via", "workspace/#{ws}"}]

    png = fn width, height, padding ->
      <<0x89, "PNG\r\n", 0x1A, "\n", 13::32, "IHDR", width::32, height::32, 8, 2, 0, 0, 0, 0::32,
        0::size(padding)-unit(8)>>
    end

    assert {:error, {:invalid, [too_wide]}} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-wide"),
               files!(ctx.tmp, cover: {"cover.png", png.(2400, 1800, 0)})
             )

    assert too_wide =~ "2400 × 1800 pixels"

    assert {:error, {:invalid, [too_heavy]}} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-heavy"),
               files!(ctx.tmp, cover: {"cover.png", png.(780, 585, 200 * 1024)})
             )

    assert too_heavy =~ "larger than 160 KiB"

    # A name that says WebP over PNG bytes is not the image it says.
    assert {:error, {:invalid, [mismatch]}} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-mismatch"),
               files!(ctx.tmp, cover: {"cover.webp", png.(780, 585, 0)})
             )

    assert mismatch =~ "not a WebP image"
    assert Repo.aggregate(from(v in Version, where: v.app_id == ^app["id"]), :count) == 0

    cover = png.(780, 585, 1024)

    assert {:ok, %{"version" => 1}} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-cover"),
               files!(ctx.tmp, cover: {"cover.png", cover})
             )

    assert %{status: 200, body: %{"cover_url" => url}} =
             req(ctx, :get, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}", ctx.ann)

    assert url == "/v1/comma/apps/#{app["id"]}/cover?v=1"

    read = req(ctx, :get, url, ctx.ann, nil, via)
    assert read.status == 200
    assert read.body == cover
    assert Req.Response.get_header(read, "content-type") == ["image/png"]

    assert Req.Response.get_header(read, "cache-control") == [
             "private, max-age=31536000, immutable"
           ]

    # Another Workspace's member reads no cover of this private app.
    other_via = [{"x-comma-app-via", "workspace/#{ctx.other.id}"}]
    assert %{status: 404} = req(ctx, :get, url, ctx.cat, nil, other_via)

    # A Version without a cover shows none.
    assert {:ok, %{"version" => 2}} =
             CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-plain"), files!(ctx.tmp))

    assert %{status: 200, body: %{"cover_url" => nil}} =
             req(ctx, :get, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}", ctx.ann)
  end

  test "bundle reads follow visibility, Installs and the link; revoking the link removes Installs",
       ctx do
    app = create_app!(ctx)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))

    assert {:ok, _} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-v2"),
               files!(ctx.tmp, backend?: true)
             )

    ws = ctx.workspace.id
    bundle = "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/versions/1/bundle"

    # Private: only its creator reads it.
    assert %{status: 200, body: tar} = req(ctx, :get, bundle, ctx.ann)
    assert {:ok, [{~c"index.html", _}, _]} = :erl_tar.extract({:binary, tar}, [:memory])
    assert %{status: 404} = req(ctx, :get, bundle, ctx.bob)

    assert %{status: 200, body: %{"visibility" => "workspace"}} =
             req(ctx, :patch, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}", ctx.ann, %{
               "visibility" => "workspace"
             })

    assert %{status: 200} = req(ctx, :get, bundle, ctx.bob)
    # A member of another Workspace reads nothing through either Workspace.
    assert %{status: 404} = req(ctx, :get, bundle, ctx.cat)

    assert %{status: 404} =
             req(
               ctx,
               :get,
               "/v1/comma/workspaces/#{ctx.other.id}/apps/#{app["id"]}/versions/1/bundle",
               ctx.cat
             )

    assert %{status: 200, body: %{"live_version" => 1}} =
             req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/rollback", ctx.ann, %{
               "version" => 1
             })

    assert %{status: 200, body: %{"token" => token, "url" => "http://127.0.0.1:5174/a/" <> token}} =
             req(ctx, :put, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/link", ctx.ann)

    assert %{status: 200, body: %{"app" => shared, "version" => 1}} =
             req(ctx, :get, "/v1/comma/apps/links/#{token}", ctx.cat)

    refute Map.has_key?(shared, "repo")

    link_bundle = req(ctx, :get, "/v1/comma/apps/links/#{token}/bundle", ctx.cat)
    assert link_bundle.status == 200
    assert [digest] = Req.Response.get_header(link_bundle, "x-comma-bundle-digest")
    assert digest == :crypto.hash(:sha256, link_bundle.body) |> Base.encode16(case: :lower)

    # Installed through the link, the other Workspace reads the live Version only.
    other_bundle = "/v1/comma/workspaces/#{ctx.other.id}/apps/#{app["id"]}/versions"

    assert %{status: 200, body: %{"installed" => true, "grants" => []}} =
             req(ctx, :post, "/v1/comma/workspaces/#{ctx.other.id}/apps/install", ctx.cat, %{
               "token" => token
             })

    assert %{status: 200} = req(ctx, :get, other_bundle <> "/1/bundle", ctx.cat)
    assert %{status: 404} = req(ctx, :get, other_bundle <> "/2/bundle", ctx.cat)

    assert %{
             status: 200,
             body: %{"data" => [%{"id" => id, "installed" => true, "has_backend" => false}]}
           } = req(ctx, :get, "/v1/comma/workspaces/#{ctx.other.id}/apps", ctx.cat)

    assert id == app["id"]

    # Pinned to Version 2, the Install shows and reads that Version.
    assert %{status: 200, body: %{"install" => %{"pinned_version" => 2}, "has_backend" => true}} =
             req(ctx, :post, "/v1/comma/workspaces/#{ctx.other.id}/apps/install", ctx.cat, %{
               "token" => token,
               "pinned_version" => 2
             })

    assert %{status: 200, body: %{"data" => [%{"has_backend" => true, "storage" => storage}]}} =
             req(ctx, :get, "/v1/comma/workspaces/#{ctx.other.id}/apps", ctx.cat)

    assert storage == ["app", "user", "device"]
    assert %{status: 200} = req(ctx, :get, other_bundle <> "/2/bundle", ctx.cat)

    # Revoking the link stops the link and removes the Install.
    assert %{status: 200} =
             req(ctx, :delete, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/link", ctx.ann)

    assert %{status: 404} = req(ctx, :get, "/v1/comma/apps/links/#{token}/bundle", ctx.cat)
    assert %{status: 404} = req(ctx, :get, other_bundle <> "/1/bundle", ctx.cat)

    assert %{status: 200, body: %{"data" => []}} =
             req(ctx, :get, "/v1/comma/workspaces/#{ctx.other.id}/apps", ctx.cat)
  end

  test "a disabled app serves no bundle, open or backend call; enabled, the backend call is signed and forwarded",
       ctx do
    app = create_app!(ctx)

    assert {:ok, _} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-v1"),
               files!(ctx.tmp, backend?: true)
             )

    ws = ctx.workspace.id
    via = [{"x-comma-app-via", "workspace/#{ws}"}]
    backend = "/v1/comma/apps/#{app["id"]}/backend/habits/today?day=1"

    assert %{status: 200} =
             req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/disable", ctx.ann)

    assert %{status: 404} =
             req(
               ctx,
               :get,
               "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/versions/1/bundle",
               ctx.ann
             )

    assert %{status: 404} = req(ctx, :post, "/v1/comma/apps/#{app["id"]}/open", ctx.ann, %{}, via)

    assert %{status: 404} =
             raw(ctx, :post, backend, ctx.ann, "hello", via ++ [{"x-comma-app-method", "PUT"}])

    refute_received {:dispatch, _, _, _, _, _}

    assert %{status: 200, body: %{"status" => "active"}} =
             req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/enable", ctx.ann)

    assert %{status: 201, body: "made hello"} =
             raw(
               ctx,
               :post,
               backend,
               ctx.ann,
               "hello",
               via ++
                 [
                   {"x-comma-app-method", "PUT"},
                   {"content-type", "text/plain"}
                 ]
             )

    assert_received {:dispatch, "POST", path, "day=1", headers, "hello"}
    assert path == "/internal/v1/apps/app-#{app["slug"]}-v1/habits/today"
    headers = Map.new(headers)
    assert headers["x-comma-app-method"] == "PUT"
    assert headers["x-comma-app-version"] == "1"
    assert headers["x-comma-app-egress"] == "api.open-meteo.com"
    assert headers["content-type"] == "text/plain"
    assert {:ok, viewer} = Comma.MiniApps.Viewer.id(elem(ctx.ann, 0)["id"], app["id"])
    assert headers["x-comma-viewer"] == viewer

    assert headers["x-salix-signature"] ==
             SalixEnv.VM.Providers.Cloudflare.Client.signature(
               "test-dispatch-secret",
               "POST",
               path <> "?day=1",
               headers["x-salix-timestamp"],
               headers["x-salix-nonce"],
               "hello"
             )

    # The platform takes it down: the owner cannot start it again.
    assert {:ok, %{"status" => "disabled"}} = Comma.MiniApps.platform_disable(app["id"])
    assert_received {:cloudflare, "DELETE", _, _}

    assert %{status: 403} =
             req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/enable", ctx.ann)
  end

  test "Publish is refused before anything changes when the pull request head has no Version",
       ctx do
    app = create_app!(ctx)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))
    {ann, _session} = ctx.ann
    group = ctx.workspace.salix_group_id
    router!(ctx.workspace)
    task_id = build_task!(group, ann, app)
    {:ok, task} = SalixIM.Conversations.get_group_conversation(group, task_id)

    # The agent pushed after its last deploy.
    GitHub.put_pr(%{
      url: "https://github.com/ann/x/pull/7",
      number: 7,
      title: "App",
      body: "",
      head_sha: @other_commit,
      state: "open",
      mergeable: "mergeable",
      checks: nil,
      new_commits: false
    })

    assert %{
             status: 409,
             body: %{
               "error" => "deploy_latest_first",
               "message" => "Deploy the latest changes first"
             }
           } =
             req(
               ctx,
               :post,
               "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}/publish",
               ctx.ann,
               %{
                 "group_id" => group,
                 "conversation_id" => task_id,
                 "review_version" => task["updated_at"],
                 "version" => 1
               }
             )

    refute :merge_method in GitHub.calls()
    {:ok, unchanged} = SalixIM.Conversations.get_group_conversation(group, task_id)
    assert unchanged["status"] == "ready_for_review"

    assert %{"live_version" => nil} =
             Comma.MiniApps.view_one(Comma.MiniApps.get_app(app["id"]), ctx.workspace.id)
  end

  test "storage is per app and per viewer, with version checks and quotas", ctx do
    app = create_app!(ctx)
    other_app = create_app!(ctx, "Second")
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))

    assert {:ok, _} =
             CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, other_app, "key-v1"), files!(ctx.tmp))

    ws = ctx.workspace.id

    for id <- [app["id"], other_app["id"]] do
      req(ctx, :patch, "/v1/comma/workspaces/#{ws}/apps/#{id}", ctx.ann, %{
        "visibility" => "workspace"
      })
    end

    via = [{"x-comma-app-via", "workspace/#{ws}"}]
    storage = fn app_id, rest -> "/v1/comma/apps/#{app_id}/storage/" <> rest end

    assert %{status: 200, body: %{"key" => "habits/a", "value" => %{"n" => 1}, "version" => 1}} =
             req(
               ctx,
               :put,
               storage.(app["id"], "user/habits/a"),
               ctx.ann,
               %{"value" => %{"n" => 1}},
               via
             )

    assert %{status: 200, body: %{"version" => 1}} =
             req(
               ctx,
               :put,
               storage.(app["id"], "app/board"),
               ctx.ann,
               %{"value" => "shared"},
               via
             )

    # Another viewer has their own user scope and shares the app scope.
    assert %{status: 404} =
             req(ctx, :get, storage.(app["id"], "user/habits/a"), ctx.bob, nil, via)

    assert %{status: 200, body: %{"data" => [], "has_more" => false}} =
             req(ctx, :get, storage.(app["id"], "user"), ctx.bob, nil, via)

    assert %{status: 200, body: %{"value" => "shared"}} =
             req(ctx, :get, storage.(app["id"], "app/board"), ctx.bob, nil, via)

    # Another app sees none of it.
    assert %{status: 404} =
             req(ctx, :get, storage.(other_app["id"], "app/board"), ctx.ann, nil, via)

    # A write names the version it read.
    assert %{status: 409, body: %{"error" => "version_conflict"}} =
             req(
               ctx,
               :put,
               storage.(app["id"], "app/board"),
               ctx.bob,
               %{"value" => "x", "if_version" => 0},
               via
             )

    assert %{status: 200, body: %{"version" => 2}} =
             req(
               ctx,
               :put,
               storage.(app["id"], "app/board"),
               ctx.bob,
               %{"value" => "x", "if_version" => 1},
               via
             )

    assert %{status: 200, body: %{"data" => [%{"key" => "habits/a"}], "has_more" => false}} =
             req(ctx, :get, storage.(app["id"], "user?prefix=habits/"), ctx.ann, nil, via)

    # 1 MiB per value; 10 MiB per viewer: ten values of about 1 MB fit, the eleventh does not.
    big = String.duplicate("x", 1_000_000)

    assert %{status: 413, body: %{"error" => "quota_exceeded"}} =
             req(
               ctx,
               :put,
               storage.(app["id"], "user/huge"),
               ctx.ann,
               %{"value" => big <> big},
               via
             )

    for n <- 1..10 do
      assert %{status: 200} =
               req(
                 ctx,
                 :put,
                 storage.(app["id"], "user/big#{n}"),
                 ctx.ann,
                 %{"value" => big},
                 via
               )
    end

    assert %{status: 413, body: %{"error" => "quota_exceeded"}} =
             req(ctx, :put, storage.(app["id"], "user/big11"), ctx.ann, %{"value" => big}, via)

    # Another viewer's quota is their own.
    assert %{status: 200} =
             req(ctx, :put, storage.(app["id"], "user/big1"), ctx.bob, %{"value" => big}, via)

    # Deleting frees the space.
    assert %{status: 200} = req(ctx, :delete, storage.(app["id"], "user/big1"), ctx.ann, nil, via)

    assert %{status: 200} =
             req(ctx, :put, storage.(app["id"], "user/big11"), ctx.ann, %{"value" => big}, via)
  end

  test "decision calls use the AI grant and retain model, billing and archive attribution",
       ctx do
    decision_provider!()
    workspace = router!(ctx.workspace)
    app = create_app!(ctx)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))
    path = "/v1/comma/apps/#{app["id"]}/ai/decide"
    via = [{"x-comma-app-via", "workspace/#{workspace.id}"}]
    grants = "/v1/comma/workspaces/#{workspace.id}/apps/#{app["id"]}/grants"
    args = DecideFixture.args(%{"message" => %{"text" => "meeting decisions"}})

    assert %{status: 403, body: %{"error" => "not_granted"}} =
             req(ctx, :post, path, ctx.ann, args, via)

    refute_received {:decision_request, _, _, _}

    assert %{status: 200} = req(ctx, :put, grants, ctx.ann, %{"grants" => ["ai.chat"]})
    assert %{status: 200, body: result} = req(ctx, :post, path, ctx.ann, args, via)
    assert result["model"] == "jev-fixture-resolved"

    assert result["answers"]["source"] == %{
             "type" => "choice",
             "choice" => "meetings",
             "probabilities_bp" => %{"meetings" => 9000, "none" => 1000},
             "confidence_bp" => 8123
           }

    assert result["answers"]["relevant"] == %{"type" => "noul", "probability_bp" => 9234}
    assert result["answers"]["priority"]["score_milli"] == 800
    assert_received {:decision_request, "/v1/systemone", ["Bearer test-decide-secret"], request}
    assert request == Map.put(args, "model", "jev-fixture")

    {:ok, router} = SalixAgent.Control.get_record(workspace.salix_router_agent_id)
    {:ok, session_id} = SalixStore.RuntimeIds.persisted_router_session_id(router)
    assert_received {:decision_meter_before, before}
    assert before.entrypoint == "mini_app_ai_decide"
    assert before.actor_type == "user"
    assert before.billing_context["billing_account_id"] == workspace.billing_owner_id
    assert before.billing_context["actor_user_id"] == elem(ctx.ann, 0)["id"]
    assert before.billing_context["mini_app_id"] == app["id"]
    assert before.salix_agent_id == workspace.salix_router_agent_id
    assert before.session_id == session_id

    assert_received {:decision_meter_after,
                     %{usage: %{"prompt_tokens" => 123, "completion_tokens" => 7}}}

    assert_received {:decision_archive, %{boundary: :llm_request} = archived}
    assert archived.agent_id == workspace.salix_router_agent_id
    assert archived.session_id == session_id
    assert archived.tenant_id == workspace.salix_tenant_id

    assert archived.payload["options"]["billing_context"]["salix_group_id"] ==
             workspace.salix_group_id

    assert Jason.decode!(archived.payload["request_body"]) == request
    refute Jason.encode!(archived.payload) =~ "test-decide-secret"
    assert_received {:decision_archive, %{boundary: :llm_response} = response}
    assert response.agent_id == archived.agent_id
    assert response.session_id == session_id

    assert %{status: 404} = req(ctx, :post, path, ctx.cat, args, via)
    assert %{status: 200} = req(ctx, :put, grants, ctx.ann, %{"grants" => []})

    assert %{status: 403, body: %{"error" => "not_granted"}} =
             req(ctx, :post, path, ctx.ann, args, via)

    assert {:ok, _} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-v2"),
               files!(ctx.tmp, capabilities: [])
             )

    assert %{status: 200} = req(ctx, :put, grants, ctx.ann, %{"grants" => ["ai.chat"]})

    assert %{status: 403, body: %{"error" => "not_granted"}} =
             req(ctx, :post, path, ctx.ann, args, via ++ [{"x-comma-app-version", "2"}])

    refute_received {:decision_request, _, _, _}
  end

  test "installed decision calls use the viewer Workspace's grant, credits and Router", ctx do
    decision_provider!()
    viewer_workspace = router!(ctx.other)
    app = create_app!(ctx)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))
    owner_path = "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}"
    assert %{status: 200} = req(ctx, :post, owner_path <> "/rollback", ctx.ann, %{"version" => 1})

    assert %{status: 200} =
             req(ctx, :put, owner_path <> "/grants", ctx.ann, %{"grants" => ["ai.chat"]})

    %{body: %{"token" => token}} = req(ctx, :put, owner_path <> "/link", ctx.ann)

    assert %{status: 200} =
             req(ctx, :post, "/v1/comma/workspaces/#{ctx.other.id}/apps/install", ctx.cat, %{
               "token" => token
             })

    path = "/v1/comma/apps/#{app["id"]}/ai/decide"
    via = [{"x-comma-app-via", "workspace/#{ctx.other.id}"}]
    args = DecideFixture.args()

    assert %{status: 403, body: %{"error" => "not_granted"}} =
             req(ctx, :post, path, ctx.cat, args, via)

    assert %{status: 200} =
             req(
               ctx,
               :put,
               "/v1/comma/workspaces/#{ctx.other.id}/apps/#{app["id"]}/grants",
               ctx.cat,
               %{"grants" => ["ai.chat"]}
             )

    set_account_status!(ctx.other, "inactive")

    assert %{status: 402, body: %{"error" => "billing_unavailable"}} =
             req(ctx, :post, path, ctx.cat, args, via)

    refute_received {:decision_request, _, _, _}
    set_account_status!(ctx.other, "active")
    assert %{status: 200} = req(ctx, :post, path, ctx.cat, args, via)
    assert_received {:decision_request, _, _, _}
    assert_received {:decision_meter_before, fact}
    assert fact.billing_context["billing_account_id"] == viewer_workspace.billing_owner_id
    assert fact.billing_context["product_owner_id"] == viewer_workspace.id
    assert fact.billing_context["actor_user_id"] == elem(ctx.cat, 0)["id"]
    assert fact.salix_agent_id == viewer_workspace.salix_router_agent_id
    assert_received {:decision_archive, %{boundary: :llm_request} = archived}
    assert archived.agent_id == viewer_workspace.salix_router_agent_id

    assert archived.payload["options"]["billing_context"]["salix_group_id"] ==
             viewer_workspace.salix_group_id

    SystemsRuntime.put_env(:salix_agent, :decide_test_deny, true)

    assert %{status: 402, body: %{"error" => "billing_unavailable"}} =
             req(ctx, :post, path, ctx.cat, args, via)

    refute_received {:decision_request, _, _, _}
  end

  test "decision requests reject invalid input and return bounded provider errors", ctx do
    decision_provider!()
    app = create_app!(ctx)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))
    path = "/v1/comma/apps/#{app["id"]}/ai/decide"
    via = [{"x-comma-app-via", "workspace/#{ctx.workspace.id}"}]

    assert %{status: 200} =
             req(
               ctx,
               :put,
               "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}/grants",
               ctx.ann,
               %{"grants" => ["ai.chat"]}
             )

    for args <- [
          Map.put(DecideFixture.args(), "model", "app-selected-model"),
          DecideFixture.args(String.duplicate("界", 4096)),
          put_in(DecideFixture.args(), ["questions", "source", "criteria"], %{"only" => "one"})
        ] do
      assert %{status: 400, body: %{"error" => "invalid"}} =
               req(ctx, :post, path, ctx.ann, args, via)
    end

    # A call cannot invent an identity when the Workspace has no Router.
    assert %{status: 503, body: %{"error" => "unavailable"}} =
             req(ctx, :post, path, ctx.ann, DecideFixture.args(), via)

    refute_received {:decision_request, _, _, _}
    router!(ctx.workspace)

    assert %{status: 429, body: %{"error" => "rate_limited"}} =
             req(ctx, :post, path, ctx.ann, DecideFixture.args("rate"), via)

    assert_received {:decision_request, "/v1/systemone", _, %{"state" => "rate"}}

    assert %{status: 503, body: %{"error" => "unavailable"}} =
             req(ctx, :post, path, ctx.ann, DecideFixture.args("unknown"), via)

    assert_received {:decision_request, "/v1/systemone", _, %{"state" => "unknown"}}
    SystemsRuntime.put_env(:salix_agent, :decide, [])

    assert %{status: 503, body: %{"error" => "unavailable"}} =
             req(ctx, :post, path, ctx.ann, DecideFixture.args(), via)

    refute_received {:decision_request, _, _, _}
  end

  test "web search checks grants and scope before it reaches the provider", ctx do
    search_provider!()
    app = create_app!(ctx)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))
    path = "/v1/comma/apps/#{app["id"]}/web/search"
    via = [{"x-comma-app-via", "workspace/#{ctx.workspace.id}"}]
    grants = "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}/grants"

    assert %{status: 403, body: %{"error" => "not_granted"}} =
             req(ctx, :post, path, ctx.ann, %{"query" => "Comma"}, via)

    refute_received {:search, _, _}

    assert %{status: 200} = req(ctx, :put, grants, ctx.ann, %{"grants" => ["web.search"]})

    assert %{status: 200, body: %{"results" => results}} =
             req(ctx, :post, path, ctx.ann, %{"query" => "  Comma  "}, via)

    assert length(results) == 5

    assert hd(results) == %{
             "title" => "Result 1",
             "url" => "https://example.test/1",
             "text" => String.duplicate("x", 1200)
           }

    assert_received {:search,
                     %{
                       "query" => "Comma",
                       "numResults" => 5,
                       "contents" => %{"text" => %{"maxCharacters" => 1500}}
                     }, ["test-exa-key"]}

    # Agent tools use the same provider request and retain their text result.
    assert SalixAgent.Tools.web_search(%{"query" => "Comma"}, %{}) =~
             "### Result 1\nhttps://example.test/1\n"

    assert_received {:search, %{"query" => "Comma"}, ["test-exa-key"]}

    assert %{status: 404} = req(ctx, :post, path, ctx.cat, %{"query" => "Comma"}, via)

    # An Install needs its own Workspace's grant.
    assert %{status: 200} =
             req(
               ctx,
               :post,
               "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}/rollback",
               ctx.ann,
               %{"version" => 1}
             )

    %{body: %{"token" => token}} =
      req(ctx, :put, "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}/link", ctx.ann)

    assert %{status: 200} =
             req(ctx, :post, "/v1/comma/workspaces/#{ctx.other.id}/apps/install", ctx.cat, %{
               "token" => token
             })

    install_via = [{"x-comma-app-via", "workspace/#{ctx.other.id}"}]

    assert %{status: 403, body: %{"error" => "not_granted"}} =
             req(ctx, :post, path, ctx.cat, %{"query" => "Comma"}, install_via)

    refute_received {:search, _, _}

    assert %{status: 200} =
             req(
               ctx,
               :put,
               "/v1/comma/workspaces/#{ctx.other.id}/apps/#{app["id"]}/grants",
               ctx.cat,
               %{"grants" => ["web.search"]}
             )

    assert %{status: 200, body: %{"results" => ^results}} =
             req(ctx, :post, path, ctx.cat, %{"query" => "Comma"}, install_via)

    assert_received {:search, %{"query" => "Comma"}, ["test-exa-key"]}

    for query <- [" ", String.duplicate("x", 2001), nil] do
      assert %{status: 400, body: %{"error" => "invalid"}} =
               req(ctx, :post, path, ctx.ann, %{"query" => query}, via)
    end

    refute_received {:search, _, _}

    assert %{status: 200} = req(ctx, :put, grants, ctx.ann, %{"grants" => []})

    assert %{status: 403, body: %{"error" => "not_granted"}} =
             req(ctx, :post, path, ctx.ann, %{"query" => "Comma"}, via)

    refute_received {:search, _, _}

    # A stored grant cannot add a capability absent from the running Version.
    assert {:ok, _} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-v2"),
               files!(ctx.tmp, capabilities: [])
             )

    assert %{status: 200} = req(ctx, :put, grants, ctx.ann, %{"grants" => ["web.search"]})

    assert %{status: 403, body: %{"error" => "not_granted"}} =
             req(
               ctx,
               :post,
               path,
               ctx.ann,
               %{"query" => "Comma"},
               via ++ [{"x-comma-app-version", "2"}]
             )

    refute_received {:search, _, _}
  end

  test "web search returns a bounded error when the provider fails or is not configured", ctx do
    search_provider!()
    app = create_app!(ctx)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))
    via = [{"x-comma-app-via", "workspace/#{ctx.workspace.id}"}]
    path = "/v1/comma/apps/#{app["id"]}/web/search"

    assert %{status: 200} =
             req(
               ctx,
               :put,
               "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}/grants",
               ctx.ann,
               %{"grants" => ["web.search"]}
             )

    for query <- ["provider failure", "invalid response"] do
      assert %{status: 503, body: %{"error" => "unavailable"}} =
               req(ctx, :post, path, ctx.ann, %{"query" => query}, via)

      assert_received {:search, %{"query" => ^query}, ["test-exa-key"]}
      refute_received {:search, _, _}
    end

    SystemsRuntime.put_env(:salix_agent, :exa_api_key, nil)

    assert %{status: 503, body: %{"error" => "unavailable"}} =
             req(ctx, :post, path, ctx.ann, %{"query" => "Comma"}, via)

    refute_received {:search, _, _}
  end

  test "an owner Workspace out of credit pauses open, backend, storage writes, AI and search until credits return",
       ctx do
    app = create_app!(ctx)

    assert {:ok, _} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-v1"),
               files!(ctx.tmp, backend?: true)
             )

    via = [{"x-comma-app-via", "workspace/#{ctx.workspace.id}"}]

    req(
      ctx,
      :put,
      "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}/grants",
      ctx.ann,
      %{"grants" => ["ai.chat", "web.search"]}
    )

    set_account_status!(ctx.workspace, "inactive")

    assert %{status: 402, body: %{"error" => "app_paused"}} =
             req(
               ctx,
               :post,
               "/v1/comma/apps/#{app["id"]}/ai/decide",
               ctx.ann,
               DecideFixture.args(),
               via
             )

    assert %{status: 402, body: %{"error" => "app_paused"}} =
             req(
               ctx,
               :post,
               "/v1/comma/apps/#{app["id"]}/web/search",
               ctx.ann,
               %{"query" => "Comma"},
               via
             )

    assert %{status: 402, body: %{"error" => "app_paused"}} =
             req(ctx, :post, "/v1/comma/apps/#{app["id"]}/open", ctx.ann, %{}, via)

    assert %{status: 402, body: %{"error" => "app_paused"}} =
             raw(
               ctx,
               :post,
               "/v1/comma/apps/#{app["id"]}/backend/x",
               ctx.ann,
               "",
               via ++ [{"x-comma-app-method", "GET"}]
             )

    assert %{status: 402, body: %{"error" => "app_paused"}} =
             req(
               ctx,
               :put,
               "/v1/comma/apps/#{app["id"]}/storage/user/a",
               ctx.ann,
               %{"value" => 1},
               via
             )

    assert %{status: 402, body: %{"error" => "app_paused"}} =
             req(
               ctx,
               :post,
               "/v1/comma/apps/#{app["id"]}/ai/chat",
               ctx.ann,
               %{
                 "messages" => [%{"role" => "user", "content" => "hi"}]
               },
               via
             )

    # Reads that change nothing still answer; nothing was deleted.
    assert %{status: 200} =
             req(ctx, :get, "/v1/comma/apps/#{app["id"]}/storage/user", ctx.ann, nil, via)

    set_account_status!(ctx.workspace, "active")

    assert %{
             status: 200,
             body: %{"version" => 1, "guest" => false, "viewer" => %{"id" => viewer}}
           } =
             req(ctx, :post, "/v1/comma/apps/#{app["id"]}/open", ctx.ann, %{}, via)

    assert byte_size(viewer) == 22
  end

  test "a guest runs a link app and nothing else; AI and web search ask it to sign up", ctx do
    app = create_app!(ctx)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))
    ws = ctx.workspace.id

    req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/rollback", ctx.ann, %{
      "version" => 1
    })

    %{body: %{"token" => token}} =
      req(ctx, :put, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/link", ctx.ann)

    guest = guest!()
    link_via = [{"x-comma-app-via", "link/" <> token}]

    assert %{status: 403, body: %{"error" => "signup_required"}} =
             req(
               ctx,
               :post,
               "/v1/comma/apps/#{app["id"]}/ai/decide",
               guest,
               DecideFixture.args(),
               link_via
             )

    assert %{status: 403, body: %{"error" => "signup_required"}} =
             req(
               ctx,
               :post,
               "/v1/comma/apps/#{app["id"]}/web/search",
               guest,
               %{"query" => "Comma"},
               link_via
             )

    assert %{status: 200} = req(ctx, :get, "/v1/comma/apps/links/#{token}", guest)
    assert %{status: 200} = req(ctx, :get, "/v1/comma/apps/links/#{token}/bundle", guest)

    assert %{status: 200, body: %{"guest" => true, "viewer" => %{"name" => "Guest"}}} =
             req(ctx, :post, "/v1/comma/apps/#{app["id"]}/open", guest, %{}, link_via)

    assert %{status: 200} =
             req(
               ctx,
               :put,
               "/v1/comma/apps/#{app["id"]}/storage/user/note",
               guest,
               %{"value" => "mine"},
               link_via
             )

    assert %{status: 403, body: %{"error" => "signup_required"}} =
             req(
               ctx,
               :post,
               "/v1/comma/apps/#{app["id"]}/ai/chat",
               guest,
               %{
                 "messages" => [%{"role" => "user", "content" => "hi"}]
               },
               link_via
             )

    # Not through a Workspace, and no list, create, install or remix.
    assert %{status: 403, body: %{"error" => "guest_signup_required"}} =
             req(ctx, :post, "/v1/comma/apps/#{app["id"]}/open", guest, %{}, [
               {"x-comma-app-via", "workspace/#{ws}"}
             ])

    for {method, path, body} <- [
          {:get, "/v1/comma/workspaces/#{ws}/apps", nil},
          {:post, "/v1/comma/workspaces/#{ws}/apps", %{"name" => "Mine"}},
          {:post, "/v1/comma/workspaces/#{ws}/apps/install", %{"token" => token}},
          {:post, "/v1/comma/workspaces/#{ws}/apps/remix", %{"token" => token}}
        ] do
      assert %{status: 403, body: %{"error" => "guest_signup_required"}} =
               req(ctx, method, path, guest, body)
    end
  end

  test "a Router's app comes with the URL that runs it for a member, the latest preview before Publish",
       ctx do
    ws = ctx.workspace.id

    assert {:ok, %{"app_id" => app_id, "repo" => repo, "url" => url}} =
             CommaWeb.MiniAppPort.create(
               %{group_id: ctx.workspace.salix_group_id},
               %{"name" => "Habit tracker"}
             )

    assert url == "http://127.0.0.1:5174/#/apps/#{ws}/#{app_id}/run"

    # The page's open call (no Version asked): nothing to run before the first deploy.
    via = [{"x-comma-app-via", "workspace/#{ws}"}]
    assert %{status: 404} = req(ctx, :post, "/v1/comma/apps/#{app_id}/open", ctx.ann, %{}, via)

    app = %{"id" => app_id, "repo" => repo}
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))

    assert %{status: 200, body: %{"version" => 1, "app" => %{"live_version" => nil}}} =
             req(ctx, :post, "/v1/comma/apps/#{app_id}/open", ctx.ann, %{}, via)
  end

  test "a Router lists and reads its Workspace's apps with their URLs, but not a member's private app",
       ctx do
    group = ctx.workspace.salix_group_id

    assert {:ok, %{"app_id" => app_id, "repo" => repo, "url" => url}} =
             CommaWeb.MiniAppPort.create(%{group_id: group}, %{"name" => "Habit tracker"})

    mine = create_app!(ctx, "Ann's own")
    app = %{"id" => app_id, "repo" => repo}
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))

    assert {:ok, %{"apps" => [listed], "has_more" => false}} = CommaWeb.MiniAppPort.list(group)

    assert %{
             "app_id" => ^app_id,
             "name" => "Habit tracker",
             "url" => ^url,
             "latest_version" => 1,
             "live_version" => nil,
             "status" => "active"
           } = listed

    assert {:ok, detail} = CommaWeb.MiniAppPort.get(group, app_id)
    assert Map.drop(detail, ["versions"]) == listed
    assert [%{"number" => 1, "state" => "ready"}] = detail["versions"]
    assert {:error, :not_found} = CommaWeb.MiniAppPort.get(group, mine["id"])

    # Shared with the Workspace, a member's app is the Router's to name too.
    assert %{status: 200} =
             req(
               ctx,
               :patch,
               "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{mine["id"]}",
               ctx.ann,
               %{
                 "visibility" => "workspace"
               }
             )

    assert {:ok, %{"apps" => [_, _]}} = CommaWeb.MiniAppPort.list(group)
    assert {:ok, %{"app_id" => _}} = CommaWeb.MiniAppPort.get(group, mine["id"])
  end

  test "an app's Comma URL in a Telegram message gets a button that opens the app inside Telegram",
       ctx do
    group = ctx.workspace.salix_group_id
    ws = ctx.workspace.id

    assert {:ok, %{"app_id" => app_id, "url" => url}} =
             CommaWeb.MiniAppPort.create(%{group_id: group}, %{"name" => "Habit tracker"})

    mine = create_app!(ctx, "Ann's own")

    origin =
      SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin) |> String.trim_trailing("/")

    text =
      "Open it here: #{url}\nAgain: #{url}\nA private one: #{origin}/#/apps/#{ws}/#{mine["id"]}/run" <>
        "\nAnother Workspace's: #{origin}/#/apps/other-ws/#{app_id}/run"

    assert [%{"text" => "▶️ Habit tracker", "web_app" => %{"url" => button_url}}] =
             CommaWeb.MiniAppPort.telegram_buttons(group, text)

    assert %URI{path: "/task-panel.html", query: query} = URI.parse(button_url)
    assert String.starts_with?(button_url, origin <> "/")

    assert URI.decode_query(query) == %{
             "workspace_id" => ws,
             "group_id" => group,
             "app_id" => app_id,
             "source" => "telegram"
           }

    assert CommaWeb.MiniAppPort.telegram_buttons(group, "No app here.") == []
    assert CommaWeb.MiniAppPort.telegram_buttons("unknown-group", text) == []
  end

  test "an app made from an existing repository needs its manifest; delete removes it everywhere",
       ctx do
    ws = ctx.workspace.id

    assert %{status: 404, body: %{"error" => "repo_not_found"}} =
             req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps", ctx.ann, %{
               "name" => "Mine",
               "repo" => %{"owner" => "acme", "name" => "no-manifest"}
             })

    assert %{status: 201, body: %{"repo" => %{"owner" => "acme", "name" => "has-manifest"}} = app} =
             req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps", ctx.ann, %{
               "name" => "Mine",
               "repo" => %{"owner" => "acme", "name" => "has-manifest"}
             })

    # A read-only member makes no app.
    {viewer, viewer_session} = user!()
    member!(ctx.workspace, viewer, "viewer")

    assert %{status: 403} =
             req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps", {viewer, viewer_session}, %{
               "name" => "No"
             })

    assert {:ok, _} =
             CommaWeb.MiniAppPort.deploy(
               %{
                 deploy_ctx(ctx, app, "key-v1")
                 | repo: %{"owner" => "ACME", "name" => "Has-Manifest"}
               },
               files!(ctx.tmp, backend?: true)
             )

    assert %{status: 200, body: %{"status" => "deleted"}} =
             req(ctx, :delete, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}", ctx.ann)

    assert %{status: 404} =
             req(ctx, :get, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}", ctx.ann)

    assert {:ok, [_ | _]} =
             SalixStore.S3.list_all("miniapps/apps/#{app["id"]}/") |> then(&{:ok, elem(&1, 1)})

    assert :done = Comma.MiniApps.cleanup(app["id"])
    assert_received {:cloudflare, "DELETE", script, _}
    assert script =~ "-v1"
    assert {:ok, []} = SalixStore.S3.list_all("miniapps/apps/#{app["id"]}/")
    assert Repo.get(Comma.MiniApps.App, app["id"]) == nil
    # The repository stays: nothing asked GitHub to delete it.
    refute Enum.any?(GitHub.calls(), &match?({:delete_repo, _}, &1))
  end

  test "guest route allowlist admits only link app calls" do
    alias CommaWeb.GuestRoutes

    assert GuestRoutes.allowed?("GET", "/v1/comma/apps/links/tok")
    assert GuestRoutes.allowed?("GET", "/v1/comma/apps/links/tok/bundle")
    assert GuestRoutes.link_app_call?("POST", "/v1/comma/apps/a1/backend/x/y", "link/tok")
    assert GuestRoutes.link_app_call?("PUT", "/v1/comma/apps/a1/storage/user/k/2", "link/tok")
    refute GuestRoutes.link_app_call?("POST", "/v1/comma/apps/a1/backend/x", "workspace/w")
    refute GuestRoutes.link_app_call?("POST", "/v1/comma/apps/a1/backend/x", nil)
    refute GuestRoutes.link_app_call?("POST", "/v1/comma/workspaces/w/apps/install", "link/tok")
    refute GuestRoutes.allowed?("GET", "/v1/comma/workspaces/w/apps")
  end

  test "Publish opens the Task's pull request, accepts the review, merges at the Version and moves live; after a refused merge a retry finishes",
       ctx do
    app = create_app!(ctx)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))
    {ann, _session} = ctx.ann
    group = ctx.workspace.salix_group_id
    router!(ctx.workspace)
    task_id = build_task!(group, ann, app)
    {:ok, task} = SalixIM.Conversations.get_group_conversation(group, task_id)
    assert task["mini_app"] == %{"app_id" => app["id"]}
    assert task["status"] == "ready_for_review"
    # The agent pushed and deployed; the branch has no pull request.
    GitHub.put_pr(nil)

    GitHub.refuse({:github, 405, "Required status check \"build\" is failing."})
    publish = "/v1/comma/workspaces/#{ctx.workspace.id}/apps/#{app["id"]}/publish"

    body = %{
      "group_id" => group,
      "conversation_id" => task_id,
      "review_version" => task["updated_at"],
      "version" => 1,
      "visibility" => "workspace"
    }

    # GitHub refuses the merge: nothing goes live, and the card shows why.
    assert %{status: 422, body: %{"error" => "github_refused", "message" => message}} =
             req(ctx, :post, publish, ctx.ann, body)

    assert message =~ "status check"
    assert {:create_pr, "main", "Build the app"} in GitHub.calls()
    view = fn -> Comma.MiniApps.view_one(Comma.MiniApps.get_app(app["id"]), ctx.workspace.id) end
    assert %{"live_version" => nil, "visibility" => "private"} = view.()
    {:ok, accepted} = SalixIM.Conversations.get_group_conversation(group, task_id)
    assert accepted["status"] == "completed"

    # The retry does not accept again (its review version is stale now); it merges and goes live.
    GitHub.refuse(nil)

    assert %{status: 200, body: %{"live_version" => 1, "visibility" => "workspace"}} =
             req(ctx, :post, publish, ctx.ann, body)

    assert {:merge, 7, "squash", @branch_head} in GitHub.calls()
    # The retry merges the pull request the first Publish opened.
    assert Enum.count(GitHub.calls(), &match?({:create_pr, _, _}, &1)) == 1
  end

  test "the Router publishes through Task review and GitHub, preserves live on failure and can retry",
       ctx do
    workspace = router!(ctx.workspace)
    {ann, _} = ctx.ann

    assert {:ok, created} = app_api(workspace, "create", %{"name" => "Habit tracker"})
    app = %{"id" => created["app_id"], "repo" => created["repo"]}
    id = app["id"]
    task_id = build_task!(workspace.salix_group_id, ann, app)
    deploy = Map.put(deploy_ctx(ctx, app, "router-v1"), :conversation_id, task_id)
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy, files!(ctx.tmp))

    assert {:ok, detail} = app_api(workspace, "get", %{"app_id" => id})
    assert [%{"number" => 1, "conversation_id" => ^task_id}] = detail["versions"]
    params = %{"app_id" => id, "version" => 1, "visibility" => "workspace"}

    # An undeployed head is refused before review acceptance.
    GitHub.put_pr(%{
      url: "https://github.com/ann/x/pull/7",
      number: 7,
      title: "App",
      body: "",
      head_sha: @other_commit,
      state: "open",
      mergeable: "mergeable",
      checks: nil,
      new_commits: false
    })

    assert {:error, message} = app_api(workspace, "publish", params)
    assert message =~ "Deploy the latest changes first"

    assert {:ok, %{"status" => "ready_for_review"}} =
             SalixIM.Conversations.get_group_conversation(workspace.salix_group_id, task_id)

    refute :merge_method in GitHub.calls()

    # A missing pull request is opened. A failed merge leaves the app unpublished.
    GitHub.put_pr(nil)
    GitHub.refuse({:github, 405, "Required status check is failing."})
    assert {:error, message} = app_api(workspace, "publish", params)
    assert message =~ "Required status check"
    assert {:ok, %{"live_version" => nil}} = app_api(workspace, "get", %{"app_id" => id})

    assert {:ok, %{"status" => "completed"}} =
             SalixIM.Conversations.get_group_conversation(workspace.salix_group_id, task_id)

    GitHub.refuse(nil)

    assert {:ok, %{"live_version" => 1, "visibility" => "workspace"}} =
             app_api(workspace, "publish", params)

    assert {:merge, 7, "squash", @branch_head} in GitHub.calls()
    assert Enum.count(GitHub.calls(), &match?({:create_pr, _, _}, &1)) == 1

    assert %{status: 200, body: %{"version" => 1}} =
             req(ctx, :post, "/v1/comma/apps/#{id}/open", ctx.ann, %{}, [
               {"x-comma-app-via", "workspace/#{workspace.id}"}
             ])
  end

  test "the Router manages settings, sharing, installed apps, secrets and the app lifecycle",
       ctx do
    workspace = router!(ctx.workspace)
    viewer = router!(ctx.other)
    assert {:ok, created} = app_api(workspace, "create", %{"name" => "Habit tracker"})
    id = created["app_id"]
    app = %{"id" => id, "repo" => created["repo"]}
    target = %{"app_id" => id}
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "v1"), files!(ctx.tmp))
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "v2"), files!(ctx.tmp))

    assert {:ok, %{"name" => "Daily habits", "description" => "Track habits"}} =
             app_api(
               workspace,
               "update",
               Map.merge(target, %{"name" => "Daily habits", "description" => "Track habits"})
             )

    assert {:ok, %{"live_version" => 2}} =
             app_api(workspace, "rollback", Map.put(target, "version", 2))

    assert {:ok, %{"live_version" => 1}} =
             app_api(workspace, "rollback", Map.put(target, "version", 1))

    assert {:ok, %{"grants" => ["ai.chat"]}} =
             app_api(workspace, "grants.set", Map.put(target, "grants", ["ai.chat"]))

    assert {:ok, %{"secrets" => ["API_KEY"]}} =
             app_api(
               workspace,
               "secrets.set",
               Map.merge(target, %{"name" => "API_KEY", "value" => "test-secret"})
             )

    assert {:ok, %{"secrets" => ["API_KEY"]} = detail} = app_api(workspace, "get", target)
    refute Jason.encode!(detail) =~ "test-secret"
    refute Comma.MiniApps.get_app(id).secrets["API_KEY"] == "test-secret"

    assert {:ok, %{"secrets" => []}} =
             app_api(workspace, "secrets.delete", Map.put(target, "name", "API_KEY"))

    assert {:ok, %{"link" => nil}} = app_api(workspace, "link.get", target)
    assert {:ok, %{"token" => token} = link} = app_api(workspace, "link.create", target)
    assert {:ok, ^link} = app_api(workspace, "link.get", target)

    assert {:ok, %{"installed" => true, "install" => %{"pinned_version" => 1}}} =
             app_api(viewer, "install", %{"token" => token, "pinned_version" => 1})

    assert {:ok, %{"apps" => [%{"app_id" => ^id, "installed" => true}], "has_more" => false}} =
             app_api(viewer, "list", %{})

    assert {:ok, %{"versions" => [], "secrets" => []}} = app_api(viewer, "get", target)

    assert {:ok, %{"grants" => ["web.search"]}} =
             app_api(viewer, "grants.set", Map.put(target, "grants", ["web.search"]))

    assert {:ok, %{"grants" => ["ai.chat"]}} = app_api(workspace, "get", target)
    assert {:error, _} = app_api(viewer, "delete", target)

    assert {:ok, %{"status" => "reported"}} =
             app_api(viewer, "report", Map.put(target, "reason", "Test report"))

    assert {:ok, %{"status" => "removed"}} = app_api(viewer, "uninstall", target)
    assert {:ok, %{"apps" => []}} = app_api(viewer, "list", %{})

    assert {:ok, _} = app_api(viewer, "install", %{"token" => token})
    assert {:ok, %{"token" => replacement}} = app_api(workspace, "link.reset", target)
    refute replacement == token
    assert {:error, _} = app_api(viewer, "install", %{"token" => token})
    assert {:ok, %{"apps" => []}} = app_api(viewer, "list", %{})
    assert {:ok, _} = app_api(viewer, "install", %{"token" => replacement})
    assert {:ok, %{"link" => nil}} = app_api(workspace, "link.revoke", target)
    assert {:ok, %{"apps" => []}} = app_api(viewer, "list", %{})
    assert {:error, _} = app_api(viewer, "install", %{"token" => replacement})

    assert {:ok, %{"status" => "disabled"}} = app_api(workspace, "disable", target)

    assert %{status: 404} =
             req(ctx, :post, "/v1/comma/apps/#{id}/open", ctx.ann, %{}, [
               {"x-comma-app-via", "workspace/#{workspace.id}"}
             ])

    assert {:ok, %{"status" => "active", "live_version" => 1}} =
             app_api(workspace, "enable", target)

    assert {:ok, _} = Comma.MiniApps.platform_disable(id)
    assert {:error, _} = app_api(workspace, "enable", target)
    assert {:ok, %{"status" => "deleted"}} = app_api(workspace, "delete", target)
    assert {:error, _} = app_api(workspace, "get", target)

    assert %{status: 404} =
             req(ctx, :get, "/v1/comma/workspaces/#{workspace.id}/apps/#{id}", ctx.ann)
  end

  test "Router management rejects private apps, foreign apps, stale authority and invalid inputs",
       ctx do
    workspace = router!(ctx.workspace)
    other = router!(ctx.other)
    private = create_app!(ctx)
    target = %{"app_id" => private["id"]}
    assert {:error, _} = app_api(workspace, "update", Map.put(target, "name", "Hidden"))
    assert {:error, _} = app_api(other, "delete", target)

    assert {:ok, created} = app_api(workspace, "create", %{"name" => "Shared"})
    target = %{"app_id" => created["app_id"]}
    assert {:error, _} = app_api(workspace, "publish", Map.put(target, "version", "1"))

    assert {:error, _} =
             app_api(
               workspace,
               "publish",
               Map.merge(target, %{"version" => 1, "visibility" => "public"})
             )

    assert {:error, _} = app_api(workspace, "delete", Map.put(target, "workspace_id", other.id))

    assert {:error, _} =
             app_api(workspace, "delete", Map.put(target, "user_id", elem(ctx.ann, 0)["id"]))

    assert {:error, _} =
             app_api(
               workspace,
               "secrets.set",
               Map.merge(target, %{"name" => "API_KEY", "value" => nil})
             )

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        workspace.salix_tenant_id,
        workspace.salix_group_id,
        %{"name" => "Worker", "role" => "worker"}
      )

    assert {:error, "operation is not authorized for this agent role"} =
             SalixIM.Provider.call_api(worker["agent_id"], "internal", "internal.apps.delete", %{
               "connect_id" => "internal",
               "params" => target
             })

    # The product resolves current account, membership and Router binding on every write.
    {ann, _} = ctx.ann

    from(u in Comma.Accounts.User, where: u.id == ^ann["id"])
    |> Repo.update_all(set: [status: "disabled"])

    assert {:error, _} = app_api(workspace, "delete", target)

    from(u in Comma.Accounts.User, where: u.id == ^ann["id"])
    |> Repo.update_all(set: [status: "active"])

    from(m in WorkspaceMembership,
      where: m.workspace_id == ^workspace.id and m.user_id == ^ann["id"]
    )
    |> Repo.update_all(set: [role: "viewer"])

    assert {:error, _} = app_api(workspace, "delete", target)

    from(m in WorkspaceMembership,
      where: m.workspace_id == ^workspace.id and m.user_id == ^ann["id"]
    )
    |> Repo.update_all(set: [role: "owner"])

    Repo.update!(Ecto.Changeset.change(workspace, salix_router_agent_id: worker["agent_id"]))
    assert {:error, _} = app_api(workspace, "delete", target)
    assert %{status: "active", name: "Shared"} = Comma.MiniApps.get_app(created["app_id"])
  end

  test "drive.app_folder reaches only the app folder of the viewer Workspace's Drive", ctx do
    start_supervised!(Drive)
    SystemsRuntime.put_env(:salix_agent, :drive_mod, Drive)
    on_exit(fn -> SystemsRuntime.delete_env(:salix_agent, :drive_mod) end)

    app = create_app!(ctx)
    ws = ctx.workspace.id
    group = ctx.workspace.salix_group_id
    assert {:ok, _} = CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))
    via = [{"x-comma-app-via", "workspace/#{ws}"}]
    drive = "/v1/comma/apps/#{app["id"]}/drive"

    # Not granted yet.
    assert %{status: 403, body: %{"error" => "not_granted"}} =
             req(ctx, :get, drive <> "?path=", ctx.ann, nil, via)

    req(ctx, :put, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/grants", ctx.ann, %{
      "grants" => ["drive.app_folder"]
    })

    assert %{status: 200, body: %{"status" => "ok"}} =
             raw(
               ctx,
               :put,
               drive <> "/file?path=notes/a.txt",
               ctx.ann,
               "hello",
               via ++ [{"content-type", "text/plain"}]
             )

    assert Drive.files() == %{{group, "Apps/Habit tracker/notes/a.txt"} => "hello"}

    assert %{
             status: 200,
             body: %{"data" => [%{"name" => "a.txt", "kind" => "file", "size" => 5}]}
           } =
             req(ctx, :get, drive <> "?path=notes", ctx.ann, nil, via)

    assert %{status: 200, body: "hello"} =
             req(ctx, :get, drive <> "/file?path=notes/a.txt", ctx.ann, nil, via)

    # Nothing outside the folder.
    for path <- ["../secret.txt", "notes/../../x", "/etc/passwd", "a%5Cb", "a%01b"] do
      assert %{status: 400, body: %{"error" => "invalid"}} =
               req(ctx, :get, drive <> "/file?path=" <> path, ctx.ann, nil, via)
    end

    assert %{status: 200, body: %{"status" => "deleted"}} =
             req(ctx, :delete, drive <> "/file?path=notes/a.txt", ctx.ann, nil, via)

    assert Drive.files() == %{}

    # A link viewer has no Drive.
    req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/rollback", ctx.ann, %{
      "version" => 1
    })

    %{body: %{"token" => token}} =
      req(ctx, :put, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/link", ctx.ann)

    assert %{status: 403, body: %{"error" => "unsupported"}} =
             req(ctx, :get, drive <> "?path=", ctx.cat, nil, [
               {"x-comma-app-via", "link/" <> token}
             ])

    # Without a Drive binding.
    SystemsRuntime.delete_env(:salix_agent, :drive_mod)

    assert %{status: 503, body: %{"error" => "unavailable"}} =
             req(ctx, :get, drive <> "?path=", ctx.ann, nil, via)
  end

  for caller <- [:user, :agent] do
    @remix_caller caller
    test "#{caller} remix makes a new app and repository from the shared source and starts its Coding Task",
         ctx do
      put_envs!([
        {:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery},
        {:salix_im, :session_activity_mod, SalixIM.TestSupport.SessionActivity},
        {:salix_im, :task_stations_mod, Stations},
        {:salix_im, :task_create_mod, Places}
      ])

      # The remixing Workspace's Group has a Router and a Worker.
      tenant = ctx.other.salix_tenant_id
      other_group = ctx.other.salix_group_id

      other = router!(ctx.other)

      worker =
        SalixAgent.TestSupport.create_control_agent_in_group!(tenant, other_group, %{
          "name" => "Worker",
          "role" => "worker"
        })

      put_envs!([{:comma_web, :mini_app_test_worker, worker["agent_id"]}])

      app = create_app!(ctx)
      ws = ctx.workspace.id

      assert {:ok, _} =
               CommaWeb.MiniAppPort.deploy(deploy_ctx(ctx, app, "key-v1"), files!(ctx.tmp))

      req(ctx, :post, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/rollback", ctx.ann, %{
        "version" => 1
      })

      %{body: %{"token" => token}} =
        req(ctx, :put, "/v1/comma/workspaces/#{ws}/apps/#{app["id"]}/link", ctx.ann)

      result =
        case @remix_caller do
          :agent ->
            assert {:ok, result} = app_api(other, "remix", %{"token" => token})

            assert {:ok, %{"versions" => []}} =
                     app_api(other, "get", %{"app_id" => result["app"]["id"]})

            result

          :user ->
            assert %{status: 201, body: result} =
                     req(ctx, :post, "/v1/comma/workspaces/#{other.id}/apps/remix", ctx.cat, %{
                       "token" => token
                     })

            result
        end

      %{"app" => remix, "task" => %{"group_id" => group, "conversation_id" => task_id}} = result

      assert remix["workspace_id"] == ctx.other.id
      assert remix["name"] == "Habit tracker"
      refute remix["id"] == app["id"]
      assert remix["repo"] == %{"owner" => "ann", "name" => "comma-app-" <> remix["slug"]}
      assert {:create_repo, repo_name, ["README.md"]} = List.last(GitHub.calls())
      assert repo_name == remix["repo"]["name"]

      assert group == ctx.other.salix_group_id
      {:ok, task} = SalixIM.Conversations.get_group_conversation(group, task_id)
      assert task["mini_app"] == %{"app_id" => remix["id"]}
      assert task["runs_on"]["kind"] == "sandbox"
      assert task["repo"]["name"] == repo_name

      # A guest cannot remix.
      guest = guest!()

      assert %{status: 403, body: %{"error" => "guest_signup_required"}} =
               req(ctx, :post, "/v1/comma/workspaces/#{ctx.other.id}/apps/remix", guest, %{
                 "token" => token
               })
    end
  end

  test "a Workspace's apps are swept before the Workspace row can go", ctx do
    app = create_app!(ctx)

    assert {:ok, _} =
             CommaWeb.MiniAppPort.deploy(
               deploy_ctx(ctx, app, "key-v1"),
               files!(ctx.tmp, backend?: true)
             )

    workspace = Repo.get!(Workspace, ctx.workspace.id)

    # The row cannot cascade the app away.
    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn -> Repo.delete!(workspace) end)
    end

    assert {:ok, 1} = Comma.MiniApps.delete_workspace_apps(workspace.id)
    assert Comma.MiniApps.get_app(app["id"]) == nil

    assert :ok = Comma.Workers.MiniAppCleanup.perform(%Oban.Job{args: %{}})
    assert_received {:cloudflare, "DELETE", script, _}
    assert script =~ "app-#{app["slug"]}-v1"
    assert {:ok, []} = SalixStore.S3.list_all("miniapps/apps/#{app["id"]}/")
    assert Repo.get(Comma.MiniApps.App, app["id"]) == nil
    assert {:ok, _} = Repo.transaction(fn -> Repo.delete!(workspace) end)
  end

  ## Fixtures

  defp search_provider! do
    test = self()

    plug = fn conn, _opts ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test, {:search, body, Plug.Conn.get_req_header(conn, "x-api-key")})

      {status, response} =
        case body["query"] do
          "provider failure" ->
            {503, %{"error" => "private provider detail"}}

          "invalid response" ->
            {200, %{"results" => [%{"url" => 42}]}}

          _ ->
            {200,
             %{
               "results" =>
                 for(
                   n <- 1..7,
                   do: %{
                     "title" => "Result #{n}",
                     "url" => "https://example.test/#{n}",
                     "text" => String.duplicate("x", 1500),
                     "provider_metadata" => "private"
                   }
                 )
             }}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(response))
    end

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: :search_provider
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    put_envs!([
      {:salix_agent, :exa_base_url, "http://127.0.0.1:#{port}"},
      {:salix_agent, :exa_api_key, "test-exa-key"}
    ])
  end

  defp decision_provider! do
    server =
      start_supervised!(
        {Bandit, plug: {DecideFixture, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: :decision_provider
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    put_envs!([
      {:salix_agent, :decide,
       [
         endpoint: "http://127.0.0.1:#{port}/v1/systemone",
         api_key: "test-decide-secret",
         model: "jev-fixture"
       ]},
      {:salix_agent, :llm_metering_mod, DecideFixture.Meter},
      {:salix_agent, :event_archive_mod, DecideFixture.Archive},
      {:salix_agent, :decide_test_pid, self()},
      {:salix_agent, :decide_test_deny, false}
    ])
  end

  defp put_envs!(entries) do
    previous = for {app, key, _} <- entries, do: {app, key, SystemsRuntime.get_env(app, key)}
    Enum.each(entries, fn {app, key, value} -> SystemsRuntime.put_env(app, key, value) end)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      Enum.each(previous, fn
        {app, key, nil} -> SystemsRuntime.delete_env(app, key)
        {app, key, value} -> SystemsRuntime.put_env(app, key, value)
      end)
    end)
  end

  # The Workspace's Group gets its Router, so the product's Task paths
  # (`Comma.Conversations`) resolve the Workspace scope.
  defp router!(%Workspace{} = workspace) do
    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        workspace.salix_tenant_id,
        workspace.salix_group_id,
        %{"name" => "Router", "role" => "router"}
      )

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(workspace.salix_group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    workspace
    |> Ecto.Changeset.change(salix_router_agent_id: router["agent_id"])
    |> Repo.update!()
  end

  # A coding Task of the app waiting for review.
  defp build_task!(group, user, app) do
    {:ok, task} =
      SalixIM.ConversationServer.create_group_conversation(group, %{
        "kind" => "agent_task",
        "title" => "Build the app",
        "runs_on" => %{"kind" => "sandbox"},
        "repo" => %{
          "owner" => app["repo"]["owner"],
          "name" => app["repo"]["name"],
          "base_ref" => "main",
          "branch" => "comma/app"
        },
        "mini_app" => %{"app_id" => app["id"]}
      })

    id = task["conversation_id"]

    {:ok, _participant} =
      SalixIM.ConversationServer.ensure_group_conversation_user_participant(group, id, %{
        "user_id" => user["id"],
        "state" => "active",
        "notification_filter" => %{"messages" => "none", "statuses" => "none"}
      })

    {:ok, _} =
      SalixIM.ConversationServer.update_group_conversation(group, id, %{
        "status" => "ready_for_review"
      })

    id
  end

  defp create_app!(ctx, name \\ "Habit tracker") do
    assert %{status: 201, body: app} =
             req(ctx, :post, "/v1/comma/workspaces/#{ctx.workspace.id}/apps", ctx.ann, %{
               "name" => name
             })

    assert app["repo"] == %{"owner" => "ann", "name" => "comma-app-" <> app["slug"]}
    assert {:generate, "AFK-surf/comma-app-template", "ann", repo} = List.last(GitHub.calls())
    assert repo == app["repo"]["name"]
    app
  end

  defp app_api(workspace, action, params) do
    SystemsRuntime.put_env(:salix_im, :mini_apps, CommaWeb.MiniAppPort)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)

    ctx =
      %{
        agent_id: workspace.salix_router_agent_id,
        tenant_id: workspace.salix_tenant_id,
        group_id: workspace.salix_group_id,
        session_id:
          SalixStore.RuntimeIds.persisted_router_session_id(workspace.salix_router_agent_id),
        role: "router",
        runtime_kind: :internal,
        llm_tool_envelope: true
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
      )

    call = %{
      "id" => "mini-app-#{SystemsRuntime.Proc.unique_integer([:positive])}",
      "name" => "call",
      "args" => %{
        "tool" => "im_api.internal.apps." <> action,
        "params" => Map.put(params, "connect_id", "internal")
      }
    }

    [result] = SalixAgent.Tools.execute([call], ctx)

    cond do
      result.error -> {:error, result.error_message}
      result.status == "guidance" -> {:error, Jason.decode!(result.content)["error"]}
      true -> {:ok, Jason.decode!(result.content)}
    end
  end

  defp deploy_ctx(ctx, app, key, commit \\ @branch_head) do
    %{
      tenant_id: ctx.workspace.salix_tenant_id,
      group_id: ctx.workspace.salix_group_id,
      conversation_id: "conv_build",
      agent_id: "agent",
      app_id: app["id"],
      key: key,
      commit: commit,
      notes: "first",
      branch: "comma/app",
      repo: app["repo"]
    }
  end

  defp files!(dir, opts \\ []) do
    id = SystemsRuntime.Proc.unique_integer([:positive])
    bundle = Path.join(dir, "bundle-#{id}.tar")
    source = Path.join(dir, "source-#{id}.tar.gz")
    worker = Path.join(dir, "worker-#{id}.js")

    cover = opts[:cover]

    :ok =
      :erl_tar.create(
        String.to_charlist(bundle),
        [
          {~c"index.html", "<!doctype html><div id=app></div>"},
          {~c"icon.png", <<137, 80, 78, 71>>}
        ] ++ if(cover, do: [{String.to_charlist(elem(cover, 0)), elem(cover, 1)}], else: [])
      )

    :ok = :erl_tar.create(String.to_charlist(source), [{~c"README.md", "hi"}], [:compressed])
    File.write!(worker, "export default { fetch() { return new Response('ok') } }")

    manifest =
      %{
        "name" => "Habit tracker",
        "icon" => "icon.png",
        "capabilities" =>
          Keyword.get(opts, :capabilities, [
            "identity.basic",
            "ai.chat",
            "web.search",
            "drive.app_folder"
          ]),
        "storage" => ["app", "user", "device"]
      }
      |> then(fn m -> if cover, do: Map.put(m, "cover", elem(cover, 0)), else: m end)
      |> then(fn m ->
        if opts[:backend?],
          do:
            Map.put(m, "backend", %{
              "entry" => "worker/index.ts",
              "egress" => ["api.open-meteo.com"]
            }),
          else: m
      end)

    files = %{bundle: %{path: bundle}, source: %{path: source}, manifest: Jason.encode!(manifest)}
    if opts[:backend?], do: Map.put(files, :worker, %{path: worker}), else: files
  end

  defp user! do
    {:ok, user} =
      Accounts.create_user(%{
        "email" => "mini-app-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    {user, session}
  end

  defp guest! do
    {user, session} = user!()

    from(u in Comma.Accounts.User, where: u.id == ^user["id"])
    |> Repo.update_all(
      set: [kind: "guest", email: String.downcase("g-#{user["id"]}@guest.comma.invalid")]
    )

    {Map.put(user, "kind", "guest"), session}
  end

  defp workspace!(user, tenant, group) do
    id = "wsp_mini_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    workspace =
      Repo.insert!(%Workspace{
        id: id,
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "mini-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "acct_" <> id,
        name: "Team",
        status: "active"
      })

    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: workspace.billing_owner_id,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace.id
      })

    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: workspace.billing_owner_id,
        credits: 100,
        valid_from: DateTime.add(SystemsClock.utc_now(), -60, :second),
        expires_at: DateTime.add(SystemsClock.utc_now(), 1, :day),
        source_type: "manual_contract",
        source_id: "mini-app-test",
        source_event_id: workspace.id,
        idempotency_key: workspace.id
      })

    member!(workspace, user, "owner")
    workspace
  end

  defp set_account_status!(workspace, status) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "UPDATE billing_accounts SET status = $1 WHERE id = $2",
      [
        status,
        workspace.billing_owner_id
      ]
    )
  end

  defp member!(workspace, user, role) do
    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: role,
      status: "active"
    })
  end

  defp req(ctx, method, path, {_user, session}, body \\ nil, headers \\ []) do
    Req.request!(
      [
        method: method,
        url: ctx.base <> path,
        headers: [{"authorization", "Bearer " <> session["token"]} | headers],
        retry: false
      ] ++ if(body, do: [json: body], else: [])
    )
  end

  defp raw(ctx, method, path, {_user, session}, body, headers) do
    Req.request!(
      method: method,
      url: ctx.base <> path,
      headers: [{"authorization", "Bearer " <> session["token"]} | headers],
      body: body,
      retry: false
    )
  end
end
