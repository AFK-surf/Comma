defmodule CommaWeb.ChatDeviceView do
  @moduledoc false

  def render(result, workspace, language) do
    zh = language == "zh"
    view = result.view
    prefix = view["revision"] <> ":"
    snapshot = choose(zh, "查询时间", "Read at") <> ": " <> time(result.observed_at)
    warning = choose(zh, "状态是查询时的快照；操作前请刷新。", "This is a snapshot. Refresh before use.")

    {body, choices} =
      case result.kind do
        :list ->
          lines =
            result.devices
            |> Enum.with_index(1)
            |> Enum.map(fn {d, i} ->
              "#{i}. #{safe(d["name"], 60)} — #{device_status(d, zh)}"
            end)

          lines = if lines == [], do: [choose(zh, "暂无设备。", "No devices.")], else: lines

          choices =
            result.devices
            |> Enum.with_index(1)
            |> Enum.map(fn {d, i} ->
              {"#{i}. #{safe(d["name"], 45)}", prefix <> to_string(i)}
            end)

          {Enum.join(lines, "\n"), choices}

        :detail ->
          d = result.device
          runtimes = d["device_runtimes"] || []

          groups =
            runtimes
            |> Enum.filter(&(&1["provider"] in ~w(codex claude pi kimi)))
            |> Enum.group_by(& &1["provider"])

          details =
            ~w(codex claude pi kimi)
            |> Enum.flat_map(fn provider ->
              entries = Map.get(groups, provider, [])

              if entries == [],
                do: [],
                else: [
                  provider <>
                    "\n" <>
                    Enum.map_join(
                      Enum.take(entries, 4),
                      "\n",
                      &runtime(&1, d, zh, result.observed_at)
                    ) <>
                    if(length(entries) > 4,
                      do:
                        "\n" <>
                          choose(
                            zh,
                            "更多安装请打开设备设置。",
                            "Open device settings for more installations."
                          ),
                      else: ""
                    )
                ]
            end)

          body =
            [
              safe(d["name"], 80),
              device_status(d, zh),
              safe(d["os"], 40) <> " " <> safe(d["arch"], 30),
              choose(zh, "设备操作权限", "Device operations") <>
                ": " <>
                choose(
                  d["allows_operations"] == true,
                  choose(zh, "允许", "allowed"),
                  choose(zh, "未允许", "not allowed")
                )
            ] ++ details

          {Enum.join(body, "\n\n"),
           [{choose(zh, "刷新详情", "Refresh details"), prefix <> to_string(result.index)}]}
      end

    navigation =
      [{choose(zh, "设备列表 / 刷新", "Device list / refresh"), prefix <> "refresh"}] ++
        if(is_binary(view["next_cursor"]),
          do: [{choose(zh, "下一页", "Next page"), prefix <> "next"}],
          else: []
        ) ++
        if(is_binary(view["cursor"]),
          do: [{choose(zh, "回到首页", "First page"), prefix <> "first"}],
          else: []
        )

    %{
      text: safe(workspace["name"], 60) <> "\n" <> body <> "\n\n" <> snapshot <> "\n" <> warning,
      choices: choices ++ navigation,
      manage_url:
        Application.fetch_env!(:comma_web, :web_cookie_origin)
        |> String.trim_trailing("/")
        |> Kernel.<>("/#/settings?category=devices"),
      manage_label:
        choose(zh, "登录 Comma 管理设备（请确认工作区）", "Sign in to manage devices (check workspace)")
    }
  end

  def wechat_text(view) do
    commands =
      Enum.map_join(view.choices, "\n", fn {label, action} ->
        label <> "：设备 " <> String.replace(action, ":", " ")
      end)

    view.text <>
      "\n\n引用此消息，回复编号、下一页、刷新或首页。也可复制以下命令：\n" <>
      commands <> "\n\n" <> view.manage_label <> "\n" <> view.manage_url
  end

  defp runtime(r, d, zh, now) do
    status =
      cond do
        d["status"] != "connected" ->
          choose(zh, "设备离线", "device offline")

        d["allows_operations"] != true or r["issue"] == "permission_required" ->
          choose(zh, "需要设备授权", "device permission required")

        r["status"] == "ready" and is_integer(r["readiness_valid_until"]) and
            r["readiness_valid_until"] > now ->
          choose(zh, "查询时可用", "ready when read")

        r["status"] in ["ready", "stale"] ->
          choose(zh, "状态已过期", "status expired")

        r["issue"] == "authentication_required" ->
          choose(zh, "需要登录", "sign-in required")

        true ->
          choose(zh, "尚未就绪", "not ready")
      end

    auth =
      case get_in(r, ["auth", "mode"]) do
        "chatgpt" -> "ChatGPT"
        "api_key" -> "API key"
        "amazon_bedrock" -> "Amazon Bedrock"
        _ -> choose(zh, "未报告", "not reported")
      end

    "• #{safe(r["version"], 40)} — #{status}; #{auth}\n" <>
      choose(zh, "检查", "Checked") <>
      ": " <>
      time(r["readiness_checked_at"]) <>
      "; " <>
      choose(zh, "有效至", "Valid until") <> ": " <> time(r["readiness_valid_until"])
  end

  defp device_status(d, zh),
    do:
      choose(
        d["status"] == "connected",
        choose(zh, "已连接", "connected"),
        choose(zh, "未连接", "disconnected")
      )

  defp time(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, date} -> Calendar.strftime(date, "%Y-%m-%d %H:%M:%S UTC")
      _ -> "—"
    end
  end

  defp time(_), do: "—"

  defp safe(value, limit) when is_binary(value),
    do: value |> String.replace(~r/[\r\n\x00-\x1F]/u, " ") |> String.slice(0, limit)

  defp safe(_, _), do: "—"
  defp choose(true, yes, _), do: yes
  defp choose(_, _, no), do: no
end
