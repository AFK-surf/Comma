defmodule SalixAnalytics.SessionHistoryIndex do
  @moduledoc "Cold Session history. Inserts and confirmation use the same bounded HTTP read route."
  @table "{{database}}.agent_session_history"

  def transfer(agent, session, documents) do
    rows =
      Enum.map(documents, fn doc ->
        doc
        |> Map.merge(%{"agent_id" => agent, "session_id" => session})
        |> Map.update!("label", &Jason.encode!/1)
      end)

    body = Enum.map_join(rows, "\n", &Jason.encode!/1)
    sql = "INSERT INTO #{@table} SETTINGS async_insert=0 FORMAT JSONEachRow\n" <> body <> "\n"

    with {:ok, _} <- request(sql, []) do
      {:ok, first} = fetch(agent, session, hd(documents)["seq"], List.last(documents)["seq"])
      if first == documents, do: :ok, else: {:error, :cold_not_visible}
    end
  end

  def search(agent, session, query, ceiling, before_seq, before_part, limit) do
    predicate = if is_nil(query), do: "part=0", else: "position(text,{query:String})>0"

    sql = """
    SELECT seq,part,text,kind,tool_name,label FROM #{@table} FINAL
    PREWHERE agent_id={agent:String} AND session_id={session:String}
    WHERE seq<={ceiling:UInt64} AND (seq,part)<({before:UInt64},{part:UInt32})
      AND #{predicate}
    ORDER BY seq DESC,part DESC LIMIT {limit:UInt32} FORMAT JSONEachRow
    """

    read(
      sql,
      params(agent, session) ++
        bind(
          ceiling: ceiling,
          before: before_seq,
          part: before_part,
          query: query || "",
          limit: limit
        )
    )
  end

  defp fetch(agent, session, first, last) do
    read(
      """
      SELECT seq,part,text,kind,tool_name,label FROM #{@table} FINAL
      PREWHERE agent_id={agent:String} AND session_id={session:String}
      WHERE seq>={first:UInt64} AND seq<={last:UInt64}
      ORDER BY seq,part LIMIT 129 FORMAT JSONEachRow
      """,
      params(agent, session) ++ bind(first: first, last: last)
    )
  end

  defp read(sql, params) do
    with {:ok, body} <- request(sql, params) do
      rows = body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:ok, Enum.map(rows, &Map.update!(&1, "label", fn label -> Jason.decode!(label) end))}
    end
  end

  defp params(agent, session), do: bind(agent: agent, session: session)

  defp bind(values),
    do: Enum.map(values, fn {key, value} -> {"param_#{key}", escape_parameter(value)} end)

  defp escape_parameter(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> String.replace(<<0>>, "\\0")
  end

  defp request(sql, params) do
    cfg = Application.get_env(:salix_analytics, :clickhouse, [])

    database =
      cfg[:database] || (cfg[:table] || "salix_analytics.events") |> String.split(".") |> hd()

    if is_binary(cfg[:base_url]) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, database) do
      headers = [
        {"x-clickhouse-user", cfg[:user] || "default"},
        {"x-clickhouse-key", cfg[:password] || ""}
      ]

      settings = [
        {"max_execution_time", "2"},
        {"max_rows_to_read", "2097152"},
        {"max_bytes_to_read", "268435456"},
        {"max_memory_usage", "268435456"},
        {"output_format_json_quote_64bit_integers", "0"}
      ]

      case Req.post(cfg[:base_url],
             body: String.replace(sql, "{{database}}", database),
             headers: headers,
             params: settings ++ params,
             retry: false,
             redirect: false,
             finch: SalixAgent.SessionHistory.HTTP,
             receive_timeout: 3_000,
             pool_timeout: 100,
             into: fn {:data, chunk}, {req, resp} ->
               body = (resp.body || "") <> chunk

               if byte_size(body) > 8 * 1024 * 1024,
                 do: {:halt, {req, %{resp | body: "", status: 413}}},
                 else: {:cont, {req, %{resp | body: body}}}
             end
           ) do
        {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
        _ -> {:error, :cold_unavailable}
      end
    else
      {:error, :cold_unavailable}
    end
  rescue
    _ -> {:error, :cold_unavailable}
  catch
    _, _ -> {:error, :cold_unavailable}
  end
end
