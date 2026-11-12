defmodule SalixIM.Provider.CloudTables do
  @moduledoc """
  Base (多维表格, `bitable`) and spreadsheet (`sheet`) reads through a Feishu
  or Lark connect's own app. `SalixIM.Provider.Feishu.Tables` and
  `SalixIM.Provider.Lark.Tables` bind this module to their API and document
  modules; the operations are the same on both platforms.

  The connect's `tenant_access_token` is the default identity. The app opens
  a table only when it is shared with a chat that includes the bot, shared
  with the app, or open by link inside the tenant. A read that names a
  signed-in account gets a connect that acts as that person, as a document
  read does, and every request below, the wiki node lookup and the audience
  read included, then runs as that person. Every read is read-only and
  carries the audience label that `SalixIM.IFC.ReadLabels` derives from the
  table's collaborators and link setting, with the same resolver as a
  document. An audience the reading identity may not list is unknown, and a
  Base with advanced permissions restricts rows and fields per collaborator,
  so its audience is unknown too: both carry the fail-closed label.

  Reads are bounded: one page of records at a time, at most 500 rows of a
  spreadsheet per call with one `next_range` cursor over the sheet, and a result
  larger than one tool result is staged in the agent workspace with a
  bounded head kept inline.
  """

  import SalixIM.Provider.Util, only: [str: 1, int_or: 2, maybe_put: 3]

  alias SalixIM.IFC.ReadLabels
  alias SalixIM.Ports.AgentWorkspace

  @type binding :: %{
          api: module(),
          docs: module(),
          prefix: String.t(),
          product: String.t(),
          host?: (String.t() -> boolean()),
          other_product: String.t(),
          other_host?: (String.t() -> boolean())
        }

  @max_tables_page 100
  @max_records_page 500
  @default_records_page 100
  @max_sheet_rows 500
  @max_sheet_columns 100
  @default_sheet_range "A1:Z500"
  @inline_content_bytes 60_000
  @content_head_chars 12_000

  @doc "The operation names this module answers, for the prefix `feishu` or `lark`."
  @spec api_names(String.t()) :: [String.t()]
  def api_names(prefix),
    do:
      Enum.map(
        ~w(get_base list_base_fields list_base_records get_sheet get_sheet_range),
        &"#{prefix}.#{&1}"
      )

  @spec call(binding(), String.t(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def call(binding, agent_id, connect, api, params) do
    case String.replace_prefix(api, binding.prefix <> ".", "") do
      "get_base" -> get_base(binding, connect, params)
      "list_base_fields" -> list_base_fields(binding, agent_id, connect, params)
      "list_base_records" -> list_base_records(binding, agent_id, connect, params)
      "get_sheet" -> get_sheet(binding, connect, params)
      "get_sheet_range" -> get_sheet_range(binding, agent_id, connect, params)
      _other -> {:error, "unsupported #{binding.product} table api"}
    end
  end

  # ---------------------------------------------------------------------------
  # Base
  # ---------------------------------------------------------------------------

  defp get_base(binding, connect, params) do
    with {:ok, ref} <- ref(binding, params, "base", "bitable"),
         {:ok, target} <- resolve(binding, connect, ref),
         {:ok, page_token} <- page_token(params),
         {:ok, app} <- base_app(binding, connect, target),
         {:ok, tables} <-
           binding.api.get(
             connect,
             "/bitable/v1/apps/#{segment(target.obj_token)}/tables",
             %{page_size: page_size(params, @max_tables_page), page_token: page_token}
           ) do
      {:ok,
       %{
         "app_token" => target.obj_token,
         "name" => str(app["name"]),
         "is_advanced" => app["is_advanced"] == true,
         "url" => blank_default(ref.url, nil),
         "default_table_id" => ref.table_id,
         "default_view_id" => ref.view_id
       }
       |> Map.merge(page(tables, "tables"))
       |> maybe_put("wiki_node", target.node)
       |> labelled(binding, connect, Map.put(target, :advanced, app["is_advanced"] == true))}
    end
  end

  defp list_base_fields(binding, agent_id, connect, params) do
    with {:ok, ref} <- ref(binding, params, "base", "bitable"),
         {:ok, target} <- resolve(binding, connect, ref),
         {:ok, table_id} <- table_id(params, ref),
         {:ok, page_token} <- page_token(params),
         {:ok, views_page_token} <- page_token(params, "views_page_token"),
         base = "/bitable/v1/apps/#{segment(target.obj_token)}/tables/#{segment(table_id)}",
         query = %{
           view_id: blank_nil(params["view_id"]) || ref.view_id,
           page_size: page_size(params, @max_tables_page),
           page_token: page_token
         },
         {:ok, fields} <- fields(binding, connect, base, query, views_page_token) do
      result =
        %{"app_token" => target.obj_token, "table_id" => table_id}
        |> Map.merge(views(binding, connect, base, page_token, views_page_token))
        |> maybe_put("wiki_node", target.node)

      staged =
        if fields == %{} do
          {:ok, result}
        else
          stage(
            agent_id,
            Map.merge(result, fields |> page("fields") |> Map.delete("fields")),
            "fields",
            List.wrap(fields["items"]),
            content_path(
              binding,
              "base",
              "#{target.obj_token}-#{table_id}-fields",
              query_digest(query)
            ),
            "The fields are larger than one tool result. The full list of this page is at vfs_path as a JSON array; read it with fs.read_file."
          )
        end

      with {:ok, result} <- staged, do: {:ok, labelled(result, binding, connect, target)}
    end
  end

  # With views_page_token alone, the call pages the views and reads no fields.
  defp fields(_binding, _connect, _base, %{page_token: nil}, views_page_token)
       when not is_nil(views_page_token),
       do: {:ok, %{}}

  defp fields(binding, connect, base, query, _views_page_token),
    do: binding.api.get(connect, base <> "/fields", query)

  # Views come with the first page of fields, or with views_page_token, and
  # have their own paging. A failed views read does not fail the fields.
  defp views(_binding, _connect, _base, page_token, nil) when not is_nil(page_token), do: %{}

  defp views(binding, connect, base, _page_token, views_page_token) do
    case binding.api.get(connect, base <> "/views", %{
           page_size: @max_tables_page,
           page_token: views_page_token
         }) do
      {:ok, data} ->
        %{
          "views" => List.wrap(data["items"]),
          "views_has_more" => data["has_more"] == true,
          "views_next_page_token" => str(data["page_token"])
        }

      {:error, reason} ->
        %{"views" => [], "views_error" => reason}
    end
  end

  defp list_base_records(binding, agent_id, connect, params) do
    with {:ok, ref} <- ref(binding, params, "base", "bitable"),
         {:ok, target} <- resolve(binding, connect, ref),
         {:ok, table_id} <- table_id(params, ref),
         {:ok, page_token} <- page_token(params),
         {:ok, filter} <- json_object(params["filter"], "filter"),
         {:ok, sort} <- json_list(params["sort"], "sort"),
         {:ok, field_names} <- json_list(params["field_names"], "field_names"),
         view_id = blank_nil(params["view_id"]) || ref.view_id,
         :ok <- view_or_search(view_id, filter, sort),
         page_size = page_size(params, @max_records_page, @default_records_page),
         query =
           %{"page_size" => page_size}
           |> maybe_put("page_token", page_token),
         body =
           %{"automatic_fields" => params["automatic_fields"] == true}
           |> maybe_put("view_id", view_id)
           |> maybe_put("field_names", field_names)
           |> maybe_put("filter", filter)
           |> maybe_put("sort", sort),
         {:ok, data} <-
           binding.api.post_read(
             connect,
             "/bitable/v1/apps/#{segment(target.obj_token)}/tables/#{segment(table_id)}/records/search?" <>
               URI.encode_query(query),
             body
           ) do
      records = List.wrap(data["items"])

      result =
        %{
          "app_token" => target.obj_token,
          "table_id" => table_id,
          "view_id" => view_id,
          "total" => data["total"],
          "has_more" => data["has_more"] == true,
          "next_page_token" => str(data["page_token"])
        }
        |> maybe_put("wiki_node", target.node)

      with {:ok, result} <-
             stage(
               agent_id,
               result,
               "records",
               records,
               content_path(
                 binding,
                 "base",
                 "#{target.obj_token}-#{table_id}",
                 query_digest(Map.merge(body, query))
               ),
               "The page is larger than one tool result. The full records of this page are at vfs_path as a JSON array; read it with fs.read_file, or ask for fewer rows with page_size or field_names."
             ) do
        {:ok, labelled(result, binding, connect, target)}
      end
    end
  end

  # Feishu and Lark run a search with filter or sort over the whole table and
  # ignore view_id, so a view and a search cannot be asked for together.
  defp view_or_search(nil, _filter, _sort), do: :ok
  defp view_or_search(_view_id, nil, nil), do: :ok

  defp view_or_search(_view_id, _filter, _sort),
    do:
      {:error,
       "filter and sort search the whole table, and the view's own filter does not apply: pass base as the bare app_token with table_id and no view_id for a search, or drop filter and sort to read the view"}

  # Two reads of the same table with different views, filters, fields or
  # pages are staged at different paths.
  defp query_digest(query) do
    :crypto.hash(:sha256, Jason.encode!(query))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp base_app(binding, connect, target) do
    with {:ok, data} <-
           binding.api.get(connect, "/bitable/v1/apps/#{segment(target.obj_token)}"),
         do: {:ok, data["app"] || %{}}
  end

  # ---------------------------------------------------------------------------
  # Spreadsheets
  # ---------------------------------------------------------------------------

  defp get_sheet(binding, connect, params) do
    with {:ok, ref} <- ref(binding, params, "sheet", "sheet"),
         {:ok, target} <- resolve(binding, connect, ref),
         {:ok, meta} <-
           binding.api.get(connect, "/sheets/v3/spreadsheets/#{segment(target.obj_token)}"),
         {:ok, sheets} <- sheets(binding, connect, target) do
      spreadsheet = meta["spreadsheet"] || %{}

      {:ok,
       %{
         "spreadsheet_token" => target.obj_token,
         "title" => str(spreadsheet["title"]),
         "url" => blank_default(spreadsheet["url"], blank_default(ref.url, nil)),
         "default_sheet_id" => ref.sheet_id,
         "sheets" => sheets
       }
       |> maybe_put("wiki_node", target.node)
       |> labelled(binding, connect, target)}
    end
  end

  # The sheets of a spreadsheet, without their merges: a metadata read stays
  # small whatever the formatting.
  defp sheets(binding, connect, target) do
    with {:ok, data} <-
           binding.api.get(
             connect,
             "/sheets/v3/spreadsheets/#{segment(target.obj_token)}/sheets/query"
           ) do
      {:ok,
       data["sheets"]
       |> List.wrap()
       |> Enum.map(&Map.take(&1, ~w(sheet_id title index hidden grid_properties)))}
    end
  end

  defp get_sheet_range(binding, agent_id, connect, params) do
    with {:ok, ref} <- ref(binding, params, "sheet", "sheet"),
         {:ok, target} <- resolve(binding, connect, ref),
         {:ok, sheet_id} <- sheet_id(params, ref),
         {:ok, sheets} <- sheets(binding, connect, target),
         grid = grid(sheets, sheet_id),
         {:ok, range} <- range(params["range"], grid),
         {:ok, data} <-
           binding.api.get(
             connect,
             "/sheets/v2/spreadsheets/#{segment(target.obj_token)}/values/#{segment(sheet_id)}!#{range.text}",
             %{valueRenderOption: "ToString", dateTimeRenderOption: "FormattedString"}
           ) do
      value_range = data["valueRange"] || %{}
      rows = List.wrap(value_range["values"])

      result =
        %{
          "spreadsheet_token" => target.obj_token,
          "sheet_id" => sheet_id,
          "range" => blank_default(value_range["range"], sheet_id <> "!" <> range.text),
          "revision" => data["revision"],
          "row_count" => length(rows)
        }
        |> Map.merge(continuation(range, grid))
        |> maybe_put("wiki_node", target.node)

      with {:ok, result} <-
             stage(
               agent_id,
               result,
               "rows",
               rows,
               content_path(binding, "sheets", "#{target.obj_token}-#{sheet_id}", range.text),
               "The range is larger than one tool result. The full rows are at vfs_path as a JSON array of rows; read it with fs.read_file, or ask for a smaller range."
             ) do
        {:ok, labelled(result, binding, connect, target)}
      end
    end
  end

  defp grid(sheets, sheet_id) do
    case Enum.find(sheets, &(str(&1["sheet_id"]) == sheet_id)) do
      %{"grid_properties" => %{"row_count" => rows, "column_count" => columns}}
      when is_integer(rows) and is_integer(columns) and rows > 0 and columns > 0 ->
        %{rows: rows, columns: columns}

      _other ->
        nil
    end
  end

  # One cursor over the sheet, each cell once: the next block of rows below
  # this range, as tall as this range; then, below the last row, the next
  # block of columns to the right, as wide as this range, from row 1 and as
  # tall as the bound allows. has_more is false only after the last block.
  # Without the sheet's grid size nothing can be promised, and has_more is
  # unknown.
  defp continuation(range, %{rows: total_rows, columns: total_columns}) do
    rows = range.r2 - range.r1 + 1
    columns = range.c2 - range.c1 + 1

    next =
      cond do
        range.r2 < total_rows ->
          a1(range.c1, range.r2 + 1, range.c2, min(range.r2 + rows, total_rows))

        range.c2 < total_columns ->
          a1(
            range.c2 + 1,
            1,
            min(range.c2 + columns, total_columns),
            min(@max_sheet_rows, total_rows)
          )

        true ->
          nil
      end

    %{
      "sheet_row_count" => total_rows,
      "sheet_column_count" => total_columns,
      "has_more" => next != nil
    }
    |> maybe_put("next_range", next)
  end

  defp continuation(_range, _grid),
    do: %{
      "has_more" => nil,
      "guidance" =>
        "The sheet's size is unknown, so this range may not be the whole sheet: read the next range until a read comes back short."
    }

  defp a1(c1, r1, c2, r2), do: "#{column_letters(c1)}#{r1}:#{column_letters(c2)}#{r2}"

  defp column_letters(index) when index >= 1 do
    letters = fn
      0, acc, _f -> acc
      n, acc, f -> f.(div(n - 1, 26), <<?A + rem(n - 1, 26)>> <> acc, f)
    end

    letters.(index, "", letters)
  end

  # ---------------------------------------------------------------------------
  # References
  # ---------------------------------------------------------------------------

  @doc """
  Parses a Base or spreadsheet URL, a wiki URL, or a bare token. `kind` is
  `bitable` or `sheet`. The URL's `table`, `view` and `sheet` queries become
  the defaults of the read. A share link (`/share/base/...`) carries no app
  token and is refused.
  """
  @spec parse_ref(binding(), term(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_ref(binding, input, kind) do
    raw = str(input)
    noun = noun(kind)
    path_marker = if kind == "bitable", do: "/base/", else: "/sheets/"

    cond do
      raw == "" ->
        {:error, "#{noun} is required: pass a #{binding.product} #{noun} URL or token"}

      String.contains?(raw, "://") ->
        uri = URI.parse(raw)
        host = String.downcase(uri.host || "")
        path = uri.path || ""
        query = URI.decode_query(uri.query || "")

        cond do
          not binding.host?.(host) and binding.other_host?.(host) ->
            {:error,
             "#{binding.other_product} links are not supported by this #{binding.product} connection; use a #{binding.product} #{noun}"}

          not binding.host?.(host) ->
            {:error, "unsupported host #{inspect(host)}; pass a #{binding.product} #{noun} URL"}

          String.starts_with?(path, "/share/") ->
            {:error,
             "this is a share link of a view or form, which names no #{noun}; open it and pass the #{noun}'s own URL (#{path_marker}...)"}

          token = path_token(path, path_marker) ->
            {:ok, with_query(%{kind: kind, token: token, input: raw, url: raw}, query)}

          token = path_token(path, "/wiki/") ->
            {:ok,
             with_query(%{kind: "wiki", want: kind, token: token, input: raw, url: raw}, query)}

          path_token(path, "/base/") || path_token(path, "/sheets/") ->
            {:error,
             "this link is a #{other_noun(kind)}, not a #{noun}; use the #{other_noun(kind)} operations"}

          true ->
            {:error,
             "unsupported #{binding.product} link #{inspect(raw)}; pass a #{path_marker} or /wiki/ link"}
        end

      raw =~ ~r/^[A-Za-z0-9_-]{8,64}$/ ->
        {:ok,
         %{
           kind: kind,
           token: raw,
           input: raw,
           url: nil,
           table_id: nil,
           view_id: nil,
           sheet_id: nil
         }}

      true ->
        {:error,
         "unsupported #{noun} #{inspect(raw)}: pass a #{binding.product} #{noun} URL or token"}
    end
  end

  defp with_query(ref, query) do
    ref
    |> Map.put(:table_id, blank_nil(query["table"]))
    |> Map.put(:view_id, blank_nil(query["view"]))
    |> Map.put(:sheet_id, blank_nil(query["sheet"]))
  end

  defp ref(binding, params, key, kind), do: parse_ref(binding, params[key], kind)

  # The object the reference names and the permission target that labels it.
  # A wiki node is looked up once, and must hold the kind the caller wants.
  defp resolve(_binding, _connect, %{kind: kind, token: token}) when kind in ~w(bitable sheet),
    do: {:ok, %{kind: kind, obj_token: token, perm_token: token, perm_type: kind, node: nil}}

  defp resolve(binding, connect, %{kind: "wiki", want: want, token: token}) do
    with {:ok, data} <-
           binding.api.get(connect, "/wiki/v2/spaces/get_node", %{token: token, obj_type: "wiki"}) do
      node = data["node"] || %{}

      case {str(node["obj_type"]), str(node["obj_token"])} do
        {^want, obj_token} when obj_token != "" ->
          {:ok,
           %{
             kind: want,
             obj_token: obj_token,
             perm_token: blank_default(node["node_token"], token),
             perm_type: "wiki",
             node: Map.take(node, ~w(space_id node_token obj_token obj_type title))
           }}

        {"", _} ->
          {:error, "#{binding.product} wiki node lookup returned no object"}

        {other, _} ->
          {:error,
           "this wiki node is a #{other}, not a #{noun(want)}; use the operations for that type"}
      end
    end
  end

  defp noun("bitable"), do: "base"
  defp noun("sheet"), do: "spreadsheet"
  defp other_noun("bitable"), do: "spreadsheet"
  defp other_noun("sheet"), do: "base"

  defp table_id(params, ref) do
    case blank_nil(params["table_id"]) || ref.table_id do
      nil ->
        {:error,
         "table_id is required: pass one from #{noun("bitable")} tables, or a URL with ?table="}

      id ->
        {:ok, id}
    end
  end

  defp sheet_id(params, ref) do
    case blank_nil(params["sheet_id"]) || ref.sheet_id do
      nil -> {:error, "sheet_id is required: pass one from get_sheet, or a URL with ?sheet="}
      id -> {:ok, id}
    end
  end

  # An A1 range inside one sheet, bounded to @max_sheet_rows rows and
  # @max_sheet_columns columns. Without one, the first block of the sheet:
  # every column up to the bound, when the sheet's size is known.
  defp range(value, grid) do
    raw = value |> str() |> String.upcase() |> String.replace(" ", "")
    raw = if raw == "", do: default_range(grid), else: raw

    case Regex.run(~r/^([A-Z]{1,3})(\d+):([A-Z]{1,3})(\d+)$/, raw) do
      [_, c1, r1, c2, r2] ->
        range = %{
          text: raw,
          c1: column_index(c1),
          r1: String.to_integer(r1),
          c2: column_index(c2),
          r2: String.to_integer(r2)
        }

        rows = range.r2 - range.r1 + 1
        columns = range.c2 - range.c1 + 1

        cond do
          rows < 1 or columns < 1 or range.r1 < 1 ->
            {:error, "range must run from its top-left cell to its bottom-right cell"}

          rows > @max_sheet_rows ->
            {:error, "range covers #{rows} rows; read at most #{@max_sheet_rows} rows per call"}

          columns > @max_sheet_columns ->
            {:error,
             "range covers #{columns} columns; read at most #{@max_sheet_columns} columns per call"}

          true ->
            {:ok, range}
        end

      _ ->
        {:error, "range must be an A1 range inside one sheet, such as A1:D200"}
    end
  end

  defp default_range(%{rows: rows, columns: columns}),
    do: a1(1, 1, min(columns, @max_sheet_columns), min(rows, @max_sheet_rows))

  defp default_range(nil), do: @default_sheet_range

  defp column_index(letters),
    do: letters |> String.to_charlist() |> Enum.reduce(0, &(&2 * 26 + (&1 - ?A + 1)))

  # ---------------------------------------------------------------------------
  # Results
  # ---------------------------------------------------------------------------

  defp labelled(result, binding, connect, target) do
    case ReadLabels.for_document(connect, fn -> audience(binding, connect, target) end) do
      nil -> result
      ifc -> Map.put(result, "__ifc__", ifc)
    end
  end

  # A Base with advanced permissions gives each collaborator its own rows and
  # fields, so what the app read may be more than a collaborator sees: its
  # audience is unknown, and the label fails closed.
  defp audience(binding, connect, %{kind: "bitable"} = target) do
    advanced =
      case Map.fetch(target, :advanced) do
        {:ok, advanced} ->
          {:ok, advanced}

        :error ->
          with {:ok, app} <- base_app(binding, connect, target),
               do: {:ok, app["is_advanced"] == true}
      end

    case advanced do
      {:ok, true} ->
        {:error,
         "the Base uses advanced permissions, which restrict rows and fields per collaborator; its audience is unknown"}

      {:ok, false} ->
        binding.docs.permission_audience(connect, target)

      {:error, _reason} = error ->
        error
    end
  end

  defp audience(binding, connect, target), do: binding.docs.permission_audience(connect, target)

  defp stage(agent_id, result, key, items, path, guidance) do
    encoded = Jason.encode!(items)

    if byte_size(encoded) <= @inline_content_bytes do
      {:ok, Map.put(result, key, items)}
    else
      case AgentWorkspace.write(agent_id, path, encoded) do
        {:ok, _} ->
          {:ok,
           result
           |> Map.put(key, [])
           |> Map.put("content", String.slice(encoded, 0, @content_head_chars))
           |> Map.put("truncated", true)
           |> Map.put("vfs_path", path)
           |> Map.put("file_name", Path.basename(path))
           |> Map.put("mime_type", "application/json")
           |> Map.put("size", byte_size(encoded))
           |> Map.put("guidance", guidance)}

        {:error, reason} ->
          {:error, "could not stage the table in the agent workspace: #{inspect(reason)}"}
      end
    end
  end

  defp content_path(binding, kind, name, suffix) do
    suffix = suffix |> str() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
    suffix = if suffix == "", do: "", else: "-" <> suffix
    "/#{binding.prefix}/#{kind}/#{String.replace(name, ~r/[^A-Za-z0-9_-]/, "_")}#{suffix}.json"
  end

  defp page(data, key) do
    %{
      key => List.wrap(data["items"]),
      "has_more" => data["has_more"] == true,
      "next_page_token" => str(data["page_token"])
    }
  end

  # ---------------------------------------------------------------------------
  # Params
  # ---------------------------------------------------------------------------

  defp page_token(params, key \\ "page_token") do
    case params[key] do
      nil -> {:ok, nil}
      token when is_binary(token) and token != "" -> {:ok, String.trim(token)}
      _ -> {:error, "#{key} must be a nonblank string when provided"}
    end
  end

  defp page_size(params, max, default \\ nil) do
    (params["page_size"] || default || max)
    |> int_or(default || max)
    |> min(max)
    |> max(1)
  end

  defp json_object(nil, _key), do: {:ok, nil}
  defp json_object(value, _key) when value == %{}, do: {:ok, nil}
  defp json_object(%{} = value, _key), do: {:ok, value}

  defp json_object(value, key) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> json_object(decoded, key)
      _ -> {:error, "#{key} must be a JSON object"}
    end
  end

  defp json_object(_value, key), do: {:error, "#{key} must be a JSON object"}

  defp json_list(nil, _key), do: {:ok, nil}
  defp json_list([], _key), do: {:ok, nil}
  defp json_list(value, _key) when is_list(value), do: {:ok, value}

  defp json_list(value, key) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_list(decoded) -> {:ok, decoded}
      _ -> {:error, "#{key} must be a JSON array"}
    end
  end

  defp json_list(_value, key), do: {:error, "#{key} must be a JSON array"}

  # The token right after a marker at the start of the path: a marker found
  # deeper in the path, as in a share link, names nothing.
  defp path_token(path, marker) do
    if String.starts_with?(path, marker) do
      path
      |> binary_part(byte_size(marker), byte_size(path) - byte_size(marker))
      |> String.split("/", parts: 2)
      |> List.first()
      |> str()
      |> case do
        "" -> nil
        token -> token
      end
    end
  end

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

  defp segment(value), do: value |> str() |> URI.encode_www_form()
end
