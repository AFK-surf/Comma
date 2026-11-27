defmodule CommaWeb.ProactiveResearch do
  @moduledoc """
  Bounded single-round read-only research for proactive screening.

  When the first screening pass sees a candidate touching the owner's work or
  products and needs cross-source context to judge or synthesize accurately, it
  may emit `decision: "investigate"` with 1..3 read-only queries across:

    * `memory` — the owner's personal Router memory (`/memory/semantic/*.md`
      and `/memory/episodes/*.md`, excluding `/memory/scoped/`).
    * `pool` — the owner's current connected-source item pool and recent
      station tasks (zero extra external provider calls).
    * `web_search` — Exa web search for public product/platform rules or facts.
    * `web_read` — Exa contents read for a single public HTTP(S) URL.

  Research runs at most once per matter, is strictly read-only, enforces tight
  wall-clock and byte budgets, and runs identically against recorded fixtures
  in `CommaWeb.ProactiveReplay`.
  """

  alias Comma.MemberSourceItems
  alias CommaWeb.{ProactiveEvidence, ProactiveOwner}
  alias SalixAgent.AgentWorkspace
  alias SalixAgent.Tools.Web
  alias SalixStore.Blob

  @sources ~w(memory pool web_search web_read)
  @max_queries 3
  @max_query_chars 200
  @max_matches_per_query 3
  @max_snippet_bytes 650
  @max_total_bytes 4_500
  @local_context_bytes 2_000
  @local_min_hits 2
  @local_min_score 7
  @timeout_ms 12_000
  @memory_semantic_limit 8
  @memory_episode_limit 14
  @memory_file_bytes 16_384
  @memory_max_blob_bytes 65_536
  @memory_semantic_budget 32_768
  @memory_total_bytes 65_536
  @pool_item_limit 200
  @station_task_limit 50
  @english_stop MapSet.new(~w(
    a an and are as at be been by for from has have how in into is it its of on or
    that the their them there these they this those to was were what when where which
    while who will with would should could your you all any can may might must new now
    please ready see sent test update re fw fwd hi hello thanks thank best regards
    subject date http https www com org net io gmail.com outlook.com hotmail.com
    yahoo.com icloud.com example.com noreply no-reply no_reply mailto email mail
    message thread channel slack github notion linear google calendar meeting invite
    weekly daily digest roundup newsletter report alert notice notification info help
    click here link view open check look make get just also only more some other over
    after before about still already available today tomorrow yesterday
  ))
  @cjk_stop_list ~w(
    我们 你们 他们 这个 那个 已经 可以 需要 请看 一下 一个 没有 不是 就是 如果 因为
    所以 目前 今天 明天 昨天 问题 通知 更新 支持 使用 进行 处理 确认 查看 相关 以及
    关于 回复 邮件 消息 功能 系统 时间 工作 大家 谢谢 您好 你好 附件 链接 地址 信息
    内容 状态 完成 开始 结束 测试 发布 版本 提交 修改 调整 方案 需求 计划 说明 建议
    讨论 会议 客户 用户 产品 项目 团队 公司 服务 平台 接口 数据 页面 账号 账户 登录
    密码 方式 规则 配置 环境 情况 反馈 记录 日志 报告 文档 文件 列表 详情 点击 打开
    进入 通过 按照 根据 对于 由于 因此 但是 不过 还是 或者 而且 并且 同时 另外 此外
    其他 所有 全部 部分 主要 具体 当前 最新 最近 之前 之后 现在 一直 正在 即将 可能
    应该 必须 希望 觉得 认为 知道 发现 看到 收到 发送 提供 保持 继续 停止 取消 删除
    增加 减少 优化 修复 解决 排查 分析 验证 检查 审核 审批 上线 下线 切换 升级 迁移
    同步 接入 调用 返回 失败 成功 错误 异常 正常 有效 无效 仅供 知悉 分享
  )
  @cjk_stop MapSet.new(@cjk_stop_list)
  @cjk_stop_re Regex.compile!(
                 Enum.join(@cjk_stop_list, "|") <>
                   "|[的了着过和与及或在于是有被把将给从到为对向由以按请让使很太更最都也就才还又再只已正要会能可应须不没无非我你他她它们这那哪什么谁怎吗呢吧啊呀哦]",
                 "u"
               )

  @doc "The read-only research sources the screening may query."
  def allowed_sources, do: @sources

  @doc """
  Validates and bounds model-supplied research queries (at most #{@max_queries}).
  Every `web_read` query must pass the shared `ProactiveEvidence.sanitize_public_fetch_url/1`
  policy boundary and is rejected altogether when `allow_web_read: false` (e.g.
  private Gmail/Outlook or junk mail).
  """
  def normalize_queries(queries, opts \\ [])

  def normalize_queries(queries, opts) when is_list(queries) do
    allow_web_read? = Keyword.get(opts, :allow_web_read, true) == true

    queries
    |> Enum.flat_map(fn
      %{"source" => source, "query" => query} when is_binary(source) and is_binary(query) ->
        query =
          query
          |> String.replace(~r/\s+/u, " ")
          |> String.trim()
          |> String.slice(0, @max_query_chars)

        cond do
          source not in @sources or query == "" ->
            []

          source == "web_read" and not allow_web_read? ->
            []

          source == "web_read" ->
            case ProactiveEvidence.sanitize_public_fetch_url(query) do
              {:ok, clean_url} -> [%{"source" => "web_read", "query" => clean_url}]
              :error -> []
            end

          true ->
            [%{"source" => source, "query" => query}]
        end

      _ ->
        []
    end)
    |> Enum.uniq_by(&{&1["source"], String.downcase(&1["query"])})
    |> Enum.take(@max_queries)
  end

  def normalize_queries(_other, _opts), do: []

  @doc """
  Zero-cost automatic local cross-source lookup (`memory` + `pool`) run before
  screening for non-junk matters. Uses a high-precision multi-token threshold
  so unrelated arrivals attach zero matches and zero prompt bloat, while active
  rules, PRs, and drafts matching the candidate reach every model tier reliably.
  """
  def local_context(%{"relationship" => "in_your_junk_folder"}, _env), do: []

  def local_context(matter, env) when is_map(matter) and is_map(env) do
    query =
      [
        matter["title"],
        matter["excerpt"],
        slice_utf8(get_in(matter, ["context", "text"]) || "", 320)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if query == "" do
      []
    else
      mem_matches =
        case Map.get(env, :local_memory) do
          fun when is_function(fun, 1) -> fun.(query)
          _ -> []
        end

      pool_matches =
        case Map.get(env, :local_pool) do
          fun when is_function(fun, 1) -> fun.(query)
          _ -> []
        end

      (Enum.map(Enum.take(mem_matches, 2), &Map.put(&1, "source", "memory")) ++
         Enum.map(Enum.take(pool_matches, 2), &Map.put(&1, "source", "pool")))
      |> bound_items(@local_context_bytes)
    end
  rescue
    _ -> []
  end

  def local_context(_matter, _env), do: []

  @doc """
  Builds a bounded read-only snapshot of personal memory, current pool items,
  and owner-filtered station tasks ONCE per check so screening up to 24 matters
  never repeats `AgentWorkspace` or `StationTaskIndex` reads.
  """
  def snapshot(workspace, ctx, profile) do
    personal? = ProactiveOwner.personal_workspace_owner?(workspace, profile.user_id)
    agent = workspace["router_agent_id"]

    memory_docs =
      if personal? and is_binary(agent),
        do: read_runtime_memory_docs(agent),
        else: []

    pool_docs = read_runtime_pool_docs(profile.id)

    station_docs =
      if personal? and is_binary(ctx.group_id),
        do: read_runtime_station_docs(ctx.group_id, profile.user_id, workspace),
        else: []

    %{
      personal?: personal?,
      memory_docs: memory_docs,
      pool_docs: pool_docs,
      station_docs: station_docs
    }
  end

  @doc "Builds the production read-only lookup environment for one matter."
  def from_runtime(workspace, ctx, profile, exclude_url \\ nil, snap \\ nil) do
    snap = snap || snapshot(workspace, ctx, profile)

    pool_docs =
      (snap.pool_docs ++ snap.station_docs)
      |> Enum.reject(&(&1["url"] == exclude_url))

    %{
      memory: fn query ->
        snap.memory_docs
        |> search_documents(query, @max_matches_per_query)
        |> Enum.map(fn doc ->
          %{"path" => doc["path"], "excerpt" => slice_utf8(doc["text"], @max_snippet_bytes)}
        end)
      end,
      local_memory: fn query ->
        snap.memory_docs
        |> search_documents(query, 2,
          min_hits: @local_min_hits,
          min_score: @local_min_score,
          require_distinctive: true
        )
        |> Enum.map(fn doc ->
          %{"path" => doc["path"], "excerpt" => slice_utf8(doc["text"], @max_snippet_bytes)}
        end)
      end,
      pool: fn query ->
        pool_docs
        |> search_documents(query, @max_matches_per_query)
        |> Enum.map(&pool_match/1)
      end,
      local_pool: fn query ->
        pool_docs
        |> search_documents(query, 2,
          min_hits: @local_min_hits,
          min_score: @local_min_score,
          require_distinctive: true
        )
        |> Enum.map(&pool_match/1)
      end,
      web_search: fn query ->
        case Web.search(query, receive_timeout: 8_000, retry: false) do
          {:ok, items} ->
            items
            |> Enum.take(@max_matches_per_query)
            |> Enum.map(&web_match/1)

          _ ->
            []
        end
      end,
      web_read: fn url ->
        with {:ok, clean_url} <- ProactiveEvidence.sanitize_public_fetch_url(url),
             {:ok, [item | _]} <-
               Web.contents([clean_url],
                 max_characters: 1_200,
                 receive_timeout: 8_000,
                 retry: false
               ) do
          [web_match(item, 900)]
        else
          _ -> []
        end
      end
    }
  end

  @doc "Builds a deterministic replay lookup environment from a replay case map."
  def from_replay(kase, exclude_url \\ nil) do
    memory_docs =
      for %{"path" => path, "text" => text} <- kase["memory"] || [],
          is_binary(path) and is_binary(text) and not String.starts_with?(path, "/memory/scoped/"),
          do: %{"path" => path, "text" => text}

    pool_docs =
      (kase["pool_items"] || [])
      |> Enum.filter(&(is_map(&1) and &1["url"] != exclude_url))
      |> Enum.map(fn item ->
        %{
          "app" => item["app"] || item["toolkit"] || "pool",
          "title" => item["title"] || "",
          "url" => item["url"],
          "text" =>
            [item["title"], item["excerpt"], get_in(item, ["context", "text"])]
            |> Enum.filter(&is_binary/1)
            |> Enum.join("\n")
        }
      end)
      |> Kernel.++(
        for %{"title" => title} = task <- kase["tasks"] || [], is_binary(title) do
          %{
            "app" => task["source"] || "task",
            "title" => title,
            "url" => task["url"],
            "text" => Enum.join(Enum.filter([title, task["note"]], &is_binary/1), "\n")
          }
        end
      )

    web_pages = List.wrap(kase["web"])
    web_searches = List.wrap(kase["web_search"])

    %{
      memory: fn query ->
        memory_docs
        |> search_documents(query, @max_matches_per_query)
        |> Enum.map(fn doc ->
          %{"path" => doc["path"], "excerpt" => slice_utf8(doc["text"], @max_snippet_bytes)}
        end)
      end,
      local_memory: fn query ->
        memory_docs
        |> search_documents(query, 2,
          min_hits: @local_min_hits,
          min_score: @local_min_score,
          require_distinctive: true
        )
        |> Enum.map(fn doc ->
          %{"path" => doc["path"], "excerpt" => slice_utf8(doc["text"], @max_snippet_bytes)}
        end)
      end,
      pool: fn query ->
        pool_docs
        |> search_documents(query, @max_matches_per_query)
        |> Enum.map(&pool_match/1)
      end,
      local_pool: fn query ->
        pool_docs
        |> search_documents(query, 2,
          min_hits: @local_min_hits,
          min_score: @local_min_score,
          require_distinctive: true
        )
        |> Enum.map(&pool_match/1)
      end,
      web_search: fn query ->
        replay_web_search(web_searches, web_pages, query)
      end,
      web_read: fn url ->
        case Enum.find(web_pages, &(&1["url"] == url)) do
          %{} = page -> [web_match(page, 900)]
          nil -> []
        end
      end
    }
  end

  @doc "Runs bounded parallel read-only queries and returns total-byte-capped findings."
  def run(queries, env, opts \\ []) when is_list(queries) and is_map(env) do
    normalized = normalize_queries(queries, opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @timeout_ms)

    if normalized == [] do
      []
    else
      normalized
      |> SystemsClock.async_stream(
        fn %{"source" => source, "query" => query} ->
          matches = execute_one(env, source, query)
          %{"source" => source, "query" => query, "matches" => matches}
        end,
        max_concurrency: @max_queries,
        timeout: SystemsClock.timeout(timeout_ms),
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(normalized)
      |> Enum.map(fn
        {{:ok, result}, _query} ->
          result

        {{:exit, _reason}, %{"source" => source, "query" => query}} ->
          %{"source" => source, "query" => query, "matches" => []}
      end)
      |> bound_findings(@max_total_bytes)
    end
  end

  defp execute_one(env, source, query) do
    key = String.to_existing_atom(source)

    case Map.get(env, key) do
      fun when is_function(fun, 1) ->
        case fun.(query) do
          list when is_list(list) -> Enum.take(list, @max_matches_per_query)
          _ -> []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp read_runtime_memory_docs(agent) do
    vfs =
      case AgentWorkspace.read_state(agent) do
        {:ok, %{vfs: map}} when is_map(map) -> map
        _ -> %{}
      end

    paths = Map.keys(vfs)

    semantic_paths =
      paths
      |> Enum.filter(
        &(String.starts_with?(&1, "/memory/semantic/") and String.ends_with?(&1, ".md"))
      )
      |> Enum.reject(&String.starts_with?(&1, "/memory/scoped/"))
      |> Enum.sort()
      |> Enum.take(@memory_semantic_limit)

    episode_paths =
      paths
      |> Enum.filter(
        &(String.starts_with?(&1, "/memory/episodes/") and String.ends_with?(&1, ".md"))
      )
      |> Enum.reject(&String.starts_with?(&1, "/memory/scoped/"))
      |> Enum.sort(:desc)
      |> Enum.take(@memory_episode_limit)

    {semantic_docs, sem_used} =
      read_memory_budget(agent, vfs, semantic_paths, @memory_semantic_budget)

    rem_budget = max(@memory_total_bytes - sem_used, 0)
    {episode_docs, _ep_used} = read_memory_budget(agent, vfs, episode_paths, rem_budget)
    semantic_docs ++ episode_docs
  rescue
    _ -> []
  end

  defp read_memory_budget(agent, vfs, paths, budget) do
    {docs_rev, used} =
      Enum.reduce_while(paths, {[], 0}, fn path, {acc, used} ->
        remaining = budget - used
        entry = Map.get(vfs, path)
        ref = if is_map(entry), do: entry["ref"] || entry[:ref], else: nil
        size = manifest_entry_size(entry, ref)

        cond do
          remaining <= 0 ->
            {:halt, {acc, used}}

          not is_map(ref) or not is_integer(size) or size < 0 or size > @memory_max_blob_bytes ->
            # Fail closed on missing/unknown/oversized blobs and read the checked
            # immutable ref directly without re-reading the manifest.
            {:cont, {acc, used}}

          true ->
            case Blob.get(agent, ref) do
              {:ok, body} when is_binary(body) and body != "" ->
                if String.valid?(body) do
                  capped = slice_utf8(body, min(@memory_file_bytes, remaining))

                  paras =
                    capped
                    |> split_paragraphs()
                    |> Enum.map(&%{"path" => path, "text" => &1})

                  {:cont, {Enum.reverse(paras, acc), used + byte_size(capped)}}
                else
                  {:cont, {acc, used}}
                end

              _ ->
                {:cont, {acc, used}}
            end
        end
      end)

    {Enum.reverse(docs_rev), used}
  end

  defp manifest_entry_size(entry, ref) do
    cond do
      is_map(entry) and is_integer(entry["size"]) -> entry["size"]
      is_map(entry) and is_integer(entry[:size]) -> entry[:size]
      is_map(ref) and is_integer(ref["size"]) -> ref["size"]
      is_map(ref) and is_integer(ref[:size]) -> ref[:size]
      true -> nil
    end
  end

  defp read_runtime_pool_docs(profile_id) do
    profile_id
    |> MemberSourceItems.current_recent(@pool_item_limit)
    |> Enum.map(fn item ->
      text =
        [item.title, item.excerpt, get_in(item.context || %{}, ["text"])]
        |> Enum.filter(&is_binary/1)
        |> Enum.join("\n")

      %{
        "app" => item.app || item.toolkit || "pool",
        "title" => item.title || "",
        "url" => item.url,
        "text" => text
      }
    end)
  rescue
    _ -> []
  end

  defp read_runtime_station_docs(group_id, user_id, workspace) do
    group_id
    |> ProactiveOwner.owner_station_rows(user_id, @station_task_limit, workspace)
    |> Enum.map(fn row ->
      %{
        "app" => "station_task",
        "title" => row.title || "",
        "url" => row.url,
        "text" => Enum.join(Enum.filter([row.title, row.note], &is_binary/1), "\n")
      }
    end)
  rescue
    _ -> []
  end

  defp replay_web_search(web_searches, web_pages, query) do
    query_down = String.downcase(query)
    query_tokens = tokens(query)

    matched =
      web_searches
      |> Enum.flat_map(fn entry ->
        triggers =
          case entry["match"] do
            list when is_list(list) -> list
            s when is_binary(s) -> [s]
            _ -> []
          end

        hit? =
          Enum.any?(triggers, fn trigger ->
            t = String.downcase(to_string(trigger))
            t != "" and (String.contains?(query_down, t) or t in query_tokens)
          end)

        if hit?, do: List.wrap(entry["results"]), else: []
      end)

    results =
      if matched != [] do
        matched
      else
        web_pages
        |> Enum.map(fn page ->
          Map.put(
            page,
            "text",
            Enum.join(Enum.filter([page["title"], page["text"]], &is_binary/1), "\n")
          )
        end)
        |> search_documents(query, @max_matches_per_query)
      end

    results
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(@max_matches_per_query)
    |> Enum.map(&web_match/1)
  end

  defp pool_match(doc) do
    %{
      "app" => doc["app"],
      "title" => slice_utf8(doc["title"] || "", 160),
      "url" => doc["url"],
      "excerpt" => slice_utf8(doc["text"] || "", @max_snippet_bytes)
    }
    |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
  end

  defp web_match(item, max_bytes \\ 500) do
    %{
      "title" => slice_utf8(item["title"] || "", 160),
      "url" => item["url"],
      "text" => slice_utf8(item["text"] || "", max_bytes)
    }
    |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
  end

  @doc false
  def search_documents(docs, query, limit, opts \\ []) when is_list(docs) and is_binary(query) do
    q_ascii = ascii_tokens(query)
    q_cjk_runs = cjk_runs(query)
    q_down = String.downcase(String.trim(query))
    min_hits = Keyword.get(opts, :min_hits, 1)
    min_score = Keyword.get(opts, :min_score, 1)
    require_distinctive? = Keyword.get(opts, :require_distinctive, false)

    if q_ascii == [] and q_cjk_runs == [] and q_down == "" do
      []
    else
      docs
      |> Enum.map(fn doc ->
        haystack = String.downcase((doc["title"] || "") <> "\n" <> (doc["text"] || ""))
        {hits, score, has_distinctive?} = score_text(haystack, q_down, q_ascii, q_cjk_runs)
        {hits, score, has_distinctive?, doc}
      end)
      |> Enum.filter(fn {hits, score, has_distinctive?, _doc} ->
        hits >= min_hits and score >= min_score and
          (not require_distinctive? or has_distinctive?)
      end)
      |> Enum.sort_by(fn {_hits, score, _dist, _doc} -> -score end)
      |> Enum.take(limit)
      |> Enum.map(&elem(&1, 3))
    end
  end

  defp score_text(haystack, q_down, q_ascii, q_cjk_runs) do
    exact_bonus =
      if q_down != "" and String.length(q_down) <= 80 and String.contains?(haystack, q_down),
        do: 6,
        else: 0

    {ascii_hits, ascii_score, ascii_dist} =
      Enum.reduce(q_ascii, {0, 0, false}, fn token, {hits, acc, dist} ->
        if String.contains?(haystack, token) do
          weight =
            cond do
              String.contains?(token, [".", "/", "-", "_"]) -> 4
              String.length(token) >= 4 -> 3
              true -> 1
            end

          {hits + 1, acc + weight, dist or distinctive_token?(token)}
        else
          {hits, acc, dist}
        end
      end)

    # Score CJK bigrams non-overlapping within each run so a single shared 3-char
    # phrase (e.g. "下周一") counts as at most 1 hit / 3 pts instead of stacking
    # overlapping sub-tokens across the same span.
    {cjk_hits, cjk_score, cjk_dist, _seen} =
      Enum.reduce(q_cjk_runs, {0, 0, false, MapSet.new()}, fn indexed_bigrams,
                                                              {h0, s0, d0, seen0} ->
        {hits, score, dist, seen, _last_idx} =
          Enum.reduce(indexed_bigrams, {h0, s0, d0, seen0, -2}, fn {idx, bg},
                                                                   {h, s, d, seen_set, last_idx} ->
            if idx != last_idx + 1 and not MapSet.member?(seen_set, bg) and
                 String.contains?(haystack, bg) do
              {h + 1, s + 3, d or distinctive_token?(bg), MapSet.put(seen_set, bg), idx}
            else
              {h, s, d, seen_set, last_idx}
            end
          end)

        {hits, score, dist, seen}
      end)

    {ascii_hits + cjk_hits, exact_bonus + ascii_score + cjk_score, ascii_dist or cjk_dist}
  end

  defp distinctive_token?(token) do
    cond do
      Regex.match?(~r/\p{Han}/u, token) ->
        String.length(token) >= 2 and not MapSet.member?(@cjk_stop, token)

      String.contains?(token, [".", "/", "-", "_"]) ->
        not MapSet.member?(@english_stop, token)

      Regex.match?(~r/\d/, token) ->
        String.length(token) >= 2

      true ->
        String.length(token) >= 5 and not MapSet.member?(@english_stop, token)
    end
  end

  defp bound_items(items, max_bytes) do
    items
    |> Enum.reduce_while({[], max_bytes}, fn item, {kept, budget} ->
      size = byte_size(Jason.encode!(item))
      if size > budget, do: {:halt, {kept, budget}}, else: {:cont, {[item | kept], budget - size}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc false
  def tokens(text) when is_binary(text) do
    cjk =
      text
      |> cjk_runs()
      |> Enum.flat_map(fn indexed -> Enum.map(indexed, &elem(&1, 1)) end)

    Enum.uniq(ascii_tokens(text) ++ cjk)
  end

  def tokens(_other), do: []

  defp ascii_tokens(text) when is_binary(text) do
    down = String.downcase(text)

    ~r/[a-z][a-z0-9._\/-]{2,}|[a-z]\d+|\d+(?:\.\d+)+/u
    |> Regex.scan(down)
    |> List.flatten()
    |> Enum.map(&String.trim(&1, "._/-"))
    |> Enum.reject(&(&1 == "" or MapSet.member?(@english_stop, &1)))
    |> Enum.uniq()
  end

  defp cjk_runs(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(@cjk_stop_re, " ")
    |> then(&Regex.scan(~r/\p{Han}{2,}/u, &1))
    |> List.flatten()
    |> Enum.map(fn run ->
      run
      |> String.graphemes()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(&Enum.join/1)
      |> Enum.with_index()
      |> Enum.reject(fn {bg, _idx} -> MapSet.member?(@cjk_stop, bg) end)
      |> Enum.map(fn {bg, idx} -> {idx, bg} end)
    end)
    |> Enum.reject(&(&1 == []))
  end

  defp split_paragraphs(body) do
    body
    |> String.split(~r/\R\s*\R/u)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp bound_findings(findings, max_bytes) do
    findings
    |> Enum.reduce_while({[], max_bytes}, fn entry, {kept, budget} ->
      size = byte_size(Jason.encode!(entry))

      cond do
        size <= budget ->
          {:cont, {[entry | kept], budget - size}}

        budget > 200 ->
          trimmed = trim_finding(entry, budget)
          trimmed_size = byte_size(Jason.encode!(trimmed))

          if trimmed_size <= budget,
            do: {:halt, {[trimmed | kept], budget - trimmed_size}},
            else: {:halt, {kept, budget}}

        true ->
          {:halt, {kept, budget}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp trim_finding(entry, budget) do
    matches =
      entry["matches"]
      |> Enum.reduce_while({[], max(budget - 160, 0)}, fn match, {acc, rem} ->
        size = byte_size(Jason.encode!(match))
        if size <= rem, do: {:cont, {[match | acc], rem - size}}, else: {:halt, {acc, rem}}
      end)
      |> elem(0)
      |> Enum.reverse()

    Map.put(entry, "matches", matches)
  end

  defp slice_utf8(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes, do: text

  defp slice_utf8(text, max_bytes) when is_binary(text) and max_bytes > 0 do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, used} ->
      size = byte_size(g)
      if used + size > max_bytes, do: {:halt, {acc, used}}, else: {:cont, {acc <> g, used + size}}
    end)
    |> elem(0)
  end

  defp slice_utf8(_other, _max_bytes), do: ""
end
