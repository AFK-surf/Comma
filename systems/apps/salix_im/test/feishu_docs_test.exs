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
          {status, answer} when is_function(answer, 1) -> {status, answer.(conn.query_params)}
          nil -> {404, %{"code" => 1_770_002, "msg" => "not found"}}
          route -> route
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

    test "a search runs as every active account and names who found each meeting", ctx do
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

      # The expired account is skipped.
      assert Enum.map(meetings, & &1["account"]) == ["feishu-ray", "feishu-ann"]

      assert pages == [
               %{"account" => "feishu-ray", "page_token" => "p2"},
               %{"account" => "feishu-ann", "page_token" => "p2"}
             ]

      # A page token is one account's; the next page names that account.
      assert {:error, "a page_token belongs to one account" <> _} =
               worker_call(ctx, "feishu.search_meetings", %{
                 "query" => "Daily",
                 "page_token" => "p2"
               })

      [ray, ann] = requests("POST", "/open-apis/vc/v1/meetings/search")
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

    test "a read tries each account until one may see the meeting", ctx do
      FakeFeishu.route(
        "GET",
        "/open-apis/vc/v1/meetings/7002",
        ok(%{"meeting" => %{"topic" => "1:1"}})
      )

      assert {:ok, %{"account" => "feishu-ray", "recording" => "unavailable: " <> _}} =
               worker_call(ctx, "feishu.get_meeting", %{"meeting_id" => "7002"})

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

    test "without a signed-in account the bot says how to add one", ctx do
      SystemsRuntime.delete_env(:salix_im, :feishu_user_accounts_mod)

      assert {:error, "no Feishu account is signed in" <> _} =
               worker_call(ctx, "feishu.search_meetings", %{"query" => "Daily"})
    end
  end
end
