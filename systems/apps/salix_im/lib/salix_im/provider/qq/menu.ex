defmodule SalixIM.Provider.QQ.Menu do
  @moduledoc """
  The command menu of a QQ bot: what QQ shows when a person types a slash.

  The menu has two parts. The control commands are fixed: `/status`,
  `/compact` and `/help`. The shortcuts belong to the connect
  (`command_menu`), and a Swarm admin edits them in the dashboard or with
  `bft qq menu`. A shortcut has a name, a description, the chats it shows in
  (`all`, `private` or `group`), whether only group admins may tap it, and
  optionally a prompt.

  QQ puts the name of a tapped item in the person's input box after a slash.
  The message that arrives is `/<name>`. `prompt/3` gives the Router the
  shortcut's prompt in its place; a shortcut without a prompt arrives as
  written. A shortcut is ordinary input for the Router, never a control
  command.

  ## Panels

  QQ keeps the menu as command panels, one for private chats and one for
  groups. `sync/2` writes the panels this module made, and only those: a panel
  it made carries the remark `bft`. A panel without the remark that holds the
  first menu this integration made (`status`, `clear`, `compact`, `help`) is
  its own too. Any other panel is the bot owner's and stays as it is; the
  result then says `owner_panel` for that scene.
  """

  require Logger

  alias SalixIM.Provider.QQ.API
  alias SalixStore.{CasRecord, Keys}

  @remark "bft"
  @scenes [{"private", "c2c"}, {"group", "group"}]
  @scopes ~w(all private group)

  @control [
    {"status", "查看会话状态"},
    {"compact", "压缩会话上下文"},
    {"help", "查看指令和功能介绍"}
  ]
  # The panel of the first version of this integration.
  @first_panel ~w(status clear compact help)

  # QQ takes 20 items in a panel, 14 characters in a name and 30 in a
  # description, and counts a Chinese character as two.
  @max_items 20
  @max_shortcuts @max_items - length(@control)
  @max_name_width 14
  @max_description_width 30
  @max_prompt_chars 500

  @default [
    %{
      "name" => "总结群聊",
      "description" => "总结最近的群聊内容",
      "prompt" => "总结这个群最近的聊天内容，列出要点、结论和待办事项。",
      "scope" => "group",
      "admin_only" => false
    }
  ]

  @doc "The names of the control commands in the menu."
  @spec control_commands() :: [String.t()]
  def control_commands, do: Enum.map(@control, &elem(&1, 0))

  @doc "The shortcuts of a connect: the ones it stores, or the default ones."
  @spec shortcuts(map()) :: [map()]
  def shortcuts(%{"command_menu" => items}) when is_list(items), do: items
  def shortcuts(_connect), do: @default

  @doc """
  Checks the shortcuts an admin sent and returns them in the stored form.
  """
  @spec validate(term()) :: {:ok, [map()]} | {:error, String.t()}
  def validate(items) when is_list(items) and length(items) <= @max_shortcuts do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case shortcut(item) do
        {:ok, shortcut} -> {:cont, {:ok, [shortcut | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, shortcuts} ->
        shortcuts = Enum.reverse(shortcuts)
        names = Enum.map(shortcuts, &String.downcase(&1["name"]))

        if names == Enum.uniq(names),
          do: {:ok, shortcuts},
          else: {:error, "two menu items have the same name"}

      error ->
        error
    end
  end

  def validate(_items),
    do: {:error, "the menu takes a list of at most #{@max_shortcuts} items"}

  defp shortcut(%{} = item) do
    name = item["name"] |> text() |> String.trim_leading("/")
    description = text(item["description"])
    prompt = text(item["prompt"])
    scope = if text(item["scope"]) == "", do: "all", else: text(item["scope"])

    cond do
      name == "" or String.contains?(name, [" ", "\t", "\n", "/", "<", ">"]) ->
        {:error, "a menu item needs a name without spaces"}

      width(name) > @max_name_width ->
        {:error,
         "the name #{name} is too long: QQ takes #{@max_name_width} characters, and a Chinese character counts as two"}

      String.downcase(name) in ["clear" | control_commands()] ->
        {:error, "#{name} is a control command and cannot be a menu item"}

      width(description) > @max_description_width ->
        {:error,
         "the description of #{name} is too long: QQ takes #{@max_description_width} characters, and a Chinese character counts as two"}

      String.length(prompt) > @max_prompt_chars ->
        {:error, "the prompt of #{name} takes at most #{@max_prompt_chars} characters"}

      scope not in @scopes ->
        {:error, "the scope of #{name} must be all, private or group"}

      true ->
        {:ok,
         %{
           "name" => name,
           "description" => description,
           "prompt" => prompt,
           "scope" => scope,
           "admin_only" => item["admin_only"] == true
         }}
    end
  end

  defp shortcut(_item), do: {:error, "a menu item must be an object"}

  @doc """
  The text the Router gets for a message of a chat: the prompt of the shortcut
  the message names, or `nil` when the message names none that has a prompt.
  """
  @spec prompt(map(), String.t(), String.t()) :: String.t() | nil
  def prompt(connect, chat_type, "/" <> name) when is_map(connect) do
    name = String.downcase(String.trim(name))

    connect
    |> shown(chat_type)
    |> Enum.find_value(fn shortcut ->
      if String.downcase(shortcut["name"]) == name and shortcut["prompt"] != "",
        do: shortcut["prompt"]
    end)
  end

  def prompt(_connect, _chat_type, _body), do: nil

  @doc "The answer to `/help` in a QQ chat of this connect."
  @spec help_text(map(), String.t()) :: String.t()
  def help_text(connect, chat_type) when is_map(connect) do
    commands = [
      "/status — 查看当前模型和上下文用量",
      "/compact — 压缩会话上下文",
      "/help — 查看本说明"
    ]

    shortcuts =
      connect
      |> shown(chat_type)
      |> Enum.map(fn shortcut ->
        case shortcut["description"] do
          "" -> "/" <> shortcut["name"]
          description -> "/#{shortcut["name"]} — #{description}"
        end
      end)

    [
      "我是这个团队在 Bridge For Teams 上的 Agent。" <>
        if(chat_type == "group", do: "在群里 @我 并说明要做的事，", else: "直接发消息说明要做的事，") <>
        "我会处理并把结果发回这里。",
      section("指令", commands),
      section("快捷指令", shortcuts),
      section("我能做的事", [
        "回答问题，查看和搜索群里此前的对话，读取发来的文件、图片和语音",
        "使用团队已连接的帐号和应用，例如代码仓库、文档、日历和工单",
        "接手耗时的任务并跟进，或按计划定时执行",
        "在远程设备和云电脑上运行代码，发布网站"
      ]),
      "团队管理员可以在 Bridge For Teams 后台的 Connections 里连接 Feishu、Slack、QQ 等消息渠道和第三方帐号，" <>
        "在 Plugins 和 Skills 里为 Agent 增加能力。"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  The answer to `help` for the QQ chat a command came from, or `nil` when the
  connect cannot be read; the caller then gives the general answer.
  """
  @spec help(String.t(), map()) :: String.t() | nil
  def help(group_id, %{"connect_id" => connect_id} = metadata)
      when is_binary(group_id) and is_binary(connect_id) do
    case CasRecord.get(Keys.ctl_im_connect(group_id, connect_id)) do
      {:ok, connect} ->
        help_text(connect, if(metadata["chat_type"] == "group", do: "group", else: "private"))

      _unavailable ->
        nil
    end
  end

  def help(_group_id, _metadata), do: nil

  defp section(_title, []), do: ""
  defp section(title, lines), do: Enum.join([title <> "：" | Enum.map(lines, &("• " <> &1))], "\n")

  @doc """
  Writes the menu of `connect` to QQ. Returns the outcome for each scene:
  `synced`, `owner_panel` when the bot's owner made the panel that is there,
  or `failed`. Never raises; a failure is logged.
  """
  @spec sync(map()) :: %{String.t() => String.t()}
  def sync(connect) when is_map(connect) do
    Map.new(@scenes, fn {chat_type, scene} ->
      {chat_type, sync_scene(connect, scene, items(connect, chat_type))}
    end)
  end

  defp sync_scene(connect, scene, items) do
    panel = %{"items" => items, "remark" => @remark}

    with {:ok, listed} <- API.request(connect, :get, "/v2/panels", params: [scope: scene]) do
      records = listed["records"] |> List.wrap() |> Enum.filter(&is_map/1)

      case Enum.find(records, &ours?/1) do
        %{"panel_id" => id} = record when is_binary(id) and id != "" ->
          if same_items?(record, items),
            do: {:ok, %{}},
            else: API.request(connect, :put, "/v2/panels/" <> id, json: %{"panel" => panel})

        _none when records == [] ->
          API.request(connect, :post, "/v2/panels",
            json: %{"scope" => scene, "target_type" => "all", "panel" => panel}
          )

        _owner_made ->
          :owner_panel
      end
    end
    |> case do
      {:ok, _body} ->
        "synced"

      :owner_panel ->
        "owner_panel"

      {:error, reason} ->
        Logger.warning("qq_command_panel_sync_failed",
          scope: scene,
          reason: API.error_text(reason)
        )

        "failed"
    end
  end

  defp ours?(%{"panel" => %{} = panel}) do
    panel["remark"] == @remark or
      panel["items"] |> List.wrap() |> Enum.map(&item_name/1) == @first_panel
  end

  defp ours?(_record), do: false

  defp same_items?(%{"panel" => %{"items" => current, "remark" => @remark}}, items)
       when is_list(current) do
    Enum.map(current, &Map.take(&1, ~w(type name desc only_admin))) ==
      Enum.map(items, &Map.take(&1, ~w(type name desc only_admin)))
  end

  defp same_items?(_record, _items), do: false

  defp item_name(%{"name" => name}) when is_binary(name), do: String.trim_leading(name, "/")
  defp item_name(_item), do: ""

  # The control commands first, then the shortcuts of the scene.
  defp items(connect, chat_type) do
    control =
      Enum.map(@control, fn {name, description} ->
        %{"type" => "command", "name" => name, "desc" => description, "only_admin" => false}
      end)

    shortcuts =
      connect
      |> shown(chat_type)
      |> Enum.map(fn shortcut ->
        %{
          "type" => "command",
          "name" => shortcut["name"],
          "desc" => shortcut["description"],
          # QQ has admins only in a group.
          "only_admin" => chat_type == "group" and shortcut["admin_only"] == true
        }
      end)

    control ++ shortcuts
  end

  defp shown(connect, chat_type) do
    connect
    |> shortcuts()
    |> Enum.filter(&(is_map(&1) and &1["scope"] in ["all", chat_type]))
  end

  # QQ's count: two for a character outside ASCII.
  defp width(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, width -> width + if(char < 128, do: 1, else: 2) end)
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
