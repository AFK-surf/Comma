defmodule SalixAgent.LiveLlmScreenLinkE2eTest do
  require SystemsRuntime.Proc

  @moduledoc """
  Real-model check that a request to see a simulator ends in the screen's link
  as a paragraph of its own, the shape Comma draws as a live card, not
  screenshots. It checks the reply's text. It does not render the card.
  The Router, its system prompt, the built-in skills (`show-screen`), the tool
  dispatcher and the internal conversation are the production ones. Only the
  computer is a stand-in at the EnvDispatch seam: it runs no command, and its
  station answers `screen_links` as systems/station/src/screens/links.ts does.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.LiveLlmTestSupport, as: Live

  @moduletag :live_llm
  @moduletag timeout: 300_000

  @mac "dev_mac_screen"
  @booted "0702F8CC-2E2A-4D0A-8401-C37FA01E1646"
  @link "comma:screen/#{@mac}/simulator%3A#{@booted}"

  defmodule MacDispatch do
    @moduledoc false
    @behaviour SalixAgent.EnvDispatch

    @mac "dev_mac_screen"
    @env "mac-env"
    @booted "0702F8CC-2E2A-4D0A-8401-C37FA01E1646"

    defp tell(message) do
      if owner = SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}, nil),
        do: SystemsRuntime.Proc.send(owner, message)
    end

    defp mac do
      %{
        "device_id" => @mac,
        "name" => "Peng's MacBook Pro",
        "status" => "connected",
        "os" => "darwin",
        "owner_is_requester" => true
      }
    end

    @impl true
    def list_devices(_agent_id, _opts), do: {:ok, %{devices: [mac()], next_cursor: nil}}

    @impl true
    def list_envs(_agent_id), do: {:ok, []}

    @impl true
    def get_device(_agent_id, @mac) do
      {:ok,
       Map.put(mac(), "environments", [
         %{
           "environment_id" => @env,
           "os" => "darwin",
           "status" => "connected",
           "capabilities" => %{
             "exec" => true,
             "screen_view" => true,
             "computer_use_tool" => true
           }
         }
       ])}
    end

    def get_device(_agent_id, _device_id), do: {:error, :not_found}

    # The model chooses the commands; this double never runs one. Each says
    # what a Mac with the repository, Xcode and a booted simulator would.
    @impl true
    def exec(_agent_id, %{device_id: @mac, environment_id: @env}, command, _opts) do
      tell({:mac_exec, command})

      # What it echoes comes back too, as a probe of the channel expects.
      echoed =
        Regex.scan(~r/\becho\s+['"]?([^'";|&]*)/, command, capture: :all_but_first)
        |> Enum.map_join(&(String.trim(hd(&1)) <> "\n"))

      {:ok,
       %{
         "status" => "completed",
         "exit_code" => 0,
         "stdout" => echoed <> said(command),
         "stderr" => ""
       }}
    end

    defp said(command) do
      # An edit that makes the button blue stays made.
      if command =~ ~r/sed -i|perl -pi|cat >|tee / and command =~ "blue",
        do: SystemsRuntime.PersistentTerm.put({__MODULE__, :blue}, true)

      color =
        if SystemsRuntime.PersistentTerm.get({__MODULE__, :blue}, false),
          do: "blue",
          else: "orange"

      cond do
        command =~ "listapps" ->
          "    \"fail.still.ios\" = {\n        CFBundleIdentifier = \"fail.still.ios\";\n    };\n"

        command =~ "simctl list" ->
          "== Devices ==\n-- iOS 27.2 --\n    iPhone 17 Pro (#{@booted}) (Booted)\n"

        command =~ "simctl launch" ->
          "fail.still.ios: 4242\n"

        command =~ "xcodebuild -list" ->
          "Information about project \"StillFail\":\n    Schemes:\n        StillFail\n"

        command =~ "xcodebuild" ->
          "** BUILD SUCCEEDED **\n"

        command =~ ~r/sed -i|perl -pi|apply_patch|cat >|tee / ->
          ""

        command =~ ~r/\bgrep\b|\brg\b/ ->
          "ios/StillFail/LoginView.swift:42:            .background(Color.#{color})\n"

        command =~ ~r/\bcat\b|\bhead\b|\bsed -n\b/ ->
          "Button(\"登录\") { login() }\n            .background(Color.#{color})\n"

        command =~ ~r/still|find|mdfind|\bls\b/ ->
          "/Users/peng/Documents/GitHub/still.fail\n/Users/peng/Documents/GitHub/still.fail/ios/StillFail.xcodeproj\n"

        true ->
          ""
      end
    end

    def exec(_agent_id, _target, _command, _opts), do: {:error, :no_environment}

    @impl true
    def request(_agent_id, %{device_id: @mac, environment_id: @env}, "screen_links", _params) do
      tell(:screen_links)

      {:ok,
       %{
         "device_id" => @mac,
         "screens" => [
           %{
             "link" => "comma:screen/#{@mac}/display",
             "kind" => "display",
             "title" => "Display"
           },
           %{
             "link" => "comma:screen/#{@mac}/simulator%3A#{@booted}",
             "kind" => "simulator",
             "title" => "iPhone 17 Pro · iOS 27.2"
           }
         ],
         "bootable_simulators" => [
           %{"udid" => "FEF50280-1320-41CC-9F03-B3FA444053A7", "title" => "iPhone 17 · iOS 27.2"}
         ],
         "startable_avds" => []
       }}
    end

    def request(_agent_id, _target, _method, _params), do: {:error, :no_environment}

    @impl true
    def computer_use(_agent_id, _target, _action), do: {:error, :no_environment}

    @impl true
    def android(_agent_id, _target, _action), do: {:error, :no_environment}
    @impl true
    def process_list(_agent_id, _target), do: {:ok, %{"processes" => []}}
    @impl true
    def process_write(_agent_id, _target, _name, _data, _opts), do: {:error, :no_environment}
    @impl true
    def process_tail(_agent_id, _target, _name, _opts), do: {:error, :no_environment}
    @impl true
    def read_stream(_agent_id, _target, _path), do: {:error, :no_environment}
    @impl true
    def write_stream(_agent_id, _target, _path, _stream), do: {:error, :no_environment}
  end

  setup_all do
    {:ok, llm: Live.llm_config!()}
  end

  setup do
    cleanup = Live.install_runtime!()
    previous = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    SystemsRuntime.PersistentTerm.put({MacDispatch, :owner}, SystemsRuntime.Proc.self())
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, MacDispatch)

    on_exit(fn ->
      SystemsRuntime.PersistentTerm.erase({MacDispatch, :owner})
      SystemsRuntime.PersistentTerm.erase({MacDispatch, :blue})
      Live.restore_env(:env_dispatch, previous)
      cleanup.()
    end)

    :ok
  end

  for request <- ["把 still fail 的 iOS 版本启动起来我看看，我要看 simulator", "启动 still.fail 的 iOS 模拟器给我看"] do
    @request request
    test "live LLM: #{@request} ends in the simulator's link alone on a line", %{llm: llm} do
      chat = start_router!(llm)
      reply = await_link!(chat, @request)

      assert_received :screen_links
      assert card?(reply)
      # The card is the answer: no screenshot is sent in its place.
      refute Enum.any?(router_replies(chat), &attachment?/1)
    end
  end

  test "live LLM: earlier screenshots in the thread do not replace the card", %{llm: llm} do
    chat = start_router!(llm)
    seed_screenshot_history!(chat.router)

    reply = await_link!(chat, "把 still.fail 的 iOS 版在我 MacBook 上用模拟器跑起来给我看")

    assert_received :screen_links
    assert card?(reply)
    refute Enum.any?(all_messages(chat), &attachment?/1)
  end

  @tag timeout: 600_000
  test "live LLM: a change after the card rebuilds in the same simulator and posts no second card",
       %{llm: llm} do
    chat = start_router!(llm)
    await_link!(chat, "启动 still.fail 的 iOS 模拟器给我看")
    seen = all_messages(chat) |> Enum.map(& &1["message_id"]) |> MapSet.new()

    say!(chat, "登录按钮的颜色改成蓝色")

    # The Router or a Worker it gives the change to rebuilds; the Router then
    # reports in this chat.
    commands =
      Live.eventually(
        fn ->
          commands = Process.get(:commands, []) ++ collect_commands([])
          Process.put(:commands, commands)
          later = Enum.reject(router_replies(chat), &MapSet.member?(seen, &1["message_id"]))

          if Enum.any?(commands, &rebuild?/1) and later != [] and turn_ended?(chat.router),
            do: {:ok, commands},
            else: :retry
        end,
        420_000
      )

    later = Enum.reject(all_messages(chat), &MapSet.member?(seen, &1["message_id"]))
    IO.puts("\n--- follow-up\n" <> transcript(chat, commands))

    refute Enum.any?(commands, &(&1 =~ ~r/simctl (boot|shutdown|erase)/))
    # It looked at the rebuilt screen before reporting.
    assert Enum.any?(commands, &(&1 =~ ~r/simctl io \S+ screenshot/))
    # No second card anywhere: the first one shows the relaunched app.
    refute Enum.any?(later, &link_line?/1)
    refute Enum.any?(later, &attachment?/1)
  end

  defp rebuild?(command), do: command =~ ~r/xcodebuild|simctl install|simctl launch/

  # Every message of the Workspace's conversations: the chat and its Tasks.
  defp all_messages(chat) do
    {:ok, listed} = SalixIM.Conversations.list_group_conversations(chat.group_id, limit: 20)
    conversations = if is_map(listed), do: listed["data"], else: listed

    Enum.flat_map(conversations, fn conversation ->
      {:ok, messages} =
        SalixIM.Conversations.list_group_conversation_messages(
          chat.group_id,
          conversation["conversation_id"],
          limit: 50
        )

      messages
    end)
  end

  defp start_router!(llm) do
    tenant = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    router = SalixStore.Ids.new_agent_id(group_id)
    Live.seed_group!(tenant, group_id)
    # The platform profile holds the key itself, as a deployment's does.
    llm = Map.put(llm, :api_key, System.fetch_env!(llm.api_key_env))
    Live.configure!(router, llm, %{tenant_id: tenant, group_id: group_id, role: "router"})
    # A Worker the Router may give the build to, as a Workspace has.
    worker = SalixStore.Ids.new_agent_id(group_id)
    Live.configure!(worker, llm, %{tenant_id: tenant, group_id: group_id, role: "worker"})

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router)
      end)

    {:ok, parent} = SalixIM.RouterConversationInput.ensure(group_id)
    Live.flush_notifications!()
    %{group_id: group_id, router: router, parent: parent}
  end

  defp say!(chat, text) do
    assert {:ok, _} =
             SalixIM.RouterConversationInput.append_user_message(chat.group_id, %{
               "content" => text,
               "client_request_id" => "screen-link-#{Live.unique_suffix()}",
               "metadata" => %{
                 "client_device" => %{"device_id" => @mac, "name" => "Peng's MacBook Pro"}
               }
             })
  end

  # The earlier turns of the failure this guards: the Router answered the same
  # request with screenshots from a Task, so its history says that is the way.
  defp seed_screenshot_history!(router) do
    session_id = Live.router_session_id!(router)

    entries =
      [
        {"user", "把 still fail 的 iOS 版本启动起来我看看，我要看 simulator"},
        {"assistant",
         "已经在 MacBook 上跑起来了。我让 Worker 在原来的 Task 里 xcrun simctl io booted screenshot，截了整屏和 App 画面两张图发给你。"},
        {"user", "再截一张聊天页"},
        {"assistant", "好，这是聊天页的截图，已发你。"}
      ]
      |> Enum.with_index()
      |> Enum.map(fn {{role, text}, index} ->
        %{"role" => role, "content" => text, "source_message_id" => "screen-history:#{index}"}
      end)

    {:ok, _} =
      SalixAgent.TestSupport.SessionFixture.commit(router, session_id, [
        %{
          "type" => "transcript_seed",
          "entries" => entries,
          "created_at" => SystemsClock.system_time(:second)
        }
      ])
  end

  # The request, and the reply with the link once its turn has ended.
  defp await_link!(chat, request) do
    say!(chat, request)

    reply =
      try do
        Live.eventually(fn ->
          case Enum.find(router_replies(chat), &card?/1) do
            nil -> :retry
            message -> {:ok, message}
          end
        end)
      rescue
        error ->
          IO.puts("\n--- #{request} (no link line)\n" <> transcript(chat, collect_commands([])))
          IO.puts(session_trace(chat.router))
          reraise error, __STACKTRACE__
      end

    Live.eventually(fn -> if turn_ended?(chat.router), do: {:ok, :ended}, else: :retry end)
    IO.puts("\n--- #{request}\n" <> transcript(chat, collect_commands([])))
    reply
  end

  defp attachment?(message) do
    Enum.any?(List.wrap(message["content"]), fn block ->
      is_map(block) and block["type"] in ["image", "file"]
    end)
  end

  defp messages(chat) do
    {:ok, messages} =
      SalixIM.Conversations.list_group_conversation_messages(
        chat.group_id,
        chat.parent["conversation_id"],
        limit: 50
      )

    Enum.sort_by(messages, & &1["seq"])
  end

  defp router_replies(chat),
    do:
      Enum.filter(
        messages(chat),
        &(&1["actor_type"] == "agent" and &1["agent_id"] == chat.router)
      )

  # A shape check on the reply's text, not a render: a top-level paragraph that
  # is the link and nothing else, which every Comma version that draws cards
  # turns into one (screenLinks.ts). A sentence above the link with one newline
  # is one paragraph: newer clients cut the link out, older ones show the text,
  # so it does not pass.
  defp card?(message) do
    message["content"]
    |> Live.text_content()
    # Fenced code blocks, of backticks or tildes and any length; an unclosed one runs to the end.
    |> then(
      &Regex.replace(~r/^ {0,3}(`{3,}|~{3,})[^\n]*\n.*?(^ {0,3}\1[`~]*[ \t]*$|\z)/ms, &1, "")
    )
    |> String.split(~r/\n[ \t]*\n/)
    |> Enum.any?(&(String.trim_trailing(&1) |> String.replace(~r/\A\n* {0,3}/, "") == @link))
  end

  # Any line that is the link: what newer clients draw as a card.
  defp link_line?(message) do
    message["content"]
    |> Live.text_content()
    |> String.split("\n")
    |> Enum.any?(&(String.trim(&1) == @link))
  end

  defp transcript(chat, commands) do
    Enum.map_join(messages(chat), "\n", fn message ->
      who = if message["agent_id"] == chat.router, do: "agent", else: message["actor_type"]
      "[#{who}] #{Live.text_content(message["content"])}"
    end) <> "\n[commands]\n$ " <> Enum.join(commands, "\n$ ")
  end

  defp turn_ended?(router) do
    case SalixAgent.InternalSessionStore.read(router, Live.router_session_id!(router)) do
      {:ok, session} ->
        SalixAgent.InternalSession.status(session) == :idle and
          SalixAgent.InternalSession.work_reasons(session) == []

      _other ->
        false
    end
  end

  # What the Router's model said and called, for a failure's report.
  defp session_trace(router) do
    with {:ok, session} <-
           SalixAgent.InternalSessionStore.read(router, Live.router_session_id!(router)) do
      session
      |> SalixAgent.InternalSession.request_live_messages()
      |> Enum.map_join("\n", fn message ->
        "[#{message["role"]}] " <>
          String.slice(inspect(message["content"] || message["tool_calls"]), 0, 600)
      end)
    end
  end

  defp collect_commands(acc) do
    SystemsRuntime.Proc.receive do
      {:mac_exec, command} -> collect_commands([command | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
