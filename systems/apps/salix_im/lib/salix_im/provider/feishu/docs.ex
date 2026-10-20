defmodule SalixIM.Provider.Feishu.Docs do
  @moduledoc """
  Feishu cloud documents (Docx, including Docx pages in a wiki) through the
  connect's own tenant app.

  The connect's `tenant_access_token` is the only identity. The app can open a
  document only when the document is shared with a chat that includes the bot,
  shared with the app itself, or shared by link inside the tenant. There is no
  per-user Feishu authorization here; `mcp.feishu.*` remains the user-identity
  path.

  Content reads and writes use Feishu's agent-oriented `docs_ai/v1` API, the
  same API the official [larksuite/cli](https://github.com/larksuite/cli) uses
  for `docs +fetch`, `+create`, and `+update`. Comments, collaborators, link
  sharing, media, and wiki discovery use the Drive, Docx block, and Wiki APIs
  that the CLI uses for the same purposes.

  Every read carries the audience label that `SalixIM.IFC.ReadLabels` derives
  from the document's collaborators and link setting. The destination of a
  write is decided by `SalixAgent.IFC.Destination` and `SalixIM.IFC.Facts`.
  Writes are never retried: an ambiguous provider result is reported as an
  unknown outcome.
  """

  import SalixIM.Provider.Util, only: [str: 1, int_or: 2, maybe_put: 3]

  alias SalixIM.FeishuFiles
  alias SalixIM.IFC.ReadLabels
  alias SalixIM.Ports.AgentWorkspace
  alias SalixIM.Provider.Feishu.API

  @update_commands ~w(str_replace block_insert_after block_replace block_delete
                      block_copy_insert_after block_move_after overwrite append)
  @content_commands ~w(str_replace block_insert_after block_replace overwrite append)
  @formats ~w(markdown xml)
  @fetch_details ~w(simple with-ids full)
  @fetch_scopes ~w(full outline section range keyword)
  @perms ~w(view edit full_access)
  @link_share_entities ~w(closed tenant_readable tenant_editable)
  @member_types %{
    "chat" => {"openchat", "chat"},
    "user" => {"openid", "user"},
    "department" => {"opendepartmentid", "department"}
  }

  # Content above this size is staged into the agent workspace instead of the
  # tool result; the result keeps a bounded head of it.
  @inline_content_bytes 60_000
  @content_head_chars 12_000
  @max_page_size 50
  @max_media_upload_bytes 20 * 1024 * 1024
  @create_task_polls 10
  @create_task_poll_ms 2_000

  @spec call(String.t(), map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def call(agent_id, connect, api, params), do: do_call(agent_id, connect, api, params)

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  defp do_call(agent_id, connect, "feishu.fetch_doc", params) do
    with {:ok, ref} <- ref(params),
         {:ok, format} <- enum(params, "format", @formats, "markdown"),
         {:ok, detail} <- enum(params, "detail", @fetch_details, "simple"),
         {:ok, read_option} <- read_option(params),
         {:ok, data} <-
           API.post_read(
             connect,
             "/docs_ai/v1/documents/#{segment(ref.token)}/fetch",
             %{
               "format" => format,
               "extra_param" =>
                 Jason.encode!(%{
                   "enable_user_cite_reference_map" => true,
                   "include_comments" => true
                 }),
               "export_option" => export_option(detail)
             }
             |> maybe_put("read_option", read_option)
             |> maybe_put("revision_id", positive(params["revision_id"]))
           ),
         {:ok, result} <- fetch_result(agent_id, ref, format, data) do
      {:ok, labelled(result, connect, ref)}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_doc_comments", params) do
    with {:ok, ref} <- ref(params),
         {:ok, target} <- resolve(connect, ref),
         {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(connect, "/drive/v1/files/#{segment(target.obj_token)}/comments", %{
             file_type: "docx",
             user_id_type: "open_id",
             is_solved: bool_param(params["is_solved"]),
             page_size: page_size(params),
             page_token: page_token
           }) do
      {:ok,
       labelled(
         %{
           "comments" => List.wrap(data["items"]),
           "has_more" => data["has_more"] == true,
           "next_page_token" => str(data["page_token"])
         },
         connect,
         ref
       )}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_doc_members", params) do
    with {:ok, ref} <- ref(params),
         {:ok, target} <- resolve(connect, ref),
         {:ok, public} <- public_setting(connect, target),
         {:ok, members} <- members(connect, target) do
      {:ok,
       labelled(
         %{
           "document" => document_summary(target),
           "link_share_entity" => str(public["link_share_entity"]),
           "permission_public" => public,
           "members" => members
         },
         connect,
         ref
       )}
    end
  end

  defp do_call(agent_id, connect, "feishu.fetch_doc_media", params) do
    with {:ok, ref} <- ref(params),
         :ok <- require_param(params, "file_token"),
         {:ok, target} <- resolve(connect, ref),
         {:ok, staged} <-
           FeishuFiles.stage_doc_media(agent_id, connect, target.obj_token, params["file_token"]) do
      {:ok, labelled(Map.put(staged, "file_token", str(params["file_token"])), connect, ref)}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_wiki_spaces", params) do
    with {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(connect, "/wiki/v2/spaces", %{
             page_size: page_size(params),
             page_token: page_token
           }) do
      {:ok, page(data, "spaces")}
    end
  end

  defp do_call(_agent_id, connect, "feishu.list_wiki_nodes", params) do
    with :ok <- require_param(params, "space_id"),
         {:ok, page_token} <- page_token(params),
         {:ok, data} <-
           API.get(connect, "/wiki/v2/spaces/#{segment(params["space_id"])}/nodes", %{
             parent_node_token: str(params["parent_node_token"]),
             page_size: page_size(params),
             page_token: page_token
           }) do
      {:ok, page(data, "nodes")}
    end
  end

  # ---------------------------------------------------------------------------
  # Content writes
  # ---------------------------------------------------------------------------

  defp do_call(_agent_id, connect, "feishu.create_doc", params) do
    with {:ok, format} <- enum(params, "format", @formats, "markdown"),
         {:ok, content} <- create_content(params),
         {:ok, parent} <- parent(params),
         {:ok, share} <- share_target(params),
         {:ok, data} <-
           API.post(
             connect,
             "/docs_ai/v1/documents",
             %{"format" => format, "content" => content}
             |> maybe_put("parent_token", parent && parent.token)
           ),
         :ok <- operation_succeeded(data, "create"),
         {:ok, data} <- await_create_task(connect, data),
         {:ok, document_id} <- created_document_id(data) do
      document = data["document"] || %{}

      result =
        %{
          "document_id" => document_id,
          "revision_id" => document["revision_id"],
          "url" => blank_default(document["url"], "https://www.feishu.cn/docx/" <> document_id),
          "warnings" => List.wrap(data["warnings"])
        }

      # A document in the app's own space is readable by no one until it is
      # shared. Its link stays closed, so the explicit share target is its
      # whole audience; a parent folder or wiki node supplies its own.
      if parent do
        {:ok, maybe_share_created(connect, document_id, share, result)}
      else
        close_created_link(connect, document_id, share, result)
      end
    end
  end

  defp do_call(_agent_id, connect, "feishu.update_doc", params) do
    with {:ok, ref} <- ref(params),
         {:ok, body} <- update_body(params),
         {:ok, data} <- API.put(connect, "/docs_ai/v1/documents/#{segment(ref.token)}", body),
         :ok <- operation_succeeded(data, "update") do
      {:ok,
       %{
         "result" => str(data["result"]),
         "revision_id" => get_in(data, ["document", "revision_id"]),
         "new_blocks" => List.wrap(get_in(data, ["document", "new_blocks"])),
         "updated_blocks_count" => data["updated_blocks_count"],
         "warnings" => List.wrap(data["warnings"]),
         "tips" => str(data["tips"])
       }}
    end
  end

  defp do_call(agent_id, connect, "feishu.insert_doc_media", params) do
    with {:ok, ref} <- ref(params),
         :ok <- require_param(params, "path"),
         {:ok, media_type} <- media_type(params),
         {:ok, upload} <- read_upload(agent_id, params["path"]),
         :ok <- validate_media_size(upload.size),
         {:ok, target} <- resolve(connect, ref) do
      insert_media(connect, target.obj_token, media_type, upload, params)
    end
  end

  # ---------------------------------------------------------------------------
  # Comments
  # ---------------------------------------------------------------------------

  defp do_call(_agent_id, connect, "feishu.add_doc_comment", params) do
    with {:ok, ref} <- ref(params),
         :ok <- require_param(params, "text"),
         {:ok, target} <- resolve(connect, ref),
         {:ok, data} <-
           API.post(
             connect,
             "/drive/v1/files/#{segment(target.obj_token)}/new_comments",
             %{
               "file_type" => "docx",
               "reply_elements" => [%{"type" => "text", "text" => comment_text(params["text"])}]
             }
             |> maybe_put(
               "anchor",
               if(str(params["block_id"]) != "", do: %{"block_id" => str(params["block_id"])})
             )
           ) do
      {:ok, %{"comment_id" => str(data["comment_id"]), "document" => document_summary(target)}}
    end
  end

  defp do_call(_agent_id, connect, "feishu.reply_doc_comment", params) do
    with {:ok, ref} <- ref(params),
         :ok <- require_param(params, "comment_id"),
         :ok <- require_param(params, "text"),
         {:ok, target} <- resolve(connect, ref),
         {:ok, data} <-
           API.post(
             connect,
             "/drive/v1/files/#{segment(target.obj_token)}/comments/#{segment(params["comment_id"])}/replies?" <>
               URI.encode_query(%{"file_type" => "docx"}),
             %{
               "content" => %{
                 "elements" => [
                   %{
                     "type" => "text_run",
                     "text_run" => %{"text" => comment_text(params["text"])}
                   }
                 ]
               }
             }
           ) do
      {:ok, %{"reply_id" => str(data["reply_id"]), "comment_id" => str(params["comment_id"])}}
    end
  end

  defp do_call(_agent_id, connect, "feishu.resolve_doc_comment", params) do
    with {:ok, ref} <- ref(params),
         :ok <- require_param(params, "comment_id"),
         {:ok, target} <- resolve(connect, ref),
         solved = params["solved"] != false and str(params["solved"]) != "false",
         {:ok, _data} <-
           API.patch(
             connect,
             "/drive/v1/files/#{segment(target.obj_token)}/comments/#{segment(params["comment_id"])}?" <>
               URI.encode_query(%{"file_type" => "docx"}),
             %{"is_solved" => solved}
           ) do
      {:ok, %{"comment_id" => str(params["comment_id"]), "is_solved" => solved}}
    end
  end

  # ---------------------------------------------------------------------------
  # Collaborators, link sharing, deletion
  # ---------------------------------------------------------------------------

  defp do_call(_agent_id, connect, "feishu.share_doc", params) do
    with {:ok, ref} <- ref(params),
         {:ok, member} <- member(params),
         {:ok, perm} <- enum(params, "perm", @perms, "view"),
         {:ok, target} <- resolve(connect, ref),
         {:ok, data} <- add_member(connect, target.perm_token, target.perm_type, member, perm) do
      {:ok, %{"member" => data["member"] || data, "document" => document_summary(target)}}
    end
  end

  defp do_call(_agent_id, connect, "feishu.remove_doc_member", params) do
    with {:ok, ref} <- ref(params),
         {:ok, {member_type, kind, member_id}} <- member(params),
         {:ok, target} <- resolve(connect, ref),
         {:ok, _data} <-
           API.delete(
             connect,
             "/drive/v1/permissions/#{segment(target.perm_token)}/members/#{segment(member_id)}?" <>
               URI.encode_query(%{"type" => target.perm_type, "member_type" => member_type}),
             %{"type" => kind}
           ) do
      {:ok, %{"removed" => %{"member_type" => kind, "member_id" => member_id}}}
    end
  end

  defp do_call(_agent_id, connect, "feishu.update_doc_link_share", params) do
    with {:ok, ref} <- ref(params),
         {:ok, entity} <- enum(params, "link_share_entity", @link_share_entities, nil),
         {:ok, target} <- resolve(connect, ref),
         {:ok, data} <- set_link_share(connect, target.perm_token, target.perm_type, entity) do
      {:ok,
       %{"permission_public" => data["permission_public"] || %{"link_share_entity" => entity}}}
    end
  end

  defp do_call(_agent_id, connect, "feishu.delete_doc", params) do
    with {:ok, ref} <- ref(params),
         :ok <- deletable(ref),
         {:ok, data} <-
           API.delete(connect, "/drive/v1/files/#{segment(ref.token)}?type=docx") do
      {:ok, %{"deleted" => ref.token, "task_id" => str(data["task_id"])}}
    end
  end

  defp do_call(_agent_id, _connect, _api, _params),
    do: {:error, "unsupported Feishu document api"}

  # ---------------------------------------------------------------------------
  # Audience
  # ---------------------------------------------------------------------------

  @doc """
  The document's link setting and collaborators, as Feishu reports them to this
  app. `SalixIM.IFC.ReadLabels.for_document/2` turns it into a read label.

  Listing collaborators needs share permission on the document. Without it the
  result is an error, which every caller treats as an unknown audience.
  """
  @spec audience(map(), term()) :: {:ok, map()} | {:error, String.t()}
  def audience(connect, doc) do
    with {:ok, ref} <- parse_ref(doc, ""),
         {:ok, target} <- resolve(connect, ref),
         do: permission_audience(connect, target)
  end

  @doc """
  The audience of any Drive permission target (`perm_token`, `perm_type`),
  such as a Minutes recording, in the shape of `audience/2`.
  """
  @spec permission_audience(map(), %{perm_token: String.t(), perm_type: String.t()}) ::
          {:ok, map()} | {:error, String.t()}
  def permission_audience(connect, target) do
    with {:ok, public} <- public_setting(connect, target),
         {:ok, members} <- members(connect, target) do
      by_type = Enum.group_by(members, &str(&1["member_type"]), &str(&1["member_id"]))

      {:ok,
       %{
         "link_share_entity" => str(public["link_share_entity"]),
         "chat_ids" => Map.get(by_type, "openchat", []),
         "user_ids" => Map.get(by_type, "openid", []),
         "other_members" =>
           by_type |> Map.drop(["openchat", "openid", "appid"]) |> Map.values() |> List.flatten()
       }}
    end
  end

  @doc """
  The link-sharing setting of a document, folder, or wiki node: the one fact a
  write destination needs to tell a tenant audience from an internet one.
  """
  @spec link_share_entity(map(), term(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def link_share_entity(connect, token, type) do
    with {:ok, target} <- permission_target(connect, token, type),
         {:ok, public} <- public_setting(connect, target) do
      case str(public["link_share_entity"]) do
        "" -> {:error, "Feishu permission setting did not include link_share_entity"}
        entity -> {:ok, entity}
      end
    end
  end

  defp permission_target(_connect, token, "folder") do
    raw = str(token)

    token =
      if String.contains?(raw, "://"),
        do: path_token(URI.parse(raw).path || "", "/drive/folder/") || "",
        else: raw

    if token == "",
      do: {:error, "folder token is required"},
      else: {:ok, %{perm_token: token, perm_type: "folder"}}
  end

  defp permission_target(connect, token, type) do
    with {:ok, ref} <- parse_ref(token, type), do: resolve(connect, ref)
  end

  defp labelled(result, connect, ref) do
    case ReadLabels.for_document(connect, fn -> audience(connect, ref) end) do
      nil -> result
      ifc -> Map.put(result, "__ifc__", ifc)
    end
  end

  # ---------------------------------------------------------------------------
  # Document references
  # ---------------------------------------------------------------------------

  @doc """
  Parses a document URL or token. A bare token is a Docx document unless
  `type` says it is a wiki node. Only Feishu (feishu.cn, larkoffice.com) hosts
  are accepted, because the connect's API base is Feishu's.
  """
  @spec parse_ref(term(), term()) :: {:ok, map()} | {:error, String.t()}
  def parse_ref(%{} = ref, _type), do: {:ok, ref}

  def parse_ref(input, type) do
    raw = str(input)
    type = str(type)

    cond do
      raw == "" ->
        {:error, "doc is required: pass a Feishu document URL or token"}

      String.contains?(raw, "://") ->
        url_ref(raw)

      raw =~ ~r/^[A-Za-z0-9_-]{8,64}$/ ->
        case type do
          type when type in ["", "docx"] -> {:ok, %{kind: "docx", token: raw, input: raw}}
          "wiki" -> {:ok, %{kind: "wiki", token: raw, input: raw}}
          other -> {:error, "unsupported doc_type #{inspect(other)}; use docx or wiki"}
        end

      true ->
        {:error, "unsupported doc #{inspect(raw)}: pass a Feishu docx or wiki URL or token"}
    end
  end

  defp url_ref(raw) do
    uri = URI.parse(raw)
    host = String.downcase(uri.host || "")
    path = uri.path || ""

    cond do
      not feishu_host?(host) and lark_host?(host) ->
        {:error,
         "Lark international documents are not supported by this Feishu connection; use a feishu.cn document"}

      not feishu_host?(host) ->
        {:error, "unsupported document host #{inspect(host)}; pass a Feishu document URL"}

      token = path_token(path, "/docx/") ->
        {:ok, %{kind: "docx", token: token, input: raw}}

      token = path_token(path, "/wiki/") ->
        {:ok, %{kind: "wiki", token: token, input: raw}}

      path_token(path, "/doc/") || path_token(path, "/docs/") ->
        {:error,
         "legacy Feishu documents (/doc/) are not supported; open the document and upgrade it to a new-version document"}

      path_token(path, "/sheets/") || path_token(path, "/base/") ->
        {:error, "Feishu spreadsheets and Base are not supported by the document operations"}

      true ->
        {:error, "unsupported Feishu link #{inspect(raw)}; pass a /docx/ or /wiki/ link"}
    end
  end

  defp feishu_host?(host),
    do:
      host in ["feishu.cn", "larkoffice.com"] or String.ends_with?(host, ".feishu.cn") or
        String.ends_with?(host, ".larkoffice.com")

  defp lark_host?(host),
    do: host == "larksuite.com" or String.ends_with?(host, ".larksuite.com")

  defp path_token(path, marker) do
    case String.split(path, marker, parts: 2) do
      [_before, rest] ->
        case rest |> String.split("/", parts: 2) |> List.first() |> str() do
          "" -> nil
          token -> token
        end

      _ ->
        nil
    end
  end

  @doc """
  Resolves a reference to the Docx object it names. A wiki node is looked up
  once; its permissions belong to the node, its content and comments to the
  Docx object.
  """
  @spec resolve(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def resolve(_connect, %{kind: "docx", token: token}),
    do: {:ok, %{kind: "docx", obj_token: token, perm_token: token, perm_type: "docx", node: nil}}

  def resolve(connect, %{kind: "wiki", token: token}) do
    with {:ok, data} <-
           API.get(connect, "/wiki/v2/spaces/get_node", %{token: token, obj_type: "wiki"}) do
      node = data["node"] || %{}

      case {str(node["obj_type"]), str(node["obj_token"])} do
        {"docx", obj_token} when obj_token != "" ->
          {:ok,
           %{
             kind: "wiki",
             obj_token: obj_token,
             perm_token: blank_default(node["node_token"], token),
             perm_type: "wiki",
             node: Map.take(node, ~w(space_id node_token obj_token obj_type title))
           }}

        {"", _} ->
          {:error, "Feishu wiki node lookup returned no document"}

        {other, _} ->
          {:error, "this wiki node is a #{other}, not a document; only Docx pages are supported"}
      end
    end
  end

  defp ref(params), do: parse_ref(params["doc"], params["doc_type"])

  defp document_summary(target) do
    %{"document_id" => target.obj_token}
    |> maybe_put("wiki_node", target.node)
  end

  defp deletable(%{kind: "docx"}), do: :ok

  defp deletable(_ref),
    do:
      {:error,
       "deleting a wiki page is not supported here; delete it in the Feishu wiki or pass the Docx token of a document outside the wiki"}

  # ---------------------------------------------------------------------------
  # fetch
  # ---------------------------------------------------------------------------

  defp export_option("simple"),
    do: %{
      "export_block_id" => false,
      "export_style_attrs" => false,
      "export_cite_extra_data" => false
    }

  defp export_option("with-ids"), do: %{"export_block_id" => true}

  defp export_option("full"),
    do: %{
      "export_block_id" => true,
      "export_style_attrs" => true,
      "export_cite_extra_data" => true
    }

  defp read_option(params) do
    with {:ok, scope} <- enum(params, "scope", @fetch_scopes, "full") do
      cond do
        scope == "full" ->
          {:ok, nil}

        scope == "section" and str(params["start_block_id"]) == "" ->
          {:error, "scope=section requires start_block_id"}

        scope == "keyword" and str(params["keyword"]) == "" ->
          {:error, "scope=keyword requires keyword"}

        scope == "range" and str(params["start_block_id"]) == "" and
            str(params["end_block_id"]) == "" ->
          {:error, "scope=range requires start_block_id or end_block_id"}

        true ->
          {:ok,
           %{"read_mode" => scope}
           |> maybe_put("start_block_id", blank_nil(params["start_block_id"]))
           |> maybe_put("end_block_id", blank_nil(params["end_block_id"]))
           |> maybe_put("keyword", blank_nil(params["keyword"]))
           |> maybe_put("context_before", count_param(params["context_before"]))
           |> maybe_put("context_after", count_param(params["context_after"]))
           |> maybe_put("max_depth", depth_param(params["max_depth"]))}
      end
    end
  end

  defp fetch_result(agent_id, ref, format, data) do
    document = data["document"] || %{}
    content = if is_binary(document["content"]), do: document["content"], else: ""

    base =
      %{
        "document_id" => blank_default(document["document_id"], ref.token),
        "revision_id" => document["revision_id"],
        "format" => format,
        "reference_map" => document["reference_map"] || %{},
        "tips" => str(document["tips"])
      }

    if byte_size(content) <= @inline_content_bytes do
      {:ok, Map.put(base, "content", content)}
    else
      path = content_path(ref.token, document["revision_id"], format)

      case AgentWorkspace.write(agent_id, path, content) do
        {:ok, _} ->
          {:ok,
           base
           |> Map.put("content", String.slice(content, 0, @content_head_chars))
           |> Map.put("truncated", true)
           |> Map.put("vfs_path", path)
           |> Map.put("file_name", Path.basename(path))
           |> Map.put(
             "mime_type",
             if(format == "xml", do: "application/xml", else: "text/markdown")
           )
           |> Map.put("size", byte_size(content))
           |> Map.put(
             "guidance",
             "The document is larger than one tool result. The full content is at vfs_path; read it with fs.read_file, or fetch a smaller scope (outline, section, range, keyword)."
           )}

        {:error, reason} ->
          {:error,
           "could not stage the Feishu document in the agent workspace: #{inspect(reason)}"}
      end
    end
  end

  defp content_path(token, revision_id, format) do
    extension = if format == "xml", do: "xml", else: "md"
    revision = revision_id |> to_string() |> String.replace(~r/[^0-9]/, "")
    suffix = if revision == "", do: "", else: "-r" <> revision
    "/feishu/docs/#{String.replace(token, ~r/[^A-Za-z0-9_-]/, "_")}#{suffix}.#{extension}"
  end

  # ---------------------------------------------------------------------------
  # create
  # ---------------------------------------------------------------------------

  defp create_content(params) do
    title = str(params["title"])
    content = if is_binary(params["content"]), do: params["content"], else: ""

    cond do
      title == "" and String.trim(content) == "" ->
        {:error, "create_doc requires title or content"}

      title == "" ->
        {:ok, content}

      String.trim(content) == "" ->
        {:ok, "<title>" <> xml_escape(title) <> "</title>"}

      true ->
        {:ok, "<title>" <> xml_escape(title) <> "</title>\n" <> content}
    end
  end

  defp parent(params) do
    raw = str(params["parent"])
    path = if String.contains?(raw, "://"), do: URI.parse(raw).path || "", else: nil

    cond do
      raw == "" ->
        {:ok, nil}

      path && path_token(path, "/wiki/") ->
        {:ok, %{token: path_token(path, "/wiki/"), type: "wiki"}}

      path && path_token(path, "/drive/folder/") ->
        {:ok, %{token: path_token(path, "/drive/folder/"), type: "folder"}}

      path ->
        {:error, "parent must be a Feishu folder (/drive/folder/) or wiki (/wiki/) link"}

      str(params["parent_type"]) in ["folder", "wiki"] ->
        {:ok, %{token: raw, type: str(params["parent_type"])}}

      true ->
        {:error, "parent_type must be folder or wiki when parent is a bare token"}
    end
  end

  @doc "The parent location of `feishu.create_doc`, for the destination resolver."
  @spec create_parent(map()) :: {:ok, map() | nil} | {:error, String.t()}
  def create_parent(params) when is_map(params), do: parent(params)

  defp share_target(params) do
    chat_id = str(params["share_chat_id"])
    user_id = str(params["share_user_id"])

    with {:ok, perm} <- enum(params, "share_perm", @perms, "edit") do
      cond do
        chat_id != "" and user_id != "" ->
          {:error, "pass either share_chat_id or share_user_id, not both"}

        chat_id != "" ->
          {:ok, {{"openchat", "chat", chat_id}, perm}}

        user_id != "" ->
          {:ok, {{"openid", "user", user_id}, perm}}

        true ->
          {:ok, nil}
      end
    end
  end

  defp operation_succeeded(data, action) do
    if str(data["result"]) |> String.downcase() == "failed" do
      details =
        [str(data["tips"]) | Enum.map(List.wrap(data["warnings"]), &str/1)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("; ")

      {:error,
       "Feishu document #{action} failed" <> if(details == "", do: "", else: ": " <> details)}
    else
      :ok
    end
  end

  defp await_create_task(connect, data), do: await_create_task(connect, data, @create_task_polls)

  defp await_create_task(_connect, %{"task" => %{} = task}, 0),
    do:
      {:error,
       "Feishu document creation is still processing (task #{str(task["task_id"])}); the document may appear later. Do not create it again."}

  defp await_create_task(connect, %{"task" => %{} = task} = data, polls_left) do
    case String.downcase(str(task["status"])) do
      "succeeded" ->
        case Jason.decode(str(get_in(task, ["result", "create_document"]))) do
          {:ok, %{} = created} -> {:ok, created}
          _ -> {:error, "Feishu document creation finished without a document"}
        end

      status when status in ["failed", "expired"] ->
        {:error,
         "Feishu document creation failed: " <>
           blank_default(get_in(task, ["failure", "message"]), status)}

      _processing ->
        SystemsClock.sleep(@create_task_poll_ms)

        case API.get(connect, "/docs_ai/v1/async_tasks/#{segment(task["task_id"])}") do
          {:ok, polled} -> await_create_task(connect, polled, polls_left - 1)
          {:error, _reason} -> await_create_task(connect, data, polls_left - 1)
        end
    end
  end

  defp await_create_task(_connect, data, _polls_left), do: {:ok, data}

  defp created_document_id(data) do
    case str(get_in(data, ["document", "document_id"])) do
      "" -> {:error, "Feishu document creation returned no document_id"}
      document_id -> {:ok, document_id}
    end
  end

  # The new document must never be readable by more people than its share
  # target. If its link cannot be confirmed closed, it is removed again.
  defp close_created_link(connect, document_id, share, result) do
    case set_link_share(connect, document_id, "docx", "closed") do
      {:ok, _} ->
        {:ok, maybe_share_created(connect, document_id, share, result)}

      {:error, reason} ->
        rollback =
          case API.delete(connect, "/drive/v1/files/#{segment(document_id)}?type=docx") do
            {:ok, _} ->
              "the new document was deleted again"

            {:error, error} ->
              "deleting the new document also failed (#{error}); delete #{result["url"]} by hand"
          end

        {:error,
         "Feishu document was created but its link sharing could not be set to closed (#{reason}); #{rollback}"}
    end
  end

  defp maybe_share_created(_connect, _document_id, nil, result),
    do: Map.put(result, "shared_with", nil)

  defp maybe_share_created(connect, document_id, {member, perm}, result) do
    {_member_type, kind, member_id} = member

    case add_member(connect, document_id, "docx", member, perm) do
      {:ok, _} ->
        Map.put(result, "shared_with", %{
          "member_type" => kind,
          "member_id" => member_id,
          "perm" => perm
        })

      {:error, reason} ->
        result
        |> Map.put("shared_with", nil)
        |> Map.put(
          "share_error",
          "The document was created but not shared: #{reason} Share it with feishu.share_doc; do not create it again."
        )
    end
  end

  # ---------------------------------------------------------------------------
  # update
  # ---------------------------------------------------------------------------

  defp update_body(params) do
    with {:ok, command} <- enum(params, "command", @update_commands, nil),
         {:ok, format} <- enum(params, "format", @formats, "markdown"),
         :ok <- update_arguments(command, params) do
      {command, block_id} =
        if command == "append",
          do: {"block_insert_after", "-1"},
          else: {command, str(params["block_id"])}

      {:ok,
       %{"format" => format, "command" => command}
       |> maybe_put("content", if(is_binary(params["content"]), do: params["content"]))
       |> maybe_put("pattern", if(is_binary(params["pattern"]), do: blank_nil(params["pattern"])))
       |> maybe_put("block_id", blank_nil(block_id))
       |> maybe_put("start_block_id", blank_nil(params["start_block_id"]))
       |> maybe_put("end_block_id", blank_nil(params["end_block_id"]))
       |> maybe_put("src_block_ids", src_block_ids(params["src_block_ids"]))
       |> maybe_put("revision_id", positive(params["revision_id"]))}
    end
  end

  defp update_arguments(command, params) do
    block? = str(params["block_id"]) != ""
    range? = str(params["start_block_id"]) != "" or str(params["end_block_id"]) != ""
    full_range? = str(params["start_block_id"]) != "" and str(params["end_block_id"]) != ""
    content? = is_binary(params["content"]) and params["content"] != ""

    cond do
      command in @content_commands and command != "str_replace" and not content? ->
        {:error, "command #{command} requires content"}

      command == "str_replace" and str(params["pattern"]) == "" ->
        {:error, "command str_replace requires pattern"}

      command == "str_replace" and not is_binary(params["content"]) ->
        {:error, "command str_replace requires content; pass an empty string to delete the text"}

      command in ["block_replace", "block_delete"] and block? and range? ->
        {:error, "pass either block_id or start_block_id with end_block_id, not both"}

      command in ["block_replace", "block_delete"] and range? and not full_range? ->
        {:error, "start_block_id and end_block_id must be passed together"}

      command in ["block_replace", "block_delete"] and not block? and not range? ->
        {:error, "command #{command} requires block_id or start_block_id with end_block_id"}

      command not in ["block_replace", "block_delete"] and range? ->
        {:error,
         "start_block_id and end_block_id are only valid with block_replace or block_delete"}

      command in ["block_insert_after", "block_copy_insert_after", "block_move_after"] and
          not block? ->
        {:error, "command #{command} requires block_id"}

      command in ["block_copy_insert_after", "block_move_after"] and
          src_block_ids(params["src_block_ids"]) == nil ->
        {:error, "command #{command} requires src_block_ids"}

      command in ["block_delete", "block_move_after"] and content? ->
        {:error, "command #{command} does not take content"}

      true ->
        :ok
    end
  end

  defp src_block_ids(ids) when is_list(ids) do
    case ids |> Enum.map(&str/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      ids -> Enum.join(ids, ",")
    end
  end

  defp src_block_ids(ids), do: blank_nil(ids)

  # ---------------------------------------------------------------------------
  # media insert
  # ---------------------------------------------------------------------------

  defp media_type(params) do
    case str(params["media_type"]) do
      type when type in ["image", "file"] ->
        {:ok, type}

      "" ->
        extension = params["path"] |> str() |> Path.extname() |> String.downcase()

        if extension in ~w(.png .jpg .jpeg .gif .webp .bmp),
          do: {:ok, "image"},
          else: {:ok, "file"}

      _other ->
        {:error, "media_type must be image or file"}
    end
  end

  defp read_upload(agent_id, path) do
    case AgentWorkspace.read_stream(agent_id, str(path)) do
      {:ok, stream, size, filename} when is_integer(size) and size >= 0 and is_binary(filename) ->
        {:ok,
         %{
           stream: stream,
           size: size,
           filename: blank_default(filename, Path.basename(str(path)))
         }}

      {:error, :not_found} ->
        {:error, "file not found in agent VFS: #{str(path)}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _ ->
        {:error, "file not found in agent VFS: #{str(path)}"}
    end
  end

  defp validate_media_size(0), do: {:error, "Feishu does not allow empty uploads"}

  defp validate_media_size(size) when size > @max_media_upload_bytes,
    do: {:error, "Feishu document media uploads are limited to 20 MB here"}

  defp validate_media_size(_size), do: :ok

  # The official flow: an empty image or file block at the end of the
  # document, the upload bound to that block, then the block pointed at the
  # upload. A failure after the placeholder exists removes it again.
  defp insert_media(connect, document_id, media_type, upload, params) do
    doc = segment(document_id)

    with {:ok, root} <- API.get(connect, "/docx/v1/documents/#{doc}/blocks/#{doc}"),
         index = length(List.wrap(get_in(root, ["block", "children"]))),
         {:ok, created} <-
           API.post(connect, "/docx/v1/documents/#{doc}/blocks/#{doc}/children", %{
             "children" => [placeholder_block(media_type)],
             "index" => index
           }),
         {:ok, block_id, target_block_id} <- created_media_block(created, media_type) do
      rollback = fn reason ->
        rollback_note =
          case API.delete(
                 connect,
                 "/docx/v1/documents/#{doc}/blocks/#{doc}/children/batch_delete",
                 %{"start_index" => index, "end_index" => index + 1}
               ) do
            {:ok, _} ->
              "the empty placeholder block was removed"

            {:error, error} ->
              "removing the empty placeholder block #{block_id} also failed (#{error})"
          end

        {:error, "#{reason}; #{rollback_note}"}
      end

      case API.upload_doc_media(
             connect,
             upload.filename,
             upload.stream,
             upload.size,
             if(media_type == "image", do: "docx_image", else: "docx_file"),
             target_block_id,
             document_id
           ) do
        {:ok, file_token} ->
          case API.patch(connect, "/docx/v1/documents/#{doc}/blocks/batch_update", %{
                 "requests" => [bind_request(media_type, target_block_id, file_token, params)]
               }) do
            {:ok, _} ->
              {:ok,
               %{
                 "document_id" => document_id,
                 "block_id" => block_id,
                 "file_token" => file_token,
                 "media_type" => media_type
               }}

            {:error, reason} ->
              rollback.("Feishu accepted the upload but could not attach it: #{reason}")
          end

        {:error, reason} ->
          rollback.("Feishu document media upload failed: #{reason}")
      end
    end
  end

  defp placeholder_block("image"), do: %{"block_type" => 27, "image" => %{}}
  defp placeholder_block("file"), do: %{"block_type" => 23, "file" => %{}}

  # A file block is wrapped: the created block owns a nested child that both
  # receives the upload and is replaced.
  defp created_media_block(created, media_type) do
    case List.wrap(created["children"]) do
      [%{"block_id" => block_id} = child | _] when is_binary(block_id) and block_id != "" ->
        nested =
          case {media_type, List.wrap(child["children"])} do
            {"file", [nested | _]} when is_binary(nested) and nested != "" -> nested
            _ -> block_id
          end

        {:ok, block_id, nested}

      _ ->
        {:error, "Feishu did not return the new media block"}
    end
  end

  defp bind_request("image", block_id, file_token, params) do
    %{
      "block_id" => block_id,
      "replace_image" =>
        %{"token" => file_token}
        |> maybe_put(
          "caption",
          if(str(params["caption"]) != "", do: %{"content" => str(params["caption"])})
        )
    }
  end

  defp bind_request("file", block_id, file_token, _params),
    do: %{"block_id" => block_id, "replace_file" => %{"token" => file_token}}

  # ---------------------------------------------------------------------------
  # permissions
  # ---------------------------------------------------------------------------

  defp public_setting(connect, target) do
    with {:ok, data} <-
           API.get(connect, "/drive/v2/permissions/#{segment(target.perm_token)}/public", %{
             type: target.perm_type
           }) do
      case data["permission_public"] do
        %{} = public -> {:ok, public}
        _ -> {:error, "Feishu permission setting response missing permission_public"}
      end
    end
  end

  defp members(connect, target) do
    with {:ok, data} <-
           API.get(connect, "/drive/v1/permissions/#{segment(target.perm_token)}/members", %{
             type: target.perm_type,
             fields: "name,type"
           }) do
      {:ok, List.wrap(data["items"])}
    end
  end

  defp member(params) do
    kind = str(params["member_type"])
    member_id = str(params["member_id"])

    case Map.fetch(@member_types, kind) do
      {:ok, {member_type, kind}} when member_id != "" -> {:ok, {member_type, kind, member_id}}
      {:ok, _} -> {:error, "member_id is required"}
      :error -> {:error, "member_type must be chat, user, or department"}
    end
  end

  defp add_member(connect, token, type, {member_type, kind, member_id}, perm) do
    API.post(
      connect,
      "/drive/v1/permissions/#{segment(token)}/members?" <>
        URI.encode_query(%{"type" => type, "need_notification" => "false"}),
      %{"member_type" => member_type, "member_id" => member_id, "perm" => perm, "type" => kind}
    )
  end

  defp set_link_share(connect, token, type, entity) do
    API.patch(
      connect,
      "/drive/v2/permissions/#{segment(token)}/public?" <> URI.encode_query(%{"type" => type}),
      %{"link_share_entity" => entity}
    )
  end

  # ---------------------------------------------------------------------------
  # params
  # ---------------------------------------------------------------------------

  defp enum(params, key, allowed, default) do
    case str(params[key]) do
      "" when is_nil(default) ->
        {:error, "#{key} is required; use one of #{Enum.join(allowed, ", ")}"}

      "" ->
        {:ok, default}

      value ->
        if value in allowed,
          do: {:ok, value},
          else: {:error, "#{key} must be one of #{Enum.join(allowed, ", ")}"}
    end
  end

  defp require_param(params, key) do
    if str(params[key]) == "", do: {:error, "#{key} is required"}, else: :ok
  end

  defp page(data, key) do
    %{
      key => List.wrap(data["items"]),
      "has_more" => data["has_more"] == true,
      "next_page_token" => str(data["page_token"])
    }
  end

  defp page_token(params) do
    case params["page_token"] do
      nil -> {:ok, nil}
      token when is_binary(token) and token != "" -> {:ok, String.trim(token)}
      _ -> {:error, "page_token must be a nonblank string when provided"}
    end
  end

  defp page_size(params) do
    (params["page_size"] || @max_page_size)
    |> int_or(@max_page_size)
    |> min(@max_page_size)
    |> max(1)
  end

  defp positive(value) do
    case int_or(value, 0) do
      n when n > 0 -> n
      _ -> nil
    end
  end

  defp count_param(value) do
    case int_or(value, 0) do
      n when n > 0 -> Integer.to_string(n)
      _ -> nil
    end
  end

  defp depth_param(nil), do: nil

  defp depth_param(value) do
    case int_or(value, -2) do
      n when n >= 0 -> Integer.to_string(n)
      _ -> nil
    end
  end

  defp bool_param(value) when value in [true, "true"], do: true
  defp bool_param(value) when value in [false, "false"], do: false
  defp bool_param(_value), do: nil

  defp blank_nil(value) do
    case str(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_default(value, default) do
    case str(value) do
      "" -> default
      value -> value
    end
  end

  # Feishu renders comment text as markup; angle brackets stay literal.
  defp comment_text(text),
    do: text |> to_string() |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

  defp xml_escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp segment(value), do: value |> str() |> URI.encode_www_form()
end
