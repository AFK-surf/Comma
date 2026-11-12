defmodule SalixIM.FeishuDocsTest do
  @moduledoc """
  Feishu cloud documents through the Group's Feishu connect: what the bot
  sends to Feishu, how a read is labelled, and which agents may call the
  operations. A local Plug stands in for the Feishu Open Platform.
  """

  use SystemsClock.Case, async: false

  alias SalixIM.Provider.Feishu
  alias SalixIM.Provider.Feishu.Docs
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.Keys

  @connect_id "cnx_feishu_docs"

  defmodule FakeFeishu do
    @moduledoc false
    use Agent
    import Plug.Conn

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{routes: %{}, requests: []} end, name: __MODULE__)

    def route(method, path, status \\ 200, body),
      do: Agent.update(__MODULE__, &put_in(&1, [:routes, {method, path}], {status, body}))

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      auth = conn |> get_req_header("authorization") |> List.first()
      {:ok, raw, conn} = read_body(conn, length: 30_000_000)

      body =
        case Jason.decode(raw) do
          {:ok, decoded} -> decoded
          _ -> raw
        end

      Agent.update(__MODULE__, fn state ->
        request = %{
          method: conn.method,
          path: conn.request_path,
          query: conn.query_params,
          body: body,
          authorization: conn |> get_req_header("authorization") |> List.first()
        }

        %{state | requests: [request | state.requests]}
      end)

      {status, response} =
        case Agent.get(__MODULE__, &Map.get(&1.routes, {conn.method, conn.request_path})) do
          # An answer that depends on the query, such as a page cursor.
          {status, answer} when is_function(answer, 1) ->
            {status, answer.(Map.put(conn.query_params, "__authorization", auth))}

          nil ->
            {404, %{"code" => 1_770_002, "msg" => "not found"}}

          route ->
            route
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(response))
    end
  end

  defmodule FakeAppStore do
    @moduledoc false
    def get_feishu_tenant_app(_tenant_id),
      do: {:ok, %{"app_id" => "cli_docs", "app_secret" => "s"}}
  end

  defmodule FakeWorkspace do
    @moduledoc false
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def put(path, body), do: Agent.update(__MODULE__, &Map.put(&1, path, body))
    def get(path), do: Agent.get(__MODULE__, &Map.get(&1, path))

    def write(_agent_id, path, body) do
      put(path, body)
      {:ok, %{path: path, size: byte_size(body)}}
    end

    def read_stream(_agent_id, path) do
      case get(path) do
        nil -> {:error, :not_found}
        body -> {:ok, [body], byte_size(body), Path.basename(path)}
      end
    end

    def read_upload(_agent_id, _path, _title), do: {:error, "unused"}
    def list(_agent_id, _path), do: {:error, :not_found}
    def put_ref(_agent_id, _path, _ref), do: {:error, "unused"}
    def file_ref(_agent_id, _path), do: {:error, "unused"}
    def read_ref_stream(_agent_id, _ref, _filename), do: {:error, "unused"}
  end

  defmodule FakeAccounts do
    @moduledoc "Two Feishu people who signed in for the Group; a token names its account."
    @behaviour SalixIM.Ports.FeishuUserAccounts

    @impl true
    def list(_group_id) do
      {:ok,
       [
         %{"alias" => "feishu-ray", "open_id" => "ou_ray", "name" => "Ray", "status" => "active"},
         %{"alias" => "feishu-ann", "open_id" => "ou_ann", "name" => "Ann", "status" => "active"},
         %{"alias" => "feishu-bo", "open_id" => "ou_bo", "name" => "Bo", "status" => "expired"}
       ]}
    end

    @impl true
    def access_token(_agent_id, alias_name), do: {:ok, "u-" <> alias_name}
  end

  defmodule ManyAccounts do
    @moduledoc "Twelve signed-in people; one of them labelled app."
    @behaviour SalixIM.Ports.FeishuUserAccounts

    @impl true
    def list(_group_id) do
      {:ok,
       [%{"alias" => "app", "open_id" => "ou_appy", "name" => "Appy", "status" => "active"}] ++
         for(
           n <- 1..11,
           do: %{
             "alias" => "p#{n}",
             "open_id" => "ou_p#{n}",
             "name" => "P#{n}",
             "status" => "active"
           }
         )}
    end

    @impl true
    def access_token(_agent_id, alias_name), do: {:ok, "u-" <> alias_name}
  end

  setup do
    for table <-
          ~w(ifc_scope_labels ifc_tag_clearances ifc_principal_facts ifc_scope_facts ifc_scope_members ifc_receipts) do
      SalixStore.Repo.query!("DELETE FROM #{table}")
    end

    previous =
      for {app, key} <- [
            {:salix_store, :s3_backend},
            {:salix_im, :feishu_api_base_url},
            {:salix_im, :agent_workspace_mod},
            {:salix_im, :provider_app_store_mod},
            {:salix_agent, :group_context_mod}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SalixAgent.TestSupport.configure_control_fixtures!()

    start_supervised!(FakeFeishu)
    start_supervised!(FakeWorkspace)
    port = BanditServer.start!(fn p -> {Bandit, plug: FakeFeishu, port: p} end)
    SystemsRuntime.put_env(:salix_im, :feishu_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, FakeWorkspace)
    SystemsRuntime.put_env(:salix_im, :provider_app_store_mod, FakeAppStore)

    on_exit(fn ->
      for {app, key, value} <- previous do
        if is_nil(value),
          do: SystemsRuntime.delete_env(app, key),
          else: SystemsRuntime.put_env(app, key, value)
      end
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    router_id = SalixStore.Ids.new_agent_id(group_id)
    worker_id = SalixStore.Ids.new_agent_id(group_id)

    SalixAgent.TestSupport.create_control_agent!(router_id, %{
      "tenant_id" => tenant,
      "group_id" => group_id,
      "name" => "Router",
      "role" => "router"
    })

    SalixAgent.TestSupport.create_control_agent!(worker_id, %{
      "tenant_id" => tenant,
      "group_id" => group_id,
      "name" => "Worker",
      "role" => "worker"
    })

    {:ok, _group} =
      SalixStore.CasRecord.update(
        Keys.ctl_group(group_id),
        &Map.put(&1, "router_agent_id", router_id)
      )

    connect = %{
      "tenant_id" => tenant,
      "group_id" => group_id,
      "connect_id" => @connect_id,
      "provider" => "feishu",
      "status" => "connected",
      "app_id" => "cli_docs",
      "tenant_access_token" => "t-docs"
    }

    {:ok, _} = SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, @connect_id), connect)

    {:ok, connect: connect, group_id: group_id, router_id: router_id, worker_id: worker_id}
  end

  defp ifc_mode(group_id, mode) do
    {:ok, _} =
      SalixStore.CasRecord.update(
        Keys.ctl_group(group_id),
        &Map.put(&1, "ifc", %{"mode" => mode})
      )

    :ok
  end

  defp ok(data), do: %{"code" => 0, "msg" => "success", "data" => data}

  defp audience_routes(token, link, members) do
    FakeFeishu.route(
      "GET",
      "/open-apis/drive/v2/permissions/#{token}/public",
      ok(%{"permission_public" => %{"link_share_entity" => link}})
    )

    FakeFeishu.route(
      "GET",
      "/open-apis/drive/v1/permissions/#{token}/members",
      ok(%{"items" => members})
    )
  end

  defp requests(method, path),
    do: Enum.filter(FakeFeishu.requests(), &(&1.method == method and &1.path == path))

  describe "who a person is" do
    test "the app says a person's name, email and tenant", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/contact/v3/users/ou_alice",
        ok(%{"user" => %{"name" => "Alice", "enterprise_email" => "alice@acme.test"}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/tenant/v2/tenant/query",
        ok(%{"tenant" => %{"name" => "Acme"}})
      )

      assert Feishu.account(ctx.connect, "ou_alice") == %{
               "name" => "Alice",
               "email" => "alice@acme.test",
               "workspace" => "Acme"
             }
    end

    test "what the app may not read stays out, and nothing fails", ctx do
      assert %{"name" => nil, "email" => nil, "workspace" => nil} =
               Feishu.account(ctx.connect, "ou_nobody")
    end
  end

  describe "reading a document" do
    test "a wiki link is read as the bot and labelled by the chat it is shared with", ctx do
      ifc_mode(ctx.group_id, "enforce")

      FakeFeishu.route(
        "POST",
        "/open-apis/docs_ai/v1/documents/WikiNode0001/fetch",
        ok(%{
          "document" => %{
            "document_id" => "WikiNode0001",
            "revision_id" => 7,
            "content" => "# Plan\n\nShip it."
          }
        })
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/wiki/v2/spaces/get_node",
        ok(%{
          "node" => %{
            "obj_type" => "docx",
            "obj_token" => "DocxObj0001",
            "node_token" => "WikiNode0001"
          }
        })
      )

      audience_routes("WikiNode0001", "closed", [
        %{"member_type" => "openchat", "member_id" => "oc_team", "perm" => "edit"}
      ])

      assert {:ok, result} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.fetch_doc", %{
                 "doc" => "https://acme.feishu.cn/wiki/WikiNode0001?from=im",
                 "detail" => "with-ids",
                 "scope" => "outline",
                 "max_depth" => 2
               })

      assert result["content"] == "# Plan\n\nShip it."
      assert result["revision_id"] == 7
      assert result["__ifc__"] == %{"label" => ["scope|#{@connect_id}|oc_team"]}

      assert [fetch] = requests("POST", "/open-apis/docs_ai/v1/documents/WikiNode0001/fetch")
      assert fetch.body["format"] == "markdown"
      assert fetch.body["export_option"] == %{"export_block_id" => true}
      assert fetch.body["read_option"] == %{"read_mode" => "outline", "max_depth" => "2"}

      # Wiki permissions belong to the node, not to the Docx object.
      assert [members] = requests("GET", "/open-apis/drive/v1/permissions/WikiNode0001/members")
      assert members.query["type"] == "wiki"

      # A bare node token names the same wiki page when doc_type says so.
      assert {:ok, %{"__ifc__" => %{"label" => ["scope|#{@connect_id}|oc_team"]}}} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.fetch_doc", %{
                 "doc" => "WikiNode0001",
                 "doc_type" => "wiki"
               })
    end

    test "a tenant link reads as the space; an audience Feishu will not disclose fails closed",
         ctx do
      ifc_mode(ctx.group_id, "enforce")

      for token <- ~w(DocxOpen0001 DocxShut0001) do
        FakeFeishu.route(
          "POST",
          "/open-apis/docs_ai/v1/documents/#{token}/fetch",
          ok(%{"document" => %{"content" => "body"}})
        )
      end

      audience_routes("DocxOpen0001", "tenant_readable", [])

      FakeFeishu.route(
        "GET",
        "/open-apis/drive/v2/permissions/DocxShut0001/public",
        ok(%{"permission_public" => %{"link_share_entity" => "closed"}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/drive/v1/permissions/DocxShut0001/members",
        403,
        %{"code" => 1_063_002, "msg" => "permission denied"}
      )

      assert {:ok, open} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.fetch_doc", %{
                 "doc" => "DocxOpen0001"
               })

      assert open["__ifc__"] == %{"label" => ["space|#{@connect_id}"]}

      assert {:ok, shut} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.fetch_doc", %{
                 "doc" => "DocxShut0001"
               })

      assert shut["__ifc__"] == %{"label" => ["agent_private"]}
    end
  end

  describe "reading the directory and chats" do
    test "the directory reads as the space and a chat's members as that chat", ctx do
      ifc_mode(ctx.group_id, "enforce")

      FakeFeishu.route(
        "GET",
        "/open-apis/contact/v3/users/ou_alice",
        ok(%{"user" => %{"open_id" => "ou_alice", "name" => "Alice"}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/im/v1/chats/oc_team/members",
        ok(%{"items" => [%{"member_id" => "ou_alice", "name" => "Alice"}], "has_more" => false})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/im/v1/chats",
        ok(%{
          "items" => [%{"chat_id" => "oc_team", "name" => "Team"}, %{"chat_id" => "oc_ops"}],
          "has_more" => false
        })
      )

      assert {:ok, user} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.get_user", %{
                 "user_id" => "ou_alice"
               })

      assert user["__ifc__"] == %{"label" => ["space|#{@connect_id}"]}

      assert {:ok, members} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.list_chat_members", %{
                 "chat_id" => "oc_team"
               })

      assert members["__ifc__"] == %{"label" => ["scope|#{@connect_id}|oc_team"]}

      assert {:ok, chats} = Feishu.call(ctx.router_id, ctx.connect, "feishu.list_chats", %{})

      assert %{"items" => [%{"index" => 0, "label" => team}, %{"index" => 1, "label" => ops}]} =
               chats["__ifc__"]

      assert team == ["scope|#{@connect_id}|oc_team"]
      assert ops == ["scope|#{@connect_id}|oc_ops"]
    end

    test "a mobile number the person hid is not returned", ctx do
      hidden = %{"open_id" => "ou_hid", "mobile" => "+8613800000001", "mobile_visible" => false}
      shown = %{"open_id" => "ou_shown", "mobile" => "+8613800000002", "mobile_visible" => true}

      FakeFeishu.route("GET", "/open-apis/contact/v3/users/ou_hid", ok(%{"user" => hidden}))

      FakeFeishu.route(
        "GET",
        "/open-apis/contact/v3/users/find_by_department",
        ok(%{"items" => [hidden, shown], "has_more" => false})
      )

      assert {:ok, %{"user" => user}} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.get_user", %{"user_id" => "ou_hid"})

      assert user == %{"open_id" => "ou_hid", "mobile_visible" => false}

      assert {:ok, %{"users" => [first, second]}} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.list_department_users", %{
                 "department_id" => "od_eng"
               })

      refute Map.has_key?(first, "mobile")
      assert second["mobile"] == "+8613800000002"
    end
  end

  describe "creating a document" do
    test "a new document is closed to its link and shared with the source chat", ctx do
      FakeFeishu.route(
        "POST",
        "/open-apis/docs_ai/v1/documents",
        ok(%{
          "document" => %{
            "document_id" => "DocxNew00001",
            "revision_id" => 1,
            "url" => "https://acme.feishu.cn/docx/DocxNew00001"
          }
        })
      )

      FakeFeishu.route("PATCH", "/open-apis/drive/v2/permissions/DocxNew00001/public", ok(%{}))

      FakeFeishu.route(
        "POST",
        "/open-apis/drive/v1/permissions/DocxNew00001/members",
        ok(%{"member" => %{}})
      )

      assert {:ok, result} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.create_doc", %{
                 "title" => "Q3 <plan>",
                 "content" => "## Goals",
                 "share_chat_id" => "oc_team"
               })

      assert result["url"] == "https://acme.feishu.cn/docx/DocxNew00001"

      assert result["shared_with"] == %{
               "member_type" => "chat",
               "member_id" => "oc_team",
               "perm" => "edit"
             }

      assert [create] = requests("POST", "/open-apis/docs_ai/v1/documents")

      assert create.body == %{
               "format" => "markdown",
               "content" => "<title>Q3 &lt;plan&gt;</title>\n## Goals"
             }

      assert [close] = requests("PATCH", "/open-apis/drive/v2/permissions/DocxNew00001/public")
      assert close.body == %{"link_share_entity" => "closed"}
      assert close.query["type"] == "docx"

      assert [share] = requests("POST", "/open-apis/drive/v1/permissions/DocxNew00001/members")

      assert share.body == %{
               "member_type" => "openchat",
               "member_id" => "oc_team",
               "perm" => "edit",
               "type" => "chat"
             }

      assert share.query == %{"type" => "docx", "need_notification" => "false"}
    end

    test "a document whose link cannot be closed is deleted again", ctx do
      FakeFeishu.route(
        "POST",
        "/open-apis/docs_ai/v1/documents",
        ok(%{"document" => %{"document_id" => "DocxNew00002"}})
      )

      FakeFeishu.route(
        "PATCH",
        "/open-apis/drive/v2/permissions/DocxNew00002/public",
        400,
        %{"code" => 99_991_672, "msg" => "no permission"}
      )

      FakeFeishu.route(
        "DELETE",
        "/open-apis/drive/v1/files/DocxNew00002",
        ok(%{"task_id" => "t1"})
      )

      assert {:error, error} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.create_doc", %{
                 "title" => "Plan",
                 "share_chat_id" => "oc_team"
               })

      assert error =~ "could not be set to closed"
      assert error =~ "deleted again"
      assert [_delete] = requests("DELETE", "/open-apis/drive/v1/files/DocxNew00002")
      assert requests("POST", "/open-apis/drive/v1/permissions/DocxNew00002/members") == []
    end
  end

  describe "editing a document" do
    test "append writes after the last block and reports provider warnings", ctx do
      FakeFeishu.route(
        "PUT",
        "/open-apis/docs_ai/v1/documents/DocxTok00001",
        ok(%{
          "result" => "success",
          "document" => %{"revision_id" => 9, "new_blocks" => [%{"block_id" => "blkNew"}]},
          "warnings" => ["image skipped"]
        })
      )

      assert {:ok, result} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.update_doc", %{
                 "doc" => "https://acme.feishu.cn/docx/DocxTok00001",
                 "command" => "append",
                 "content" => "- done"
               })

      assert result["new_blocks"] == [%{"block_id" => "blkNew"}]
      assert result["warnings"] == ["image skipped"]

      assert [put] = requests("PUT", "/open-apis/docs_ai/v1/documents/DocxTok00001")

      assert put.body == %{
               "format" => "markdown",
               "command" => "block_insert_after",
               "block_id" => "-1",
               "content" => "- done"
             }
    end

    test "an image is appended in a placeholder block that is removed if the upload fails", ctx do
      FakeWorkspace.put("/out/chart.png", "png-bytes")

      FakeFeishu.route(
        "GET",
        "/open-apis/docx/v1/documents/DocxTok00001/blocks/DocxTok00001",
        ok(%{"block" => %{"block_id" => "DocxTok00001", "children" => ["b1", "b2"]}})
      )

      FakeFeishu.route(
        "POST",
        "/open-apis/docx/v1/documents/DocxTok00001/blocks/DocxTok00001/children",
        ok(%{"children" => [%{"block_id" => "blkImg"}]})
      )

      FakeFeishu.route(
        "POST",
        "/open-apis/drive/v1/medias/upload_all",
        ok(%{"file_token" => "boxImg"})
      )

      FakeFeishu.route(
        "PATCH",
        "/open-apis/docx/v1/documents/DocxTok00001/blocks/batch_update",
        ok(%{})
      )

      assert {:ok, %{"block_id" => "blkImg", "file_token" => "boxImg", "media_type" => "image"}} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.insert_doc_media", %{
                 "doc" => "DocxTok00001",
                 "path" => "/out/chart.png"
               })

      assert [placeholder] =
               requests(
                 "POST",
                 "/open-apis/docx/v1/documents/DocxTok00001/blocks/DocxTok00001/children"
               )

      assert placeholder.body == %{
               "children" => [%{"block_type" => 27, "image" => %{}}],
               "index" => 2
             }

      assert [bind] =
               requests("PATCH", "/open-apis/docx/v1/documents/DocxTok00001/blocks/batch_update")

      assert bind.body == %{
               "requests" => [
                 %{"block_id" => "blkImg", "replace_image" => %{"token" => "boxImg"}}
               ]
             }

      FakeFeishu.route(
        "POST",
        "/open-apis/drive/v1/medias/upload_all",
        400,
        %{"code" => 1_061_045, "msg" => "upload failed"}
      )

      FakeFeishu.route(
        "DELETE",
        "/open-apis/docx/v1/documents/DocxTok00001/blocks/DocxTok00001/children/batch_delete",
        ok(%{})
      )

      assert {:error, error} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.insert_doc_media", %{
                 "doc" => "DocxTok00001",
                 "path" => "/out/chart.png"
               })

      assert error =~ "placeholder block was removed"

      assert [rollback] =
               requests(
                 "DELETE",
                 "/open-apis/docx/v1/documents/DocxTok00001/blocks/DocxTok00001/children/batch_delete"
               )

      assert rollback.body == %{"start_index" => 2, "end_index" => 3}
    end
  end

  describe "reading Minutes" do
    test "a Minutes link returns the asked-for artifacts, labelled by the recording's chat",
         ctx do
      ifc_mode(ctx.group_id, "enforce")

      FakeFeishu.route(
        "GET",
        "/open-apis/minutes/v1/minutes/obcnminute001",
        ok(%{"minute" => %{"title" => "周会", "token" => "obcnminute001"}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/minutes/v1/minutes/obcnminute001/artifacts",
        ok(%{
          "summary" => "决定下周发布",
          "minute_todos" => [%{"content" => "写发布说明"}],
          "minute_chapters" => [%{"title" => "发布"}],
          "transcript" => "说话人 1: 我们下周发布。"
        })
      )

      audience_routes("obcnminute001", "closed", [
        %{"member_type" => "openchat", "member_id" => "oc_team"}
      ])

      assert {:ok, result} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.get_minute", %{
                 "minute" => "https://acme.feishu.cn/minutes/obcnminute001?from=im",
                 "include" => "summary,todos,transcript"
               })

      assert result["title"] == "周会"

      assert result["artifacts"] == %{
               "summary" => "决定下周发布",
               "todos" => [%{"content" => "写发布说明"}],
               "transcript" => "说话人 1: 我们下周发布。"
             }

      assert result["__ifc__"] == %{"label" => ["scope|#{@connect_id}|oc_team"]}

      assert [members] = requests("GET", "/open-apis/drive/v1/permissions/obcnminute001/members")
      assert members.query["type"] == "minutes"
    end

    test "search sends the filters Feishu expects and needs at least one", ctx do
      FakeFeishu.route(
        "POST",
        "/open-apis/minutes/v1/minutes/search",
        ok(%{"items" => [%{"token" => "obcnminute001", "avatar" => "x"}], "has_more" => false})
      )

      assert {:ok, %{"minutes" => [%{"token" => "obcnminute001"} = item]}} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.list_minutes", %{
                 "query" => "发布",
                 "participant_ids" => ["ou_a"],
                 "start" => "2026-10-01",
                 "page_size" => 100
               })

      refute Map.has_key?(item, "avatar")

      assert [search] = requests("POST", "/open-apis/minutes/v1/minutes/search")
      assert search.query == %{"page_size" => "30"}

      assert search.body == %{
               "query" => "发布",
               "sorter" => "create_time_desc",
               "filter" => %{
                 "participant_ids" => ["ou_a"],
                 "create_time" => %{"start_time" => "2026-10-01T00:00:00Z"}
               }
             }

      assert {:error, "pass at least one of query, owner_ids, participant_ids, start, or end"} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.list_minutes", %{})
    end

    test "media is fetched only from an HTTPS link Feishu returned", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/minutes/v1/minutes/obcnminute001/media",
        ok(%{"download_url" => "http://127.0.0.1:1/media.mp4"})
      )

      assert {:error, "Feishu returned no usable download_url for this recording"} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.fetch_minute_media", %{
                 "minute" => "obcnminute001"
               })
    end
  end

  describe "reading a Base and a spreadsheet" do
    test "a Base link is read as the bot, its table and view are the defaults, and the read is labelled",
         ctx do
      ifc_mode(ctx.group_id, "enforce")

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseApp0001",
        ok(%{"app" => %{"app_token" => "BaseApp0001", "name" => "销售数据", "is_advanced" => false}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseApp0001/tables",
        ok(%{
          "items" => [%{"table_id" => "tblOrders", "name" => "销售订单"}],
          "has_more" => false,
          "page_token" => ""
        })
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseApp0001/tables/tblOrders/fields",
        ok(%{
          "items" => [%{"field_id" => "fld1", "field_name" => "订单号", "type" => 1}],
          "has_more" => false
        })
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseApp0001/tables/tblOrders/views",
        ok(%{"items" => [%{"view_id" => "vew2026", "view_name" => "2026"}]})
      )

      FakeFeishu.route(
        "POST",
        "/open-apis/bitable/v1/apps/BaseApp0001/tables/tblOrders/records/search",
        ok(%{
          "items" => [%{"record_id" => "rec1", "fields" => %{"订单号" => "SO-2026-001"}}],
          "has_more" => true,
          "page_token" => "next1",
          "total" => 2
        })
      )

      audience_routes("BaseApp0001", "closed", [
        %{"member_type" => "openchat", "member_id" => "oc_team", "perm" => "view"}
      ])

      link = "https://acme.feishu.cn/base/BaseApp0001?table=tblOrders&view=vew2026"

      assert {:ok, base} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.get_base", %{"base" => link})

      assert base["name"] == "销售数据"
      assert base["default_table_id"] == "tblOrders"
      assert base["default_view_id"] == "vew2026"
      assert [%{"table_id" => "tblOrders"}] = base["tables"]
      assert base["__ifc__"] == %{"label" => ["scope|#{@connect_id}|oc_team"]}

      # A Base's permissions are a bitable's, not a document's.
      assert [members] = requests("GET", "/open-apis/drive/v1/permissions/BaseApp0001/members")
      assert members.query["type"] == "bitable"

      assert {:ok, fields} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.list_base_fields", %{
                 "base" => link
               })

      assert [%{"field_name" => "订单号"}] = fields["fields"]
      assert [%{"view_id" => "vew2026"}] = fields["views"]

      assert [list] =
               requests("GET", "/open-apis/bitable/v1/apps/BaseApp0001/tables/tblOrders/fields")

      assert list.query["view_id"] == "vew2026"

      # A Worker reads the rows; the link's view keeps the person's filter.
      assert {:ok, records} =
               SalixIM.Provider.call_api(ctx.worker_id, "feishu", "feishu.list_base_records", %{
                 "connect_id" => @connect_id,
                 "params" => %{"base" => link, "field_names" => ["订单号"]}
               })

      assert [%{"record_id" => "rec1"}] = records["records"]
      assert records["has_more"] == true
      assert records["next_page_token"] == "next1"
      assert records["total"] == 2
      assert records["__ifc__"] == %{"label" => ["scope|#{@connect_id}|oc_team"]}

      assert [search] =
               requests(
                 "POST",
                 "/open-apis/bitable/v1/apps/BaseApp0001/tables/tblOrders/records/search"
               )

      assert search.query["page_size"] == "100"
      assert search.body["view_id"] == "vew2026"
      assert search.body["field_names"] == ["订单号"]
      refute Map.has_key?(search.body, "filter")

      # A search with filter or sort runs over the whole table and the view's
      # filter does not apply, so the two are never combined.
      assert {:error, "filter and sort search the whole table" <> _} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_records", %{
                 "base" => link,
                 "filter" => ~s({"conjunction":"and","conditions":[]})
               })

      assert {:ok, _} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_records", %{
                 "base" => "BaseApp0001",
                 "table_id" => "tblOrders",
                 "filter" => ~s({"conjunction":"and","conditions":[]})
               })

      assert [_, search] =
               requests(
                 "POST",
                 "/open-apis/bitable/v1/apps/BaseApp0001/tables/tblOrders/records/search"
               )

      refute Map.has_key?(search.body, "view_id")
      assert search.body["filter"] == %{"conjunction" => "and", "conditions" => []}

      # An empty view_id does not drop the link's view.
      assert {:ok, _} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_records", %{
                 "base" => link,
                 "view_id" => ""
               })

      assert %{body: %{"view_id" => "vew2026"}} =
               requests(
                 "POST",
                 "/open-apis/bitable/v1/apps/BaseApp0001/tables/tblOrders/records/search"
               )
               |> List.last()

      # Without a table in the link or the call, there is nothing to read.
      assert {:error, "table_id is required" <> _} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.list_base_records", %{
                 "base" => "BaseApp0001"
               })

      # Every table operation is a read in information flow control: its
      # result is labelled, and it sends nothing anywhere.
      for api <- SalixIM.Provider.OperationRegistry.feishu_table_api_names() do
        assert {:read, _} = SalixAgent.IFC.Destination.describe("im_api." <> api, %{}, %{})
      end
    end

    test "a page of records larger than one tool result is staged in the workspace", ctx do
      rows =
        for n <- 1..500,
            do: %{"record_id" => "rec#{n}", "fields" => %{"备注" => String.duplicate("x", 200)}}

      FakeFeishu.route(
        "POST",
        "/open-apis/bitable/v1/apps/BaseApp0001/tables/tblOrders/records/search",
        ok(%{"items" => rows, "has_more" => false, "page_token" => ""})
      )

      assert {:ok, %{"truncated" => true, "records" => [], "vfs_path" => path}} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_records", %{
                 "base" => "BaseApp0001",
                 "table_id" => "tblOrders",
                 "page_size" => 500
               })

      assert String.starts_with?(path, "/feishu/base/BaseApp0001-tblOrders-")
      assert Jason.decode!(FakeWorkspace.get(path)) == rows

      # Another read of the same table, selecting other columns, keeps its own file.
      assert {:ok, %{"vfs_path" => other}} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_records", %{
                 "base" => "BaseApp0001",
                 "table_id" => "tblOrders",
                 "page_size" => 500,
                 "field_names" => ["备注"]
               })

      assert other != path
      assert Jason.decode!(FakeWorkspace.get(path)) == rows

      assert [search, _other] =
               requests(
                 "POST",
                 "/open-apis/bitable/v1/apps/BaseApp0001/tables/tblOrders/records/search"
               )

      assert search.query["page_size"] == "500"
    end

    test "a spreadsheet link is read in bounded ranges and labelled by its link setting", ctx do
      ifc_mode(ctx.group_id, "enforce")

      FakeFeishu.route(
        "GET",
        "/open-apis/sheets/v3/spreadsheets/Sheet0000001",
        ok(%{
          "spreadsheet" => %{
            "title" => "应收单",
            "url" => "https://acme.feishu.cn/sheets/Sheet0000001"
          }
        })
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/sheets/v3/spreadsheets/Sheet0000001/sheets/query",
        ok(%{
          "sheets" => [
            %{
              "sheet_id" => "sh01",
              "title" => "2026",
              "index" => 0,
              "grid_properties" => %{"row_count" => 1000, "column_count" => 3}
            }
          ]
        })
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/sheets/v2/spreadsheets/Sheet0000001/values/sh01!A1:C3",
        ok(%{
          "revision" => 12,
          "valueRange" => %{
            "range" => "sh01!A1:C3",
            "values" => [["单号", "金额"], ["AR-1", "100"], ["AR-2", "250"]]
          }
        })
      )

      audience_routes("Sheet0000001", "tenant_readable", [])

      link = "https://acme.feishu.cn/sheets/Sheet0000001?sheet=sh01"

      assert {:ok, sheet} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.get_sheet", %{"sheet" => link})

      assert sheet["title"] == "应收单"
      assert sheet["default_sheet_id"] == "sh01"

      assert [%{"sheet_id" => "sh01", "grid_properties" => %{"row_count" => 1000}}] =
               sheet["sheets"]

      assert sheet["__ifc__"] == %{"label" => ["space|#{@connect_id}"]}

      assert [members] = requests("GET", "/open-apis/drive/v1/permissions/Sheet0000001/members")
      assert members.query["type"] == "sheet"

      assert {:ok, range} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.get_sheet_range", %{
                 "sheet" => link,
                 "range" => "a1:c3"
               })

      assert range["rows"] == [["单号", "金额"], ["AR-1", "100"], ["AR-2", "250"]]
      assert range["row_count"] == 3
      assert range["revision"] == 12

      # The sheet is longer than the range: the next range continues it, and
      # no column lies to the right.
      assert range["has_more"] == true
      assert range["next_range"] == "A4:C6"
      assert range["sheet_row_count"] == 1000
      assert range["__ifc__"] == %{"label" => ["space|#{@connect_id}"]}

      assert [read] =
               requests("GET", "/open-apis/sheets/v2/spreadsheets/Sheet0000001/values/sh01!A1:C3")

      assert read.query["valueRenderOption"] == "ToString"

      # A range is bounded per call; the next range continues it.
      assert {:error, "range covers 600 rows" <> _} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.get_sheet_range", %{
                 "sheet" => link,
                 "range" => "A1:C600"
               })

      assert {:error, "range must be an A1 range" <> _} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.get_sheet_range", %{
                 "sheet" => link,
                 "range" => "sh01!A1:C3"
               })
    end

    test "an advanced-permission Base is private to the agent, a share link names no Base, and views page",
         ctx do
      ifc_mode(ctx.group_id, "enforce")

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseAdv0001",
        ok(%{"app" => %{"name" => "工资表", "is_advanced" => true}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseAdv0001/tables",
        ok(%{"items" => [%{"table_id" => "tblPay", "name" => "工资"}], "has_more" => false})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseAdv0001/tables/tblPay/fields",
        ok(%{"items" => [%{"field_name" => "姓名"}], "has_more" => false})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseAdv0001/tables/tblPay/views",
        ok(%{"items" => [%{"view_id" => "vewAll"}], "has_more" => true, "page_token" => "v2"})
      )

      FakeFeishu.route(
        "POST",
        "/open-apis/bitable/v1/apps/BaseAdv0001/tables/tblPay/records/search",
        ok(%{
          "items" => [%{"record_id" => "rec1", "fields" => %{"姓名" => "Ann"}}],
          "has_more" => false
        })
      )

      # The Base is shared with a chat, but advanced permissions give each
      # collaborator its own rows: the chat is not the audience of what the
      # app read.
      audience_routes("BaseAdv0001", "closed", [
        %{"member_type" => "openchat", "member_id" => "oc_team", "perm" => "view"}
      ])

      assert {:ok, %{"is_advanced" => true, "__ifc__" => %{"label" => ["agent_private"]}}} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.get_base", %{
                 "base" => "BaseAdv0001"
               })

      assert {:ok, fields} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_fields", %{
                 "base" => "BaseAdv0001",
                 "table_id" => "tblPay"
               })

      assert fields["__ifc__"] == %{"label" => ["agent_private"]}
      assert [%{"view_id" => "vewAll"}] = fields["views"]
      assert fields["views_has_more"] == true
      assert fields["views_next_page_token"] == "v2"

      assert {:ok, %{"__ifc__" => %{"label" => ["agent_private"]}}} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_records", %{
                 "base" => "BaseAdv0001",
                 "table_id" => "tblPay"
               })

      # A second page of fields does not fetch the views again; views page alone.
      assert {:ok, page2} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_fields", %{
                 "base" => "BaseAdv0001",
                 "table_id" => "tblPay",
                 "page_token" => "f2"
               })

      refute Map.has_key?(page2, "views")

      assert {:ok, %{"views_next_page_token" => "v2"} = views_only} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_fields", %{
                 "base" => "BaseAdv0001",
                 "table_id" => "tblPay",
                 "views_page_token" => "v2"
               })

      refute Map.has_key?(views_only, "fields")

      assert [_, _] =
               requests("GET", "/open-apis/bitable/v1/apps/BaseAdv0001/tables/tblPay/fields")

      # An empty filter is no filter, so it keeps the link's view.
      assert {:ok, _} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.list_base_records", %{
                 "base" => "https://acme.feishu.cn/base/BaseAdv0001?table=tblPay&view=vewAll",
                 "filter" => %{}
               })

      assert %{body: %{"view_id" => "vewAll"} = body} =
               requests(
                 "POST",
                 "/open-apis/bitable/v1/apps/BaseAdv0001/tables/tblPay/records/search"
               )
               |> List.last()

      refute Map.has_key?(body, "filter")

      assert [_, %{query: %{"page_token" => "v2"}}] =
               requests("GET", "/open-apis/bitable/v1/apps/BaseAdv0001/tables/tblPay/views")

      # A share link of a view or form carries no app token.
      assert {:error, "this is a share link" <> _} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.get_base", %{
                 "base" => "https://acme.feishu.cn/share/base/view/shrcnAbCdEfGh"
               })

      assert [] = requests("GET", "/open-apis/bitable/v1/apps/view")
    end

    test "next_range walks a sheet to its end and reads each cell once", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/sheets/v3/spreadsheets/Sheet0000002/sheets/query",
        ok(%{
          "sheets" => [
            %{"sheet_id" => "sh02", "grid_properties" => %{"row_count" => 7, "column_count" => 3}}
          ]
        })
      )

      for block <- ~w(A1:C7 A1:B3 A4:B6 A7:B7 C1:C7) do
        FakeFeishu.route(
          "GET",
          "/open-apis/sheets/v2/spreadsheets/Sheet0000002/values/sh02!#{block}",
          ok(%{"valueRange" => %{"range" => "sh02!#{block}", "values" => [[block]]}})
        )
      end

      # Without a range, the first block covers every column of the sheet.
      assert {:ok, %{"range" => "sh02!A1:C7", "has_more" => false} = whole} =
               Feishu.call(ctx.worker_id, ctx.connect, "feishu.get_sheet_range", %{
                 "sheet" => "Sheet0000002",
                 "sheet_id" => "sh02"
               })

      refute Map.has_key?(whole, "next_range")

      # A smaller block walks rows first, then the next columns at full
      # height, each cell once.
      walk = fn walk, range, acc ->
        assert {:ok, result} =
                 Feishu.call(ctx.worker_id, ctx.connect, "feishu.get_sheet_range", %{
                   "sheet" => "Sheet0000002",
                   "sheet_id" => "sh02",
                   "range" => range
                 })

        acc = acc ++ [range]

        case result do
          %{"has_more" => true, "next_range" => next} -> walk.(walk, next, acc)
          %{"has_more" => false} -> acc
        end
      end

      assert walk.(walk, "A1:B3", []) == ~w(A1:B3 A4:B6 A7:B7 C1:C7)
    end

    test "a wiki page that holds a Base is read through the node, and a document read of a Base says where to go",
         ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/wiki/v2/spaces/get_node",
        ok(%{
          "node" => %{
            "obj_type" => "bitable",
            "obj_token" => "BaseApp0002",
            "node_token" => "WikiBase0001",
            "title" => "订单台账"
          }
        })
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseApp0002",
        ok(%{"app" => %{"name" => "订单台账"}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseApp0002/tables",
        ok(%{"items" => [], "has_more" => false})
      )

      assert {:ok, base} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.get_base", %{
                 "base" => "https://acme.feishu.cn/wiki/WikiBase0001"
               })

      assert base["app_token"] == "BaseApp0002"
      assert base["wiki_node"]["node_token"] == "WikiBase0001"

      assert {:error, error} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.fetch_doc", %{
                 "doc" => "https://acme.feishu.cn/wiki/WikiBase0001"
               })

      assert error =~ "feishu.get_base"

      assert {:error, error} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.fetch_doc", %{
                 "doc" => "https://acme.feishu.cn/base/BaseApp0001?table=tblOrders"
               })

      assert error =~ "feishu.get_base"

      assert {:error, error} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.fetch_doc", %{
                 "doc" => "https://acme.feishu.cn/sheets/Sheet0000001"
               })

      assert error =~ "feishu.get_sheet"

      # A spreadsheet link is not a Base, and the other way round.
      assert {:error, "this link is a spreadsheet, not a base" <> _} =
               Feishu.call(ctx.router_id, ctx.connect, "feishu.get_base", %{
                 "base" => "https://acme.feishu.cn/sheets/Sheet0000001"
               })
    end
  end

  describe "who may call the document operations" do
    test "a worker holds every read and document operation and no messaging write", ctx do
      FakeFeishu.route(
        "POST",
        "/open-apis/docs_ai/v1/documents/DocxTok00001/fetch",
        ok(%{"document" => %{"content" => "body"}})
      )

      FakeFeishu.route("GET", "/open-apis/im/v1/chats/oc_team", ok(%{"name" => "Team"}))

      assert {:ok, %{"content" => "body"}} =
               SalixIM.Provider.call_api(ctx.worker_id, "feishu", "feishu.fetch_doc", %{
                 "connect_id" => @connect_id,
                 "params" => %{"doc" => "DocxTok00001"}
               })

      assert {:error, "operation is not available to this agent role"} =
               SalixIM.Provider.call_api(ctx.worker_id, "feishu", "feishu.send_text", %{
                 "connect_id" => @connect_id,
                 "params" => %{"receive_id" => "oc_team", "text" => "hi"}
               })

      assert {:ok, %{"name" => "Team"}} =
               SalixIM.Provider.call_api(ctx.worker_id, "feishu", "feishu.get_chat", %{
                 "connect_id" => @connect_id,
                 "params" => %{"chat_id" => "oc_team"}
               })

      assert {:ok, manual} = SalixIM.Provider.provider_manual("feishu", ctx.worker_id)
      worker_apis = manual["apis"] |> Enum.map(& &1["name"]) |> Enum.sort()

      {:ok, full} = SalixIM.Provider.Manuals.manual("feishu")

      reads =
        for %{"name" => name, "safety" => "read"} <- full["apis"], do: name

      assert worker_apis ==
               Enum.sort(
                 Enum.uniq(
                   reads ++
                     ["feishu.fetch_message_resource"] ++
                     SalixIM.Provider.OperationRegistry.worker_api_names("feishu")
                 )
               )

      for api <-
            ~w(feishu.list_accounts feishu.search_meetings feishu.get_meeting feishu.get_note),
          do: assert(api in worker_apis)

      refute "feishu.send_text" in worker_apis
      refute "feishu.delete_message" in worker_apis

      assert {:ok, connects} = SalixIM.Provider.list_connects(ctx.worker_id)
      assert Enum.any?(connects, &(&1["connect_id"] == @connect_id))
    end
  end

  describe "a write's destination" do
    test "is the space unless the document's link is open to anyone, and public when unknown",
         ctx do
      ifc_mode(ctx.group_id, "enforce")
      audience_routes("DocxTenant01", "closed", [])
      audience_routes("DocxPublic01", "anyone_readable", [])

      resolve = fn document ->
        {:ok, reply} =
          SalixIM.IFC.Facts.resolve(%{
            "tenant_id" => ctx.connect["tenant_id"],
            "group_id" => ctx.group_id,
            "destination" => %{
              "kind" => "provider_document",
              "connect_id" => @connect_id,
              "document" => document,
              "document_type" => ""
            }
          })

        reply["destination"]
      end

      assert %{"label" => ["space|" <> @connect_id], "writers" => "any"} =
               resolve.("DocxTenant01")

      assert %{"label" => ["public"], "writers" => "any"} = resolve.("DocxPublic01")
      assert %{"label" => ["public"], "writers" => "unknown"} = resolve.("DocxMissing1")
    end
  end

  describe "meetings as a signed-in account" do
    setup do
      previous = SystemsRuntime.get_env(:salix_im, :feishu_user_accounts_mod)
      SystemsRuntime.put_env(:salix_im, :feishu_user_accounts_mod, FakeAccounts)

      on_exit(fn ->
        if previous,
          do: SystemsRuntime.put_env(:salix_im, :feishu_user_accounts_mod, previous),
          else: SystemsRuntime.delete_env(:salix_im, :feishu_user_accounts_mod)
      end)

      :ok
    end

    defp worker_call(ctx, api, params) do
      SalixIM.Provider.call_api(ctx.worker_id, "feishu", api, %{
        "connect_id" => @connect_id,
        "params" => params
      })
    end

    test "a chat the bot cannot read is read as a signed-in member", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/im/v1/messages",
        ok(%{
          "items" => [
            %{
              "message_id" => "om_ext",
              "chat_id" => "oc_external",
              "msg_type" => "text",
              "create_time" => "1793785000000",
              "sender" => %{"id" => "ou_ann", "sender_type" => "user"},
              "body" => %{"content" => ~s({"text":"hello"})}
            }
          ],
          "has_more" => false
        })
      )

      assert {:ok, %{"messages" => [%{"message_id" => "om_ext"}]}} =
               worker_call(ctx, "feishu.get_chat_history", %{
                 "chat_id" => "oc_external",
                 "account" => "feishu-ann"
               })

      assert FakeFeishu.requests() |> Enum.map(& &1.authorization) |> Enum.uniq() ==
               ["Bearer u-feishu-ann"]
    end

    test "a search runs as the app and every active account and names who found each meeting",
         ctx do
      FakeFeishu.route(
        "POST",
        "/open-apis/vc/v1/meetings/search",
        ok(%{
          "items" => [%{"id" => "7001", "display_info" => "Ditto Daily"}],
          "has_more" => true,
          "page_token" => "p2"
        })
      )

      assert {:ok, %{"meetings" => meetings, "failed_accounts" => [], "next_pages" => pages}} =
               worker_call(ctx, "feishu.search_meetings", %{
                 "query" => "Daily",
                 "start" => "2026-10-19"
               })

      # The app searches first; the expired account is skipped.
      assert Enum.map(meetings, & &1["account"]) == ["app", "feishu-ray", "feishu-ann"]

      assert pages == [
               %{"account" => "app", "page_token" => "p2"},
               %{"account" => "feishu-ray", "page_token" => "p2"},
               %{"account" => "feishu-ann", "page_token" => "p2"}
             ]

      # A page token is one account's; the next page names that account.
      assert {:error, "a page_token belongs to one account" <> _} =
               worker_call(ctx, "feishu.search_meetings", %{
                 "query" => "Daily",
                 "page_token" => "p2"
               })

      [app, ray, ann] = requests("POST", "/open-apis/vc/v1/meetings/search")
      assert app.authorization == "Bearer t-docs"
      assert ray.authorization == "Bearer u-feishu-ray"
      assert ann.authorization == "Bearer u-feishu-ann"

      assert ray.body == %{
               "query" => "Daily",
               "meeting_filter" => %{"start_time" => %{"start_time" => "2026-10-19T00:00:00Z"}}
             }
    end

    test "a meeting leads to its notes, transcript and recording, read as that person", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/vc/v1/meetings/7001",
        ok(%{
          "meeting" => %{
            "topic" => "Ditto Daily",
            "note_id" => "note_1",
            "participants" => [%{"id" => "ou_ray"}, %{"id" => "ou_bo"}]
          }
        })
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/vc/v1/meetings/7001/recording",
        ok(%{"recording" => %{"url" => "https://x.feishu.cn/minutes/obcndaily0001"}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/vc/v1/notes/note_1",
        ok(%{
          "note" => %{
            "artifacts" => [
              %{"artifact_type" => 1, "doc_token" => "DocxNotes001"},
              %{"artifact_type" => 2, "doc_token" => "DocxVerbatim1"}
            ],
            "note_display_type" => 1
          }
        })
      )

      FakeFeishu.route(
        "POST",
        "/open-apis/docs_ai/v1/documents/DocxNotes001/fetch",
        ok(%{"document" => %{"content" => "Decisions"}})
      )

      assert {:ok,
              %{
                "account" => "feishu-ann",
                "note_id" => "note_1",
                "minute_token" => "obcndaily0001"
              }} =
               worker_call(ctx, "feishu.get_meeting", %{
                 "meeting_id" => "7001",
                 "account" => "ou_ann"
               })

      assert {:ok, %{"note_doc_token" => "DocxNotes001", "verbatim_doc_token" => "DocxVerbatim1"}} =
               worker_call(ctx, "feishu.get_note", %{
                 "note_id" => "note_1",
                 "account" => "feishu-ann"
               })

      assert {:ok, %{"content" => "Decisions"}} =
               worker_call(ctx, "feishu.fetch_doc", %{
                 "doc" => "DocxNotes001",
                 "account" => "feishu-ann"
               })

      # Every read went to Feishu as Ann, none as the bot.
      assert FakeFeishu.requests() |> Enum.map(& &1.authorization) |> Enum.uniq() ==
               ["Bearer u-feishu-ann"]

      # Without an account the same document is read as the bot.
      assert {:ok, %{"content" => "Decisions"}} =
               worker_call(ctx, "feishu.fetch_doc", %{"doc" => "DocxNotes001"})

      assert List.last(FakeFeishu.requests()).authorization == "Bearer t-docs"
    end

    test "a unified note's transcript is read page by page, as the account", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/vc/v1/notes/note_u",
        ok(%{"note" => %{"artifacts" => [], "note_display_type" => 2}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/vc/v1/notes/note_u/unified_note_transcript",
        fn
          %{"cursor_id" => "c2"} ->
            ok(%{"transcript" => %{"markdown" => " Ann: next."}, "has_more" => false})

          _first ->
            ok(%{
              "transcript" => %{"markdown" => "Ray: done."},
              "has_more" => true,
              "next_cursor_id" => "c2"
            })
        end
      )

      assert {:ok, %{"display_type" => "unified", "transcript" => "Ray: done. Ann: next."}} =
               worker_call(ctx, "feishu.get_note", %{
                 "note_id" => "note_u",
                 "account" => "feishu-ray",
                 "include_transcript" => true
               })

      assert [first, %{query: %{"cursor_id" => "c2"}}] =
               requests("GET", "/open-apis/vc/v1/notes/note_u/unified_note_transcript")

      assert first.query == %{"format" => "markdown", "locale" => "zh_cn", "page_size" => "200"}
      assert first.authorization == "Bearer u-feishu-ray"

      # A transcript longer than one tool result is put in the workspace whole.
      long = String.duplicate("Ray: the long stand-up goes on. ", 2_500)

      FakeFeishu.route(
        "GET",
        "/open-apis/vc/v1/notes/note_u/unified_note_transcript",
        ok(%{"transcript" => %{"markdown" => long}, "has_more" => false})
      )

      assert {:ok,
              %{
                "transcript_truncated" => true,
                "vfs_path" => "/feishu/notes/note_u-transcript.md" = path,
                "transcript" => head
              }} =
               worker_call(ctx, "feishu.get_note", %{
                 "note_id" => "note_u",
                 "account" => "feishu-ray",
                 "include_transcript" => true
               })

      assert byte_size(long) > 60_000
      assert FakeWorkspace.get(path) == long
      assert String.starts_with?(long, head)

      # A page that says there is more without a new cursor fails the read.
      FakeFeishu.route(
        "GET",
        "/open-apis/vc/v1/notes/note_u/unified_note_transcript",
        ok(%{"transcript" => %{"markdown" => "x"}, "has_more" => true})
      )

      assert {:error, "Feishu's transcript pages stopped advancing" <> _} =
               worker_call(ctx, "feishu.get_note", %{
                 "note_id" => "note_u",
                 "account" => "feishu-ray",
                 "include_transcript" => "true"
               })
    end

    test "a shared message link is read as the first identity that may open it", ctx do
      url = "https://applink.feishu.cn/client/message/link/open?token=AmT%2Fab%2BQ%3D"

      # The app holds no grant for message links; Ray may read this one.
      FakeFeishu.route("POST", "/open-apis/im/v1/message_links/query", fn
        %{"__authorization" => "Bearer t-docs"} ->
          %{"code" => 99_991_672, "msg" => "Access denied"}

        _person ->
          ok(%{
            "messages" => [
              %{
                "message" => %{
                  "message_id" => "om_src",
                  "msg_type" => "text",
                  "sender" => %{"id" => "ou_bo", "sender_type" => "user"},
                  "body" => %{"content" => ~s({"text":"the build fails on main"})}
                }
              }
            ],
            "chat_info" => %{"chat_id" => "oc_pilot", "name" => "Pilot", "is_authorized" => true}
          })
      end)

      assert {:ok,
              %{
                "account" => "feishu-ray",
                "url" => ^url,
                "messages" => [%{"message_id" => "om_src", "text" => "the build fails on main"}],
                "chat_id" => "oc_pilot",
                "chat" => %{"name" => "Pilot"}
              }} = worker_call(ctx, "feishu.read_message_link", %{"url" => url})

      # The link goes to Feishu whole, as the person shared it.
      assert [app, ray] = requests("POST", "/open-apis/im/v1/message_links/query")
      assert app.body == %{"message_link_url" => url}
      assert ray.authorization == "Bearer u-feishu-ray"

      # Refused everywhere, the read says where else the messages are.
      assert {:error, refused} =
               worker_call(ctx, "feishu.read_message_link", %{"url" => url, "account" => "app"})

      assert refused =~ "find the messages with feishu.search_chats"

      assert {:error, "url must be a Feishu message link" <> _} =
               worker_call(ctx, "feishu.read_message_link", %{
                 "url" => "https://applink.feishu.cn/client/chat/open?openChatId=oc_pilot"
               })
    end

    test "a merged forward is read with the messages it carries", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/im/v1/messages/om_fwd",
        ok(%{
          "items" => [
            %{
              "message_id" => "om_fwd",
              "chat_id" => "oc_here",
              "msg_type" => "merge_forward",
              "body" => %{"content" => "Merged and Forwarded Message"}
            },
            %{
              "message_id" => "om_one",
              "upper_message_id" => "om_fwd",
              "msg_type" => "text",
              "sender" => %{"id" => "ou_bo", "sender_type" => "user"},
              "body" => %{"content" => ~s({"text":"the build fails on main"})}
            }
          ]
        })
      )

      assert {:ok,
              %{
                "message" => %{"message_id" => "om_fwd", "message_type" => "merge_forward"},
                "forwarded_messages" => [
                  %{
                    "message_id" => "om_one",
                    "upper_message_id" => "om_fwd",
                    "text" => "the build fails on main"
                  }
                ]
              }} = worker_call(ctx, "feishu.get_message", %{"message_id" => "om_fwd"})
    end

    test "a read tries each account until one may see the meeting", ctx do
      # The app may not see this meeting; Ray may.
      FakeFeishu.route("GET", "/open-apis/vc/v1/meetings/7002", fn
        %{"__authorization" => "Bearer t-docs"} ->
          %{"code" => 121_005, "msg" => "no permission"}

        _person ->
          ok(%{"meeting" => %{"topic" => "1:1"}})
      end)

      assert {:ok, %{"account" => "feishu-ray", "recording" => "unavailable: " <> _}} =
               worker_call(ctx, "feishu.get_meeting", %{"meeting_id" => "7002"})

      # account=app reads as the app alone.
      assert {:error, _refused} =
               worker_call(ctx, "feishu.get_meeting", %{
                 "meeting_id" => "7002",
                 "account" => "app"
               })

      assert {:error, "no signed-in Feishu account feishu-zoe; feishu.list_accounts names them"} =
               worker_call(ctx, "feishu.get_note", %{"note_id" => "n", "account" => "feishu-zoe"})

      assert {:error,
              "the Feishu account Bo is expired; ask that person to sign in again: call oauth.request_authorization with provider feishu and alias feishu-bo" <>
                _} =
               worker_call(ctx, "feishu.get_minute", %{
                 "minute" => "obcndaily0001",
                 "account" => "feishu-bo"
               })

      assert {:ok, %{"accounts" => [_, _, _]}} = worker_call(ctx, "feishu.list_accounts", %{})
    end

    test "without a signed-in account the app searches alone and says how a person signs in",
         ctx do
      SystemsRuntime.delete_env(:salix_im, :feishu_user_accounts_mod)

      FakeFeishu.route(
        "POST",
        "/open-apis/vc/v1/meetings/search",
        ok(%{"items" => [%{"id" => "7003"}], "has_more" => false})
      )

      assert {:ok, %{"meetings" => [%{"account" => "app"}], "guidance" => guidance}} =
               worker_call(ctx, "feishu.search_meetings", %{"query" => "Daily"})

      assert guidance =~ "oauth.request_authorization with provider feishu"

      assert [%{authorization: "Bearer t-docs"}] =
               requests("POST", "/open-apis/vc/v1/meetings/search")
    end

    test "documents and wiki pages are found by keyword and read without a link", ctx do
      FakeFeishu.route(
        "POST",
        "/open-apis/search/v2/doc_wiki/search",
        ok(%{
          "res_units" => [
            %{
              "title_highlighted" => "Ditto x RC <h>Daily</h> SyncUp",
              "entity_type" => "DOC",
              "result_meta" => %{
                "url" => "https://x.feishu.cn/docx/DocxDaily0001",
                "token" => "DocxDaily0001",
                "doc_types" => "DOCX"
              }
            }
          ],
          "has_more" => false
        })
      )

      FakeFeishu.route(
        "POST",
        "/open-apis/docs_ai/v1/documents/DocxDaily0001/fetch",
        ok(%{"document" => %{"content" => "Decided: cloud browser."}})
      )

      assert {:ok, %{"documents" => hits, "failed_accounts" => []}} =
               worker_call(ctx, "feishu.search_docs", %{"query" => "Daily"})

      assert Enum.map(hits, & &1["account"]) == ["app", "feishu-ray", "feishu-ann"]

      assert %{
               "title" => "Ditto x RC Daily SyncUp",
               "url" => "https://x.feishu.cn/docx/DocxDaily0001",
               "token" => "DocxDaily0001"
             } = hd(hits)

      [app, ray, _ann] = requests("POST", "/open-apis/search/v2/doc_wiki/search")
      assert app.authorization == "Bearer t-docs"
      assert ray.authorization == "Bearer u-feishu-ray"

      assert ray.body == %{
               "query" => "Daily",
               "page_size" => 15,
               "doc_filter" => %{},
               "wiki_filter" => %{}
             }

      # A hit is read as the account that found it.
      assert {:ok, %{"content" => "Decided: cloud browser."}} =
               worker_call(ctx, "feishu.fetch_doc", %{
                 "doc" => "https://x.feishu.cn/docx/DocxDaily0001",
                 "account" => "feishu-ray"
               })

      assert List.last(requests("POST", "/open-apis/docs_ai/v1/documents/DocxDaily0001/fetch")).authorization ==
               "Bearer u-feishu-ray"
    end

    test "a search is labelled by the identities whose items it returns", ctx do
      ifc_mode(ctx.group_id, "enforce")

      hit = %{
        "title_highlighted" => "Plan",
        "result_meta" => %{
          "url" => "https://x.feishu.cn/docx/DocxPlan00001",
          "token" => "DocxPlan00001"
        }
      }

      route = fn app_answer ->
        FakeFeishu.route("POST", "/open-apis/search/v2/doc_wiki/search", fn
          %{"__authorization" => "Bearer t-docs"} -> app_answer
          %{"__authorization" => "Bearer u-feishu-ray"} -> ok(%{"res_units" => [hit]})
          _ann -> ok(%{"res_units" => []})
        end)
      end

      route.(ok(%{"res_units" => []}))

      assert {:ok, %{"__ifc__" => ray_only}} =
               worker_call(ctx, "feishu.search_docs", %{
                 "query" => "Plan",
                 "account" => "feishu-ray"
               })

      refute ray_only == %{"label" => ["agent_private"]}

      # The app finds nothing, or fails: only Ray's items come back, labelled as Ray's.

      assert {:ok, %{"documents" => [%{"account" => "feishu-ray"}], "__ifc__" => ^ray_only}} =
               worker_call(ctx, "feishu.search_docs", %{"query" => "Plan"})

      route.(%{"code" => 99_991_672, "msg" => "no permission"})

      assert {:ok,
              %{
                "documents" => [_],
                "failed_accounts" => [%{"account" => "app"}],
                "__ifc__" => ^ray_only
              }} =
               worker_call(ctx, "feishu.search_docs", %{"query" => "Plan"})

      # An item the app found has no audience this read can name.
      route.(ok(%{"res_units" => [hit]}))

      assert {:ok, %{"__ifc__" => %{"label" => ["agent_private"]}}} =
               worker_call(ctx, "feishu.search_docs", %{"query" => "Plan"})
    end

    test "a search reads as ten identities per call and continues with accounts_from", ctx do
      SystemsRuntime.put_env(:salix_im, :feishu_user_accounts_mod, ManyAccounts)

      FakeFeishu.route(
        "POST",
        "/open-apis/search/v2/doc_wiki/search",
        ok(%{
          "res_units" => [
            %{"title_highlighted" => "Plan", "result_meta" => %{"token" => "DocxPlan00001"}}
          ]
        })
      )

      assert {:ok, %{"documents" => first, "more_accounts" => %{"accounts_from" => 10}}} =
               worker_call(ctx, "feishu.search_docs", %{"query" => "Plan"})

      # The app, then the person labelled app (named by open_id), then p1..p8.
      assert Enum.map(first, & &1["account"]) ==
               ["app", "ou_appy"] ++ for(n <- 1..8, do: "p#{n}")

      assert {:ok, %{"documents" => rest} = page} =
               worker_call(ctx, "feishu.search_docs", %{"query" => "Plan", "accounts_from" => 10})

      assert Enum.map(rest, & &1["account"]) == ["p9", "p10", "p11"]
      refute Map.has_key?(page, "more_accounts")
      assert length(requests("POST", "/open-apis/search/v2/doc_wiki/search")) == 13

      # The person labelled app reads as themselves through that name; app is
      # the app.
      assert {:ok, _} =
               worker_call(ctx, "feishu.search_docs", %{"query" => "Plan", "account" => "ou_appy"})

      assert {:ok, _} =
               worker_call(ctx, "feishu.search_docs", %{"query" => "Plan", "account" => "app"})

      assert requests("POST", "/open-apis/search/v2/doc_wiki/search")
             |> Enum.take(-2)
             |> Enum.map(& &1.authorization) == ["Bearer u-app", "Bearer t-docs"]
    end

    test "a read tries ten identities per call and continues with accounts_from", ctx do
      SystemsRuntime.put_env(:salix_im, :feishu_user_accounts_mod, ManyAccounts)

      # Only p9, the eleventh identity, may see the meeting.
      FakeFeishu.route("GET", "/open-apis/vc/v1/meetings/7009", fn
        %{"__authorization" => "Bearer u-p9"} -> ok(%{"meeting" => %{"topic" => "Late"}})
        _other -> %{"code" => 121_005, "msg" => "no permission"}
      end)

      assert {:error, refused} =
               worker_call(ctx, "feishu.get_meeting", %{"meeting_id" => "7009"})

      assert refused =~ "call again with accounts_from 10"
      assert length(requests("GET", "/open-apis/vc/v1/meetings/7009")) == 10

      assert {:ok, %{"account" => "p9", "meeting" => %{"topic" => "Late"}}} =
               worker_call(ctx, "feishu.get_meeting", %{
                 "meeting_id" => "7009",
                 "accounts_from" => 10
               })

      assert requests("GET", "/open-apis/vc/v1/meetings/7009")
             |> Enum.drop(10)
             |> Enum.map(& &1.authorization) == ["Bearer u-p9"]
    end

    test "a document's owner is asked for access as the person, never as the app", ctx do
      wiki = "/open-apis/drive/v1/permissions/WikiNode0001/members/apply"
      docx = "/open-apis/drive/v1/permissions/DocxTok00001/members/apply"
      FakeFeishu.route("POST", wiki, ok(%{}))

      assert {:ok, %{"doc" => "WikiNode0001", "doc_type" => "wiki", "requested" => "view"}} =
               worker_call(ctx, "feishu.request_doc_access", %{
                 "doc" => "https://acme.feishu.cn/wiki/WikiNode0001",
                 "account" => "feishu-ann",
                 "remark" => "Needs the launch plan"
               })

      assert [asked] = requests("POST", wiki)
      assert asked.authorization == "Bearer u-feishu-ann"
      assert asked.query == %{"type" => "wiki"}
      assert asked.body == %{"perm" => "view", "remark" => "Needs the launch plan"}

      for params <- [%{}, %{"account" => "app"}] do
        assert {:error, "Feishu takes an access request only from a person" <> _} =
                 worker_call(
                   ctx,
                   "feishu.request_doc_access",
                   Map.put(params, "doc", "DocxTok00001")
                 )
      end

      assert requests("POST", docx) == []

      FakeFeishu.route("POST", docx, 400, %{"code" => 1_063_006, "msg" => "apply quota exceeded"})

      assert {:error, "Feishu API error 1063006: this person has asked" <> _} =
               worker_call(ctx, "feishu.request_doc_access", %{
                 "doc" => "DocxTok00001",
                 "account" => "feishu-ray",
                 "perm" => "edit"
               })

      assert [%{query: %{"type" => "docx"}, body: %{"perm" => "edit"}}] = requests("POST", docx)
    end

    test "a cloud space and the wiki are walked as the app or as a person", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/drive/v1/files",
        ok(%{
          "files" => [%{"name" => "Plans", "type" => "folder", "token" => "fld1"}],
          "has_more" => false
        })
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/wiki/v2/spaces",
        ok(%{"items" => [%{"space_id" => "sp1", "name" => "Team"}], "has_more" => false})
      )

      assert {:ok, %{"files" => [%{"account" => "feishu-ann", "token" => "fld1"}]}} =
               worker_call(ctx, "feishu.list_drive_files", %{
                 "account" => "feishu-ann",
                 "folder" => "root1"
               })

      [listed] = requests("GET", "/open-apis/drive/v1/files")
      assert listed.authorization == "Bearer u-feishu-ann"
      assert listed.query["folder_token"] == "root1"

      assert {:ok, %{"files" => files}} = worker_call(ctx, "feishu.list_drive_files", %{})
      assert Enum.map(files, & &1["account"]) == ["app", "feishu-ray", "feishu-ann"]

      assert {:ok, _spaces} =
               worker_call(ctx, "feishu.list_wiki_spaces", %{"account" => "feishu-ray"})

      assert {:ok, _spaces} = worker_call(ctx, "feishu.list_wiki_spaces", %{"account" => "app"})

      assert requests("GET", "/open-apis/wiki/v2/spaces") |> Enum.map(& &1.authorization) ==
               ["Bearer u-feishu-ray", "Bearer t-docs"]
    end
  end

  describe "documents, spreadsheets and Base as the person who asked" do
    setup do
      previous = SystemsRuntime.get_env(:salix_im, :feishu_user_accounts_mod)
      SystemsRuntime.put_env(:salix_im, :feishu_user_accounts_mod, FakeAccounts)

      on_exit(fn ->
        if previous,
          do: SystemsRuntime.put_env(:salix_im, :feishu_user_accounts_mod, previous),
          else: SystemsRuntime.delete_env(:salix_im, :feishu_user_accounts_mod)
      end)

      :ok
    end

    test "a spreadsheet and a Base are read and labelled as the account", ctx do
      ifc_mode(ctx.group_id, "enforce")

      FakeFeishu.route(
        "GET",
        "/open-apis/sheets/v3/spreadsheets/Sheet0000001",
        ok(%{"spreadsheet" => %{"title" => "AR"}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/sheets/v3/spreadsheets/Sheet0000001/sheets/query",
        ok(%{"sheets" => [%{"sheet_id" => "sh01", "title" => "2026"}]})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseApp0001",
        ok(%{"app" => %{"name" => "Sales", "is_advanced" => false}})
      )

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseApp0001/tables",
        ok(%{"items" => [%{"table_id" => "tblOrders"}], "has_more" => false})
      )

      audience_routes("Sheet0000001", "closed", [
        %{"member_type" => "openchat", "member_id" => "oc_team", "perm" => "view"}
      ])

      audience_routes("BaseApp0001", "closed", [
        %{"member_type" => "openchat", "member_id" => "oc_team", "perm" => "view"}
      ])

      assert {:ok, %{"sheets" => [%{"sheet_id" => "sh01"}]} = sheet} =
               worker_call(ctx, "feishu.get_sheet", %{
                 "sheet" => "https://acme.feishu.cn/sheets/Sheet0000001",
                 "account" => "feishu-ann"
               })

      assert {:ok, %{"tables" => [%{"table_id" => "tblOrders"}]} = base} =
               worker_call(ctx, "feishu.get_base", %{
                 "base" => "BaseApp0001",
                 "account" => "feishu-ann"
               })

      # The audience the person may list labels the read, as for a document.
      assert sheet["__ifc__"] == %{"label" => ["scope|#{@connect_id}|oc_team"]}
      assert base["__ifc__"] == sheet["__ifc__"]

      # Every table, wiki and permission read runs as the person. The app
      # only classifies the chat the label names, for the IFC projection
      # (`SalixIM.IFC.Projection`), never a read of the table.
      as_app =
        for %{authorization: "Bearer t-docs"} = request <- FakeFeishu.requests(),
            uniq: true,
            do: {request.method, request.path}

      assert as_app == [{"GET", "/open-apis/im/v1/chats/oc_team"}]

      assert Enum.count(FakeFeishu.requests(), &(&1.authorization == "Bearer u-feishu-ann")) >= 6
    end

    test "a content write runs as the account, and sharing or deleting refuses one", ctx do
      FakeFeishu.route(
        "PUT",
        "/open-apis/docs_ai/v1/documents/DocxTok00001",
        ok(%{"result" => "success", "document" => %{"revision_id" => 3}})
      )

      assert {:ok, %{"revision_id" => 3}} =
               worker_call(ctx, "feishu.update_doc", %{
                 "doc" => "DocxTok00001",
                 "command" => "append",
                 "content" => "- done",
                 "account" => "feishu-ann"
               })

      assert [%{authorization: "Bearer u-feishu-ann"}] =
               requests("PUT", "/open-apis/docs_ai/v1/documents/DocxTok00001")

      for {api, params} <- [
            {"feishu.share_doc", %{"member_type" => "chat", "member_id" => "oc_team"}},
            {"feishu.delete_doc", %{}}
          ] do
        assert {:error, message} =
                 worker_call(
                   ctx,
                   api,
                   Map.merge(params, %{"doc" => "DocxTok00001", "account" => "feishu-ann"})
                 )

        assert message =~ "#{api} runs as the app only"
      end

      assert length(FakeFeishu.requests()) == 1
    end

    test "a denial names the next step for the identity that was denied", ctx do
      fetch = "/open-apis/docs_ai/v1/documents/DocxTok00001/fetch"
      update = "/open-apis/docs_ai/v1/documents/DocxTok00001"
      FakeFeishu.route("POST", fetch, 403, %{"code" => 3_380_002, "msg" => "no permission"})
      FakeFeishu.route("PUT", update, 403, %{"code" => 1_770_032, "msg" => "forbidden"})

      read = %{"doc" => "DocxTok00001"}
      write = Map.merge(read, %{"command" => "append", "content" => "x"})

      # The app: read or write as the person who asked, signing them in first.
      assert {:error, as_app} = worker_call(ctx, "feishu.fetch_doc", read)
      assert as_app =~ "3380002"
      assert as_app =~ "account="
      assert as_app =~ "oauth.request_authorization"
      refute as_app =~ "request_doc_access"

      assert {:error, write_as_app} = worker_call(ctx, "feishu.update_doc", write)
      assert write_as_app =~ "account="
      assert write_as_app =~ "agree"
      assert write_as_app =~ "oauth.request_authorization"
      assert write_as_app =~ "docs:document.comment:create"
      refute as_app =~ "sheets:spreadsheet:readonly"

      # A table read as the app names the table scopes for the sign-in.
      FakeFeishu.route(
        "GET",
        "/open-apis/sheets/v3/spreadsheets/Sheet0000001",
        403,
        %{"code" => 131_006, "msg" => "permission denied"}
      )

      assert {:error, table_as_app} =
               worker_call(ctx, "feishu.get_sheet", %{"sheet" => "Sheet0000001"})

      assert table_as_app =~ "oauth.request_authorization"
      assert table_as_app =~ "scopes [sheets:spreadsheet:readonly, bitable:app:readonly]"

      # The person: ask the owner for access as them.
      assert {:error, as_person} =
               worker_call(ctx, "feishu.fetch_doc", Map.put(read, "account", "feishu-ann"))

      assert as_person =~ "feishu.request_doc_access"
      refute as_person =~ "oauth.request_authorization"

      assert {:error, write_as_person} =
               worker_call(ctx, "feishu.update_doc", Map.put(write, "account", "feishu-ann"))

      assert write_as_person =~ "feishu.request_doc_access and perm edit"

      for message <- [as_app, write_as_app, as_person, write_as_person],
          do: refute(message =~ ~r/Excel|CSV/)
    end

    test "a missing scope names the tenant admin, not sharing", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/sheets/v3/spreadsheets/Sheet0000001",
        400,
        %{
          "code" => 99_991_672,
          "msg" =>
            "Access denied. One of the following scopes is required: [sheets:spreadsheet:readonly, sheets:spreadsheet]"
        }
      )

      assert {:error, message} =
               worker_call(ctx, "feishu.get_sheet", %{"sheet" => "Sheet0000001"})

      assert message =~ "sheets:spreadsheet:readonly"
      assert message =~ "developer console"
      assert message =~ "Sharing the document does not help"

      FakeFeishu.route(
        "GET",
        "/open-apis/bitable/v1/apps/BaseApp0001",
        400,
        %{
          "code" => 99_991_679,
          "msg" =>
            "Unauthorized. required one of these privileges under the user identity: [bitable:app:readonly]"
        }
      )

      assert {:error, message} =
               worker_call(ctx, "feishu.get_base", %{
                 "base" => "BaseApp0001",
                 "account" => "feishu-ann"
               })

      assert message =~ "scopes [bitable:app:readonly]"
      assert message =~ "oauth.request_authorization"
      assert message =~ "20027"
    end

    test "the owner of a spreadsheet or a Base is asked by its own type", ctx do
      sheet = "/open-apis/drive/v1/permissions/Sheet0000001/members/apply"
      base = "/open-apis/drive/v1/permissions/BaseApp0001/members/apply"
      FakeFeishu.route("POST", sheet, ok(%{}))
      FakeFeishu.route("POST", base, ok(%{}))

      assert {:ok, %{"doc_type" => "sheet"}} =
               worker_call(ctx, "feishu.request_doc_access", %{
                 "doc" => "https://acme.feishu.cn/sheets/Sheet0000001?sheet=sh01",
                 "account" => "feishu-ann"
               })

      assert {:ok, %{"doc_type" => "bitable"}} =
               worker_call(ctx, "feishu.request_doc_access", %{
                 "doc" => "BaseApp0001",
                 "doc_type" => "bitable",
                 "account" => "feishu-ann",
                 "perm" => "edit"
               })

      assert [%{query: %{"type" => "sheet"}, authorization: "Bearer u-feishu-ann"}] =
               requests("POST", sheet)

      assert [%{query: %{"type" => "bitable"}, body: %{"perm" => "edit"}}] =
               requests("POST", base)
    end
  end
end
