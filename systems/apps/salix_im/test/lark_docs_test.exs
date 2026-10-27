defmodule SalixIM.LarkDocsTest do
  @moduledoc """
  Lark cloud documents and Minutes through the Group's Lark connect: what
  the bot sends to Lark, which links it takes, how a read is labelled, where
  a write goes, and which agents may call the operations. A local Plug stands
  in for the Lark open platform.
  """

  use SystemsClock.Case, async: false

  alias SalixIM.Provider.Lark
  alias SalixIM.Provider.Lark.Docs
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.Keys

  @connect_id "cnx_lark_docs"

  defmodule FakeLark do
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

      case Agent.get(__MODULE__, &Map.get(&1.routes, {conn.method, conn.request_path})) do
        # The bytes of a file, as a download answers.
        {status, {:file, content_type, name, bytes}} ->
          conn
          |> put_resp_content_type(content_type)
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
          |> send_resp(status, bytes)

        # An answer that depends on the query, such as a page cursor.
        {status, answer} when is_function(answer, 1) ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            status,
            Jason.encode!(
              answer.(
                Map.put(
                  conn.query_params,
                  "__authorization",
                  conn |> get_req_header("authorization") |> List.first()
                )
              )
            )
          )

        route ->
          {status, response} = route || {404, %{"code" => 1_770_002, "msg" => "not found"}}

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(response))
      end
    end
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

    def put_ref(_agent_id, path, ref) do
      put(path, ref)
      {:ok, %{path: path}}
    end

    def file_ref(_agent_id, _path), do: {:error, "unused"}
    def read_ref_stream(_agent_id, _ref, _filename), do: {:error, "unused"}
  end

  defmodule FakeAccounts do
    @moduledoc "Two Lark people who signed in for the Group; a token names its account."
    @behaviour SalixIM.Ports.LarkUserAccounts

    @impl true
    def list(_group_id) do
      {:ok,
       [
         %{"alias" => "lark-ray", "open_id" => "ou_ray", "name" => "Ray", "status" => "active"},
         %{"alias" => "lark-ann", "open_id" => "ou_ann", "name" => "Ann", "status" => "active"}
       ]}
    end

    @impl true
    def access_token(_agent_id, alias_name), do: {:ok, "u-" <> alias_name}
  end

  defmodule ManyAccounts do
    @moduledoc "Twelve signed-in people; one of them labelled app."
    @behaviour SalixIM.Ports.LarkUserAccounts

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
            {:salix_im, :lark_api_base_url},
            {:salix_im, :agent_workspace_mod},
            {:salix_agent, :group_context_mod}
          ],
          do: {app, key, SystemsRuntime.get_env(app, key)}

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    SalixAgent.TestSupport.configure_control_fixtures!()

    start_supervised!(FakeLark)
    start_supervised!(FakeWorkspace)
    port = BanditServer.start!(fn p -> {Bandit, plug: FakeLark, port: p} end)
    SystemsRuntime.put_env(:salix_im, :lark_api_base_url, "http://127.0.0.1:#{port}/open-apis")
    SystemsRuntime.put_env(:salix_im, :agent_workspace_mod, FakeWorkspace)

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
      "provider" => "lark",
      "status" => "connected",
      "app_id" => "cli_docs",
      "app_secret" => "s",
      "tenant_access_token" => "t-docs"
    }

    {:ok, _} = SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, @connect_id), connect)
    SalixIM.Provider.Lark.API.reset_token_cache()

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
    FakeLark.route(
      "GET",
      "/open-apis/drive/v2/permissions/#{token}/public",
      ok(%{"permission_public" => %{"link_share_entity" => link}})
    )

    FakeLark.route(
      "GET",
      "/open-apis/drive/v1/permissions/#{token}/members",
      ok(%{"items" => members})
    )
  end

  defp requests(method, path),
    do: Enum.filter(FakeLark.requests(), &(&1.method == method and &1.path == path))

  describe "reading a document" do
    test "a wiki link is read as the bot and labelled by the chat it is shared with", ctx do
      ifc_mode(ctx.group_id, "enforce")

      FakeLark.route(
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

      FakeLark.route(
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
               Lark.call(ctx.router_id, ctx.connect, "lark.fetch_doc", %{
                 "doc" => "https://acme.larksuite.com/wiki/WikiNode0001?from=im",
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
               Lark.call(ctx.router_id, ctx.connect, "lark.fetch_doc", %{
                 "doc" => "WikiNode0001",
                 "doc_type" => "wiki"
               })
    end

    test "a tenant link reads as the space; an audience Lark will not disclose fails closed",
         ctx do
      ifc_mode(ctx.group_id, "enforce")

      for token <- ~w(DocxOpen0001 DocxShut0001) do
        FakeLark.route(
          "POST",
          "/open-apis/docs_ai/v1/documents/#{token}/fetch",
          ok(%{"document" => %{"content" => "body"}})
        )
      end

      audience_routes("DocxOpen0001", "tenant_readable", [])

      FakeLark.route(
        "GET",
        "/open-apis/drive/v2/permissions/DocxShut0001/public",
        ok(%{"permission_public" => %{"link_share_entity" => "closed"}})
      )

      FakeLark.route(
        "GET",
        "/open-apis/drive/v1/permissions/DocxShut0001/members",
        403,
        %{"code" => 1_063_002, "msg" => "permission denied"}
      )

      assert {:ok, open} =
               Lark.call(ctx.router_id, ctx.connect, "lark.fetch_doc", %{
                 "doc" => "DocxOpen0001"
               })

      assert open["__ifc__"] == %{"label" => ["space|#{@connect_id}"]}

      assert {:ok, shut} =
               Lark.call(ctx.router_id, ctx.connect, "lark.fetch_doc", %{
                 "doc" => "DocxShut0001"
               })

      assert shut["__ifc__"] == %{"label" => ["agent_private"]}
    end

    test "an image of a document is copied into the workspace under the document's label",
         ctx do
      ifc_mode(ctx.group_id, "enforce")
      audience_routes("DocxTok00001", "tenant_readable", [])

      FakeLark.route(
        "GET",
        "/open-apis/drive/v1/medias/boxImg0001/download",
        {:file, "image/png", "chart.png", "PNG-BYTES"}
      )

      assert {:ok, staged} =
               Lark.call(ctx.worker_id, ctx.connect, "lark.fetch_doc_media", %{
                 "doc" => "DocxTok00001",
                 "file_token" => "boxImg0001"
               })

      assert %{"file_name" => "chart.png", "mime_type" => "image/png", "size" => 9} = staged
      assert staged["vfs_path"] =~ ~r"\A/lark/docs/media/[0-9a-f]{20}-chart\.png\z"
      assert staged["__ifc__"] == %{"label" => ["space|#{@connect_id}"]}
      assert FakeWorkspace.get(staged["vfs_path"])
    end
  end

  describe "creating a document" do
    test "a new document is closed to its link and shared with the source chat", ctx do
      FakeLark.route(
        "POST",
        "/open-apis/docs_ai/v1/documents",
        ok(%{
          "document" => %{
            "document_id" => "DocxNew00001",
            "revision_id" => 1,
            "url" => "https://acme.larksuite.com/docx/DocxNew00001"
          }
        })
      )

      FakeLark.route("PATCH", "/open-apis/drive/v2/permissions/DocxNew00001/public", ok(%{}))

      FakeLark.route(
        "POST",
        "/open-apis/drive/v1/permissions/DocxNew00001/members",
        ok(%{"member" => %{}})
      )

      assert {:ok, result} =
               Lark.call(ctx.router_id, ctx.connect, "lark.create_doc", %{
                 "title" => "Q3 <plan>",
                 "content" => "## Goals",
                 "share_chat_id" => "oc_team"
               })

      assert result["url"] == "https://acme.larksuite.com/docx/DocxNew00001"

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

      # Lark refuses `need_notification` from an app, so it is not sent.
      assert share.query == %{"type" => "docx"}
    end

    test "a document is not shared with a department: Lark does not let an app do it", ctx do
      assert {:error, "Lark does not let an app share a document with a department" <> _} =
               Lark.call(ctx.router_id, ctx.connect, "lark.share_doc", %{
                 "doc" => "https://acme.larksuite.com/docx/DocxShare0001",
                 "member_type" => "department",
                 "member_id" => "od_engineering"
               })

      assert FakeLark.requests() == []
    end

    test "a document whose link cannot be closed is deleted again", ctx do
      FakeLark.route(
        "POST",
        "/open-apis/docs_ai/v1/documents",
        ok(%{"document" => %{"document_id" => "DocxNew00002"}})
      )

      FakeLark.route(
        "PATCH",
        "/open-apis/drive/v2/permissions/DocxNew00002/public",
        400,
        %{"code" => 99_991_672, "msg" => "no permission"}
      )

      FakeLark.route(
        "DELETE",
        "/open-apis/drive/v1/files/DocxNew00002",
        ok(%{"task_id" => "t1"})
      )

      assert {:error, error} =
               Lark.call(ctx.router_id, ctx.connect, "lark.create_doc", %{
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
      FakeLark.route(
        "PUT",
        "/open-apis/docs_ai/v1/documents/DocxTok00001",
        ok(%{
          "result" => "success",
          "document" => %{"revision_id" => 9, "new_blocks" => [%{"block_id" => "blkNew"}]},
          "warnings" => ["image skipped"]
        })
      )

      assert {:ok, result} =
               Lark.call(ctx.worker_id, ctx.connect, "lark.update_doc", %{
                 "doc" => "https://acme.larksuite.com/docx/DocxTok00001",
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

      FakeLark.route(
        "GET",
        "/open-apis/docx/v1/documents/DocxTok00001/blocks/DocxTok00001",
        ok(%{"block" => %{"block_id" => "DocxTok00001", "children" => ["b1", "b2"]}})
      )

      FakeLark.route(
        "POST",
        "/open-apis/docx/v1/documents/DocxTok00001/blocks/DocxTok00001/children",
        ok(%{"children" => [%{"block_id" => "blkImg"}]})
      )

      FakeLark.route(
        "POST",
        "/open-apis/drive/v1/medias/upload_all",
        ok(%{"file_token" => "boxImg"})
      )

      FakeLark.route(
        "PATCH",
        "/open-apis/docx/v1/documents/DocxTok00001/blocks/batch_update",
        ok(%{})
      )

      assert {:ok, %{"block_id" => "blkImg", "file_token" => "boxImg", "media_type" => "image"}} =
               Lark.call(ctx.worker_id, ctx.connect, "lark.insert_doc_media", %{
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

      FakeLark.route(
        "POST",
        "/open-apis/drive/v1/medias/upload_all",
        400,
        %{"code" => 1_061_045, "msg" => "upload failed"}
      )

      FakeLark.route(
        "DELETE",
        "/open-apis/docx/v1/documents/DocxTok00001/blocks/DocxTok00001/children/batch_delete",
        ok(%{})
      )

      assert {:error, error} =
               Lark.call(ctx.worker_id, ctx.connect, "lark.insert_doc_media", %{
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

      FakeLark.route(
        "GET",
        "/open-apis/minutes/v1/minutes/obusminute001",
        ok(%{"minute" => %{"title" => "Weekly", "token" => "obusminute001"}})
      )

      FakeLark.route(
        "GET",
        "/open-apis/minutes/v1/minutes/obusminute001/artifacts",
        ok(%{
          "summary" => "Ship next week",
          "minute_todos" => [%{"content" => "Write the release notes"}],
          "minute_chapters" => [%{"title" => "release"}],
          "transcript" => "Speaker 1: we ship next week."
        })
      )

      audience_routes("obusminute001", "closed", [
        %{"member_type" => "openchat", "member_id" => "oc_team"}
      ])

      assert {:ok, result} =
               Lark.call(ctx.worker_id, ctx.connect, "lark.get_minute", %{
                 "minute" => "https://acme.larksuite.com/minutes/obusminute001?from=im",
                 "include" => "summary,todos,transcript"
               })

      assert result["title"] == "Weekly"

      assert result["artifacts"] == %{
               "summary" => "Ship next week",
               "todos" => [%{"content" => "Write the release notes"}],
               "transcript" => "Speaker 1: we ship next week."
             }

      assert result["__ifc__"] == %{"label" => ["scope|#{@connect_id}|oc_team"]}

      assert [members] = requests("GET", "/open-apis/drive/v1/permissions/obusminute001/members")
      assert members.query["type"] == "minutes"
    end

    test "search sends the filters Lark expects and needs at least one", ctx do
      FakeLark.route(
        "POST",
        "/open-apis/minutes/v1/minutes/search",
        ok(%{"items" => [%{"token" => "obusminute001", "avatar" => "x"}], "has_more" => false})
      )

      assert {:ok, %{"minutes" => [%{"token" => "obusminute001"} = item]}} =
               Lark.call(ctx.router_id, ctx.connect, "lark.list_minutes", %{
                 "query" => "release",
                 "participant_ids" => ["ou_a"],
                 "start" => "2026-10-01",
                 "page_size" => 100
               })

      refute Map.has_key?(item, "avatar")

      assert [search] = requests("POST", "/open-apis/minutes/v1/minutes/search")
      assert search.query == %{"page_size" => "30"}

      assert search.body == %{
               "query" => "release",
               "sorter" => "create_time_desc",
               "filter" => %{
                 "participant_ids" => ["ou_a"],
                 "create_time" => %{"start_time" => "2026-10-01T00:00:00Z"}
               }
             }

      assert {:error, "pass at least one of query, owner_ids, participant_ids, start, or end"} =
               Lark.call(ctx.router_id, ctx.connect, "lark.list_minutes", %{})
    end

    test "media is fetched only from an HTTPS link Lark returned", ctx do
      FakeLark.route(
        "GET",
        "/open-apis/minutes/v1/minutes/obusminute001/media",
        ok(%{"download_url" => "http://127.0.0.1:1/media.mp4"})
      )

      assert {:error, "Lark returned no usable download_url for this recording"} =
               Lark.call(ctx.worker_id, ctx.connect, "lark.fetch_minute_media", %{
                 "minute" => "obusminute001"
               })
    end
  end

  describe "the links a Lark connect takes" do
    test "a larksuite.com link names its document; a Feishu link belongs to the Feishu connect",
         ctx do
      assert {:ok, %{kind: "docx", token: "DocxTok00001"}} =
               Docs.parse_ref("https://acme.larksuite.com/docx/DocxTok00001?from=im", "")

      assert {:ok, %{kind: "wiki", token: "WikiNode0001"}} =
               Docs.parse_ref("https://acme.jp.larksuite.com/wiki/WikiNode0001", "")

      for link <- ~w(https://acme.feishu.cn/docx/DocxTok00001
                     https://acme.larkoffice.com/wiki/WikiNode0001) do
        assert {:error, error} =
                 Lark.call(ctx.router_id, ctx.connect, "lark.fetch_doc", %{"doc" => link})

        assert error =~ "use the Feishu connect"
      end

      # A host that only ends like Lark's is not Lark's.
      assert {:error, "unsupported document host \"evil-larksuite.com\"" <> _rest} =
               Lark.call(ctx.router_id, ctx.connect, "lark.fetch_doc", %{
                 "doc" => "https://evil-larksuite.com/docx/DocxTok00001"
               })

      assert {:error, error} =
               Lark.call(ctx.router_id, ctx.connect, "lark.get_minute", %{
                 "minute" => "https://acme.feishu.cn/minutes/obcnminute001"
               })

      assert error =~ "use the Feishu connect"

      assert {:error, "unsupported Minutes host" <> _rest} =
               Lark.call(ctx.router_id, ctx.connect, "lark.get_minute", %{
                 "minute" => "https://example.com/minutes/obusminute001"
               })

      # Nothing was asked of Lark for a link it does not own.
      assert FakeLark.requests() == []

      # The Feishu connect refuses the Lark link in its turn.
      assert {:error, error} =
               SalixIM.Provider.Feishu.Docs.parse_ref(
                 "https://acme.larksuite.com/docx/DocxTok00001",
                 ""
               )

      assert error =~ "not supported by this Feishu connection"
    end

    test "a new document without a link from Lark gets a larksuite.com link", ctx do
      FakeLark.route(
        "POST",
        "/open-apis/docs_ai/v1/documents",
        ok(%{"document" => %{"document_id" => "DocxNew00003"}})
      )

      FakeLark.route("PATCH", "/open-apis/drive/v2/permissions/DocxNew00003/public", ok(%{}))

      assert {:ok,
              %{"url" => "https://www.larksuite.com/docx/DocxNew00003", "shared_with" => nil}} =
               Lark.call(ctx.router_id, ctx.connect, "lark.create_doc", %{"title" => "Plan"})
    end
  end

  describe "who may call the document operations" do
    test "a worker holds every read, document and Minutes operation and no messaging write",
         ctx do
      FakeLark.route(
        "POST",
        "/open-apis/docs_ai/v1/documents/DocxTok00001/fetch",
        ok(%{"document" => %{"content" => "body"}})
      )

      FakeLark.route(
        "GET",
        "/open-apis/minutes/v1/minutes/obusminute001",
        ok(%{"minute" => %{"title" => "Weekly"}})
      )

      FakeLark.route("GET", "/open-apis/im/v1/chats/oc_team", ok(%{"name" => "Daily SyncUp"}))

      assert {:ok, %{"content" => "body"}} =
               SalixIM.Provider.call_api(ctx.worker_id, "lark", "lark.fetch_doc", %{
                 "connect_id" => @connect_id,
                 "params" => %{"doc" => "DocxTok00001"}
               })

      assert {:ok, %{"title" => "Weekly"}} =
               SalixIM.Provider.call_api(ctx.worker_id, "lark", "lark.get_minute", %{
                 "connect_id" => @connect_id,
                 "params" => %{"minute" => "obusminute001"}
               })

      assert {:ok, %{"name" => "Daily SyncUp"}} =
               SalixIM.Provider.call_api(ctx.worker_id, "lark", "lark.get_chat", %{
                 "connect_id" => @connect_id,
                 "params" => %{"chat_id" => "oc_team"}
               })

      for {api, params} <- [
            {"lark.send_message", %{"chat_id" => "oc_team", "text" => "hi"}},
            {"lark.add_reaction", %{"message_id" => "om_1", "emoji_type" => "OK"}},
            {"lark.post_task_card",
             %{"conversation_id" => "c", "chat_id" => "oc_team", "message_id" => "om_1"}}
          ] do
        assert {:error, "operation is not available to this agent role"} =
                 SalixIM.Provider.call_api(ctx.worker_id, "lark", api, %{
                   "connect_id" => @connect_id,
                   "params" => params
                 })
      end

      # Only the three reads above reached Lark.
      assert Enum.map(FakeLark.requests(), & &1.path) == [
               "/open-apis/docs_ai/v1/documents/DocxTok00001/fetch",
               "/open-apis/minutes/v1/minutes/obusminute001",
               "/open-apis/im/v1/chats/oc_team"
             ]

      assert {:ok, manual} = SalixIM.Provider.provider_manual("lark", ctx.worker_id)
      worker_apis = manual["apis"] |> Enum.map(& &1["name"]) |> Enum.sort()

      assert worker_apis ==
               Enum.sort(~w(lark.get_chat_history lark.get_thread_replies lark.get_message
                            lark.search_messages lark.list_chat_files
                            lark.fetch_message_resource lark.list_reactions lark.list_pins
                            lark.list_chats lark.get_chat lark.list_chat_members lark.get_user
                            lark.list_observed_chats lark.list_observed_users
                            lark.lookup_users lark.list_contact_scopes lark.list_departments
                            lark.list_department_users
                            lark.fetch_doc lark.list_doc_comments lark.list_doc_members
                            lark.fetch_doc_media lark.list_wiki_spaces lark.list_wiki_nodes
                            lark.create_doc lark.update_doc lark.insert_doc_media
                            lark.add_doc_comment lark.reply_doc_comment
                            lark.resolve_doc_comment lark.share_doc lark.remove_doc_member
                            lark.update_doc_link_share lark.delete_doc lark.get_minute
                            lark.list_minutes lark.fetch_minute_media
                            lark.request_minute_access lark.list_accounts
                            lark.search_docs lark.list_drive_files
                            lark.search_meetings lark.get_meeting lark.get_note))

      assert {:ok, connects} = SalixIM.Provider.list_connects(ctx.worker_id)
      assert Enum.any?(connects, &(&1["connect_id"] == @connect_id))
    end

    test "the router keeps the messaging operations and has the document ones", ctx do
      assert {:ok, manual} = SalixIM.Provider.provider_manual("lark", ctx.router_id)
      names = Enum.map(manual["apis"], & &1["name"])

      assert "lark.send_message" in names
      assert "lark.fetch_doc" in names
      assert "lark.get_minute" in names

      FakeLark.route(
        "GET",
        "/open-apis/wiki/v2/spaces",
        ok(%{"items" => [%{"space_id" => "sp1"}], "has_more" => false})
      )

      assert {:ok, %{"spaces" => [%{"space_id" => "sp1"}]}} =
               SalixIM.Provider.call_api(ctx.router_id, "lark", "lark.list_wiki_spaces", %{
                 "connect_id" => @connect_id,
                 "params" => %{}
               })
    end
  end

  describe "a write's destination" do
    defp destination(ctx, api, params) do
      {class, descriptor} =
        SalixAgent.IFC.Destination.describe(
          "im_api." <> api,
          Map.put(params, "connect_id", @connect_id),
          %{}
        )

      {:ok, reply} =
        SalixIM.IFC.Facts.resolve(%{
          "tenant_id" => ctx.connect["tenant_id"],
          "group_id" => ctx.group_id,
          "atoms" => [],
          "destination" => descriptor
        })

      {class, reply["destination"]}
    end

    test "is the space unless the document's link is open to anyone, and public when unknown",
         ctx do
      ifc_mode(ctx.group_id, "enforce")
      audience_routes("DocxTenant01", "closed", [])
      audience_routes("DocxPublic01", "anyone_readable", [])

      assert {:egress, %{"label" => ["space|" <> @connect_id], "writers" => "any"}} =
               destination(ctx, "lark.update_doc", %{
                 "doc" => "https://acme.larksuite.com/docx/DocxTenant01",
                 "command" => "append",
                 "content" => "x"
               })

      assert {:egress, %{"label" => ["public"], "writers" => "any"}} =
               destination(ctx, "lark.add_doc_comment", %{"doc" => "DocxPublic01", "text" => "x"})

      assert {:egress, %{"label" => ["public"], "writers" => "unknown"}} =
               destination(ctx, "lark.insert_doc_media", %{
                 "doc" => "DocxMissing1",
                 "path" => "/a"
               })

      # The link setting was read from Lark with the document's own type.
      assert [setting] = requests("GET", "/open-apis/drive/v2/permissions/DocxTenant01/public")
      assert setting.query["type"] == "docx"

      # A Feishu link is not a document of this connect: nothing vouches for it.
      assert {:egress, %{"label" => ["public"], "writers" => "unknown"}} =
               destination(ctx, "lark.update_doc", %{
                 "doc" => "https://acme.feishu.cn/docx/DocxTenant01",
                 "command" => "append",
                 "content" => "x"
               })
    end

    test "a new document under a folder takes the folder's link setting", ctx do
      ifc_mode(ctx.group_id, "enforce")
      audience_routes("FolderTok001", "tenant_readable", [])

      assert {:egress, %{"label" => ["space|" <> @connect_id], "writers" => "any"}} =
               destination(ctx, "lark.create_doc", %{
                 "title" => "Plan",
                 "parent" => "https://acme.larksuite.com/drive/folder/FolderTok001"
               })

      assert [setting] = requests("GET", "/open-apis/drive/v2/permissions/FolderTok001/public")
      assert setting.query["type"] == "folder"
    end

    test "a document of a Lark connect is not decided through the Feishu path", ctx do
      ifc_mode(ctx.group_id, "enforce")
      audience_routes("DocxTenant01", "closed", [])

      {:ok, reply} =
        SalixIM.IFC.Facts.resolve(%{
          "tenant_id" => ctx.connect["tenant_id"],
          "group_id" => ctx.group_id,
          "atoms" => [],
          "destination" => %{
            "kind" => "provider_document",
            "provider" => "feishu",
            "connect_id" => @connect_id,
            "document" => "DocxTenant01",
            "document_type" => ""
          }
        })

      assert reply["destination"] == %{"label" => ["public"], "writers" => "unknown"}
      assert FakeLark.requests() == []
    end
  end

  describe "meetings as a signed-in account" do
    setup do
      previous = SystemsRuntime.get_env(:salix_im, :lark_user_accounts_mod)
      SystemsRuntime.put_env(:salix_im, :lark_user_accounts_mod, FakeAccounts)

      on_exit(fn ->
        if previous,
          do: SystemsRuntime.put_env(:salix_im, :lark_user_accounts_mod, previous),
          else: SystemsRuntime.delete_env(:salix_im, :lark_user_accounts_mod)
      end)

      :ok
    end

    defp worker_call(ctx, api, params) do
      SalixIM.Provider.call_api(ctx.worker_id, "lark", api, %{
        "connect_id" => @connect_id,
        "params" => params
      })
    end

    test "a search runs as the app and every signed-in account and names who found each meeting",
         ctx do
      FakeLark.route(
        "POST",
        "/open-apis/vc/v1/meetings/search",
        ok(%{
          "items" => [%{"id" => "7001", "display_info" => "Ditto Daily"}],
          "has_more" => true,
          "page_token" => "p2"
        })
      )

      assert {:ok, %{"meetings" => meetings, "failed_accounts" => [], "next_pages" => pages}} =
               worker_call(ctx, "lark.search_meetings", %{
                 "query" => "Daily",
                 "start" => "2026-10-19"
               })

      assert Enum.map(meetings, & &1["account"]) == ["app", "lark-ray", "lark-ann"]

      # A page token is one account's; the next page names that account.
      assert {:error, "a page_token belongs to one account" <> _} =
               worker_call(ctx, "lark.search_meetings", %{
                 "query" => "Daily",
                 "page_token" => "p2"
               })

      assert pages == [
               %{"account" => "app", "page_token" => "p2"},
               %{"account" => "lark-ray", "page_token" => "p2"},
               %{"account" => "lark-ann", "page_token" => "p2"}
             ]

      [app, ray, ann] = requests("POST", "/open-apis/vc/v1/meetings/search")
      assert app.authorization == "Bearer t-docs"
      assert ray.authorization == "Bearer u-lark-ray"
      assert ann.authorization == "Bearer u-lark-ann"

      assert ray.body == %{
               "query" => "Daily",
               "meeting_filter" => %{"start_time" => %{"start_time" => "2026-10-19T00:00:00Z"}}
             }
    end

    test "a meeting leads to its notes, transcript and recording, read as that person", ctx do
      FakeLark.route(
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

      FakeLark.route(
        "GET",
        "/open-apis/vc/v1/meetings/7001/recording",
        ok(%{"recording" => %{"url" => "https://x.larksuite.com/minutes/obusdaily0001"}})
      )

      FakeLark.route(
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

      FakeLark.route(
        "POST",
        "/open-apis/docs_ai/v1/documents/DocxNotes001/fetch",
        ok(%{"document" => %{"content" => "Decisions"}})
      )

      assert {:ok,
              %{
                "account" => "lark-ann",
                "note_id" => "note_1",
                "minute_token" => "obusdaily0001"
              }} =
               worker_call(ctx, "lark.get_meeting", %{
                 "meeting_id" => "7001",
                 "account" => "ou_ann"
               })

      assert {:ok, %{"note_doc_token" => "DocxNotes001", "verbatim_doc_token" => "DocxVerbatim1"}} =
               worker_call(ctx, "lark.get_note", %{"note_id" => "note_1", "account" => "lark-ann"})

      assert {:ok, %{"content" => "Decisions"}} =
               worker_call(ctx, "lark.fetch_doc", %{
                 "doc" => "DocxNotes001",
                 "account" => "lark-ann"
               })

      # Every read went to Lark as Ann, none as the bot.
      assert FakeLark.requests() |> Enum.map(& &1.authorization) |> Enum.uniq() ==
               ["Bearer u-lark-ann"]
    end

    test "a unified note's transcript is read page by page, as the account", ctx do
      FakeLark.route(
        "GET",
        "/open-apis/vc/v1/notes/note_u",
        ok(%{"note" => %{"artifacts" => [], "note_display_type" => 2}})
      )

      FakeLark.route(
        "GET",
        "/open-apis/vc/v1/notes/note_u/unified_note_transcript",
        ok(%{"transcript" => %{"markdown" => "Ray: done."}, "has_more" => false})
      )

      assert {:ok, %{"display_type" => "unified", "transcript" => "Ray: done."}} =
               worker_call(ctx, "lark.get_note", %{
                 "note_id" => "note_u",
                 "account" => "lark-ray",
                 "include_transcript" => true
               })

      [page] = requests("GET", "/open-apis/vc/v1/notes/note_u/unified_note_transcript")
      assert page.query == %{"format" => "markdown", "locale" => "zh_cn", "page_size" => "200"}
      assert page.authorization == "Bearer u-lark-ray"

      # Two pages join in order; the second is asked for by the first's cursor.
      FakeLark.route(
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

      assert {:ok, %{"transcript" => "Ray: done. Ann: next."}} =
               worker_call(ctx, "lark.get_note", %{
                 "note_id" => "note_u",
                 "account" => "lark-ray",
                 "include_transcript" => true
               })

      assert [_single, _first, %{query: %{"cursor_id" => "c2"}}] =
               requests("GET", "/open-apis/vc/v1/notes/note_u/unified_note_transcript")

      # A transcript longer than one tool result is put in the workspace whole.
      long = String.duplicate("Ray: the long stand-up goes on. ", 2_500)

      FakeLark.route(
        "GET",
        "/open-apis/vc/v1/notes/note_u/unified_note_transcript",
        ok(%{"transcript" => %{"markdown" => long}, "has_more" => false})
      )

      assert {:ok,
              %{
                "transcript_truncated" => true,
                "vfs_path" => "/lark/notes/note_u-transcript.md" = path,
                "transcript" => head
              }} =
               worker_call(ctx, "lark.get_note", %{
                 "note_id" => "note_u",
                 "account" => "lark-ray",
                 "include_transcript" => true
               })

      assert byte_size(long) > 60_000
      assert FakeWorkspace.get(path) == long
      assert String.starts_with?(long, head)

      # A page that says there is more without a new cursor fails the read.
      FakeLark.route(
        "GET",
        "/open-apis/vc/v1/notes/note_u/unified_note_transcript",
        ok(%{"transcript" => %{"markdown" => "x"}, "has_more" => true})
      )

      assert {:error, "Lark's transcript pages stopped advancing" <> _} =
               worker_call(ctx, "lark.get_note", %{
                 "note_id" => "note_u",
                 "account" => "lark-ray",
                 "include_transcript" => "true"
               })
    end

    test "a read tries each account until one may see the meeting", ctx do
      # The app may not see this meeting; Ray may.
      FakeLark.route("GET", "/open-apis/vc/v1/meetings/7002", fn
        %{"__authorization" => "Bearer t-docs"} ->
          %{"code" => 121_005, "msg" => "no permission"}

        _person ->
          ok(%{"meeting" => %{"topic" => "1:1"}})
      end)

      assert {:ok, %{"account" => "lark-ray", "recording" => "unavailable: " <> _}} =
               worker_call(ctx, "lark.get_meeting", %{"meeting_id" => "7002"})

      # account=app reads as the app alone.
      assert {:error, _refused} =
               worker_call(ctx, "lark.get_meeting", %{"meeting_id" => "7002", "account" => "app"})

      assert {:error, "no signed-in Lark account lark-zoe; lark.list_accounts names them"} =
               worker_call(ctx, "lark.get_note", %{"note_id" => "n", "account" => "lark-zoe"})
    end

    test "without a signed-in account the app searches alone and says how a person signs in",
         ctx do
      SystemsRuntime.delete_env(:salix_im, :lark_user_accounts_mod)

      FakeLark.route(
        "POST",
        "/open-apis/vc/v1/meetings/search",
        ok(%{"items" => [%{"id" => "7003"}], "has_more" => false})
      )

      assert {:ok, %{"meetings" => [%{"account" => "app"}], "guidance" => guidance}} =
               worker_call(ctx, "lark.search_meetings", %{"query" => "Daily"})

      assert guidance =~ "oauth.request_authorization with provider lark"

      assert [%{authorization: "Bearer t-docs"}] =
               requests("POST", "/open-apis/vc/v1/meetings/search")
    end

    test "documents and wiki pages are found by keyword and read without a link", ctx do
      FakeLark.route(
        "POST",
        "/open-apis/search/v2/doc_wiki/search",
        ok(%{
          "res_units" => [
            %{
              "title_highlighted" => "Ditto x RC <h>Daily</h> SyncUp",
              "entity_type" => "DOC",
              "result_meta" => %{
                "url" => "https://x.larksuite.com/docx/DocxDaily0001",
                "token" => "DocxDaily0001",
                "doc_types" => "DOCX"
              }
            }
          ],
          "has_more" => false
        })
      )

      FakeLark.route(
        "POST",
        "/open-apis/docs_ai/v1/documents/DocxDaily0001/fetch",
        ok(%{"document" => %{"content" => "Decided: cloud browser."}})
      )

      assert {:ok, %{"documents" => hits, "failed_accounts" => []}} =
               worker_call(ctx, "lark.search_docs", %{"query" => "Daily"})

      assert Enum.map(hits, & &1["account"]) == ["app", "lark-ray", "lark-ann"]

      assert %{
               "title" => "Ditto x RC Daily SyncUp",
               "url" => "https://x.larksuite.com/docx/DocxDaily0001",
               "token" => "DocxDaily0001"
             } = hd(hits)

      [app, ray, _ann] = requests("POST", "/open-apis/search/v2/doc_wiki/search")
      assert app.authorization == "Bearer t-docs"
      assert ray.authorization == "Bearer u-lark-ray"

      assert ray.body == %{
               "query" => "Daily",
               "page_size" => 15,
               "doc_filter" => %{},
               "wiki_filter" => %{}
             }

      # A hit is read as the account that found it.
      assert {:ok, %{"content" => "Decided: cloud browser."}} =
               worker_call(ctx, "lark.fetch_doc", %{
                 "doc" => "https://x.larksuite.com/docx/DocxDaily0001",
                 "account" => "lark-ray"
               })

      assert List.last(requests("POST", "/open-apis/docs_ai/v1/documents/DocxDaily0001/fetch")).authorization ==
               "Bearer u-lark-ray"
    end

    test "a search is labelled by the identities whose items it returns", ctx do
      ifc_mode(ctx.group_id, "enforce")

      hit = %{
        "title_highlighted" => "Plan",
        "result_meta" => %{
          "url" => "https://x.larksuite.com/docx/DocxPlan00001",
          "token" => "DocxPlan00001"
        }
      }

      route = fn app_answer ->
        FakeLark.route("POST", "/open-apis/search/v2/doc_wiki/search", fn
          %{"__authorization" => "Bearer t-docs"} -> app_answer
          %{"__authorization" => "Bearer u-lark-ray"} -> ok(%{"res_units" => [hit]})
          _ann -> ok(%{"res_units" => []})
        end)
      end

      route.(ok(%{"res_units" => []}))

      assert {:ok, %{"__ifc__" => ray_only}} =
               worker_call(ctx, "lark.search_docs", %{"query" => "Plan", "account" => "lark-ray"})

      refute ray_only == %{"label" => ["agent_private"]}

      # The app finds nothing, or fails: only Ray's items come back, labelled as Ray's.

      assert {:ok, %{"documents" => [%{"account" => "lark-ray"}], "__ifc__" => ^ray_only}} =
               worker_call(ctx, "lark.search_docs", %{"query" => "Plan"})

      route.(%{"code" => 99_991_672, "msg" => "no permission"})

      assert {:ok,
              %{
                "documents" => [_],
                "failed_accounts" => [%{"account" => "app"}],
                "__ifc__" => ^ray_only
              }} =
               worker_call(ctx, "lark.search_docs", %{"query" => "Plan"})

      # An item the app found has no audience this read can name.
      route.(ok(%{"res_units" => [hit]}))

      assert {:ok, %{"__ifc__" => %{"label" => ["agent_private"]}}} =
               worker_call(ctx, "lark.search_docs", %{"query" => "Plan"})
    end

    test "a search reads as ten identities per call and continues with accounts_from", ctx do
      SystemsRuntime.put_env(:salix_im, :lark_user_accounts_mod, ManyAccounts)

      FakeLark.route(
        "POST",
        "/open-apis/search/v2/doc_wiki/search",
        ok(%{
          "res_units" => [
            %{"title_highlighted" => "Plan", "result_meta" => %{"token" => "DocxPlan00001"}}
          ]
        })
      )

      assert {:ok, %{"documents" => first, "more_accounts" => %{"accounts_from" => 10}}} =
               worker_call(ctx, "lark.search_docs", %{"query" => "Plan"})

      # The app, then the person labelled app (named by open_id), then p1..p8.
      assert Enum.map(first, & &1["account"]) ==
               ["app", "ou_appy"] ++ for(n <- 1..8, do: "p#{n}")

      assert {:ok, %{"documents" => rest} = page} =
               worker_call(ctx, "lark.search_docs", %{"query" => "Plan", "accounts_from" => 10})

      assert Enum.map(rest, & &1["account"]) == ["p9", "p10", "p11"]
      refute Map.has_key?(page, "more_accounts")
      assert length(requests("POST", "/open-apis/search/v2/doc_wiki/search")) == 13

      # The person labelled app reads as themselves through that name; app is
      # the app.
      assert {:ok, _} =
               worker_call(ctx, "lark.search_docs", %{"query" => "Plan", "account" => "ou_appy"})

      assert {:ok, _} =
               worker_call(ctx, "lark.search_docs", %{"query" => "Plan", "account" => "app"})

      assert requests("POST", "/open-apis/search/v2/doc_wiki/search")
             |> Enum.take(-2)
             |> Enum.map(& &1.authorization) == ["Bearer u-app", "Bearer t-docs"]
    end

    test "a read tries ten identities per call and continues with accounts_from", ctx do
      SystemsRuntime.put_env(:salix_im, :lark_user_accounts_mod, ManyAccounts)

      # Only p9, the eleventh identity, may see the meeting.
      FakeLark.route("GET", "/open-apis/vc/v1/meetings/7009", fn
        %{"__authorization" => "Bearer u-p9"} -> ok(%{"meeting" => %{"topic" => "Late"}})
        _other -> %{"code" => 121_005, "msg" => "no permission"}
      end)

      assert {:error, refused} =
               worker_call(ctx, "lark.get_meeting", %{"meeting_id" => "7009"})

      assert refused =~ "call again with accounts_from 10"
      assert length(requests("GET", "/open-apis/vc/v1/meetings/7009")) == 10

      assert {:ok, %{"account" => "p9", "meeting" => %{"topic" => "Late"}}} =
               worker_call(ctx, "lark.get_meeting", %{
                 "meeting_id" => "7009",
                 "accounts_from" => 10
               })

      assert requests("GET", "/open-apis/vc/v1/meetings/7009")
             |> Enum.drop(10)
             |> Enum.map(& &1.authorization) == ["Bearer u-p9"]
    end

    test "a cloud space and the wiki are walked as the app or as a person", ctx do
      FakeLark.route(
        "GET",
        "/open-apis/drive/v1/files",
        ok(%{
          "files" => [%{"name" => "Plans", "type" => "folder", "token" => "fld1"}],
          "has_more" => false
        })
      )

      FakeLark.route(
        "GET",
        "/open-apis/wiki/v2/spaces",
        ok(%{"items" => [%{"space_id" => "sp1", "name" => "Team"}], "has_more" => false})
      )

      assert {:ok, %{"files" => [%{"account" => "lark-ann", "token" => "fld1"}]}} =
               worker_call(ctx, "lark.list_drive_files", %{
                 "account" => "lark-ann",
                 "folder" => "root1"
               })

      [listed] = requests("GET", "/open-apis/drive/v1/files")
      assert listed.authorization == "Bearer u-lark-ann"
      assert listed.query["folder_token"] == "root1"

      assert {:ok, %{"files" => files}} = worker_call(ctx, "lark.list_drive_files", %{})
      assert Enum.map(files, & &1["account"]) == ["app", "lark-ray", "lark-ann"]

      assert {:ok, _spaces} =
               worker_call(ctx, "lark.list_wiki_spaces", %{"account" => "lark-ray"})

      assert {:ok, _spaces} = worker_call(ctx, "lark.list_wiki_spaces", %{"account" => "app"})

      assert requests("GET", "/open-apis/wiki/v2/spaces") |> Enum.map(& &1.authorization) ==
               ["Bearer u-lark-ray", "Bearer t-docs"]
    end
  end
end
