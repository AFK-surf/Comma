defmodule SalixAgent.BrowserDriverTest do
  use ExUnit.Case, async: false
  alias SalixAgent.Browser.{Driver, Connection}
  @moduletag :browser_local
  @moduletag timeout: 60_000

  defmodule LocalDriver do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(opts), do: Driver.init_connection(opts)
    @impl true
    defdelegate handle_call(message, from, state), to: Driver
    @impl true
    defdelegate handle_cast(message, state), to: Driver
    @impl true
    defdelegate handle_info(message, state), to: Driver
    @impl true
    defdelegate terminate(reason, state), to: Driver
    @impl true
    defdelegate format_status(status), to: Driver
  end

  defmodule Page do
    def init(opts), do: opts

    def call(conn, _) do
      Plug.Conn.send_resp(
        conn,
        200,
        "<html><title>Native navigation</title><body><button>Loaded</button></body></html>"
      )
    end
  end

  setup do
    directory = Path.join(System.tmp_dir!(), "browser-native-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    executable = System.fetch_env!("BROWSER_DRIVER_CHROMIUM")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "--headless",
          "--no-sandbox",
          "--disable-gpu",
          "--remote-debugging-port=0",
          "--user-data-dir=#{directory}",
          "about:blank"
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

      assert eventually(fn ->
               File.rm_rf(directory) == {:ok, []} or not File.exists?(directory)
             end)
    end)

    path = Path.join(directory, "DevToolsActivePort")
    assert eventually(fn -> File.exists?(path) end)
    [port_number, endpoint | _] = File.read!(path) |> String.split("\n")
    url = "ws://127.0.0.1:#{port_number}#{endpoint}"
    {:ok, driver} = start_supervised({LocalDriver, url: url})
    assert {:ok, %{"tabs" => [%{"tab_id" => tab}]}} = Driver.request(driver, "tabs", %{})
    %{driver: driver, tab: tab, url: url}
  end

  test "native observation, form actions, screenshot, keyboard and Unicode input", %{
    driver: driver,
    tab: tab
  } do
    set_content(driver, tab, """
    <input aria-label="Name"><button onclick="document.querySelector('output').textContent=document.querySelector('input').value">Save</button><output></output><input type="number" aria-label="Count" value="123">
    """)

    assert {:ok, snapshot} = Driver.request(driver, "snapshot", %{"tab_id" => tab})
    input = Enum.find(snapshot["elements"], &(&1["name"] == "Name"))["ref"]
    button = Enum.find(snapshot["elements"], &(&1["name"] == "Save"))["ref"]

    assert {:ok, _} =
             Driver.request(driver, "fill", %{
               "tab_id" => tab,
               "ref" => input,
               "text" => "agent text"
             })

    eval(
      driver,
      tab,
      "document.querySelector('button').disabled=true;setTimeout(()=>document.querySelector('button').disabled=false,250)"
    )

    assert {:ok, _} = Driver.request(driver, "click", %{"tab_id" => tab, "ref" => button})
    assert eval(driver, tab, "document.querySelector('output').textContent") == "agent text"
    assert {:ok, _} = Driver.request(driver, "click", %{"tab_id" => tab, "ref" => input})
    select_all = if match?({:unix, :darwin}, :os.type()), do: "Meta+a", else: "Control+a"
    assert {:ok, _} = Driver.request(driver, "press", %{"tab_id" => tab, "key" => select_all})

    assert {:ok, _} =
             Driver.request(driver, "input", %{
               "tab_id" => tab,
               "input" => %{"type" => "text", "text" => "中文輸入"}
             })

    assert eval(driver, tab, "document.querySelector('input').value") == "中文輸入"

    for type <- ~w(keyDown keyUp) do
      assert {:ok, _} =
               Driver.request(driver, "input", %{
                 "tab_id" => tab,
                 "input" => %{"type" => type, "key" => "Tab", "code" => "Tab", "keyCode" => 9}
               })
    end

    assert eval(driver, tab, "document.activeElement.tagName") == "BUTTON"
    assert {:ok, _} = Driver.request(driver, "press", %{"tab_id" => tab, "key" => "Enter"})
    assert eval(driver, tab, "document.querySelector('output').textContent") == "中文輸入"
    assert {:ok, %{"data" => data}} = Driver.request(driver, "screenshot", %{"tab_id" => tab})
    assert <<255, 216, _::binary>> = Base.decode64!(data)

    assert {:error, "invalid_input"} =
             Driver.request(driver, "input", %{
               "tab_id" => tab,
               "input" => %{"type" => "mousePressed", "x" => -1, "y" => 10}
             })

    assert {:ok, _} =
             Driver.request(driver, "fill", %{"tab_id" => tab, "ref" => input, "text" => ""})

    assert eval(driver, tab, "document.querySelector('input').value") == ""
    count = Enum.find(snapshot["elements"], &(&1["name"] == "Count"))["ref"]

    assert {:ok, _} =
             Driver.request(driver, "fill", %{"tab_id" => tab, "ref" => count, "text" => "456"})

    assert eval(driver, tab, "document.querySelector('[type=number]').value") == "456"
  end

  @tag :browser_review
  test "clearing a number field updates the application's input state", %{
    driver: driver,
    tab: tab
  } do
    set_content(driver, tab, """
    <input type="number" aria-label="Count" value="123" oninput="document.querySelector('output').textContent=this.value"><output>123</output>
    """)

    assert {:ok, %{"elements" => [%{"ref" => ref}]}} =
             Driver.request(driver, "snapshot", %{"tab_id" => tab})

    assert {:ok, _} =
             Driver.request(driver, "fill", %{"tab_id" => tab, "ref" => ref, "text" => ""})

    assert eval(driver, tab, "document.querySelector('input').value") == ""
    assert eval(driver, tab, "document.querySelector('output').textContent") == ""

    assert {:ok, _} =
             Driver.request(driver, "fill", %{"tab_id" => tab, "ref" => ref, "text" => "456"})

    assert eval(driver, tab, "document.querySelector('output').textContent") == "456"
  end

  @tag :browser_review
  test "wait matches rendered text across inline nodes and whitespace", %{
    driver: driver,
    tab: tab
  } do
    set_content(
      driver,
      tab,
      "<button style='white-space:pre'>Save   <b>changes</b></button><p style='display:none'>Hidden match</p>"
    )

    assert {:ok, _} =
             Driver.request(driver, "wait", %{
               "tab_id" => tab,
               "text" => "Save changes",
               "timeout_ms" => 500
             })

    assert {:error, "browser_operation_failed"} =
             Driver.request(driver, "wait", %{
               "tab_id" => tab,
               "text" => "Hidden match",
               "timeout_ms" => 100
             })
  end

  test "navigation invalidates references and tabs can be created and closed", %{
    driver: driver,
    tab: tab
  } do
    server =
      start_supervised!({Bandit, plug: Page, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    set_content(driver, tab, "<button>Old</button>")

    assert {:ok, %{"elements" => [%{"ref" => old}]}} =
             Driver.request(driver, "snapshot", %{"tab_id" => tab})

    assert {:ok, _} =
             Driver.request(driver, "navigate", %{
               "tab_id" => tab,
               "url" => "http://127.0.0.1:#{port}/page"
             })

    assert {:error, "stale_element"} =
             Driver.request(driver, "click", %{"tab_id" => tab, "ref" => old})

    assert {:ok, %{"title" => "Native navigation", "text" => "Loaded"}} =
             Driver.request(driver, "snapshot", %{"tab_id" => tab})

    assert {:ok, %{"tabs" => tabs}} = Driver.request(driver, "new_tab", %{})
    assert length(tabs) == 2
    new_tab = Enum.find(tabs, &(&1["tab_id"] != tab))["tab_id"]

    assert {:ok, %{"tabs" => [%{"tab_id" => ^tab}]}} =
             Driver.request(driver, "close_tab", %{"tab_id" => new_tab})
  end

  test "replacement rejects old references instead of clicking a different button", %{
    driver: first,
    tab: tab,
    url: url
  } do
    set_content(
      first,
      tab,
      "<button onclick=\"document.body.dataset.clicked='old'\">Old</button>"
    )

    assert {:ok, %{"elements" => [%{"ref" => old}]}} =
             Driver.request(first, "snapshot", %{"tab_id" => tab})

    set_content(
      first,
      tab,
      "<button onclick=\"document.body.dataset.clicked='new'\">New</button>"
    )

    stop_supervised(LocalDriver)
    {:ok, replacement} = start_supervised({LocalDriver, url: url})
    assert {:ok, _} = Driver.request(replacement, "tabs", %{})

    assert {:ok, %{"elements" => [%{"ref" => current}]}} =
             Driver.request(replacement, "snapshot", %{"tab_id" => tab})

    assert {:error, "stale_element"} =
             Driver.request(replacement, "click", %{"tab_id" => tab, "ref" => old})

    assert eval(replacement, tab, "document.body.dataset.clicked || null") == nil
    assert {:ok, _} = Driver.request(replacement, "click", %{"tab_id" => tab, "ref" => current})
    assert eval(replacement, tab, "document.body.dataset.clicked") == "new"
  end

  test "a viewer admitted during stop receives new frames", %{driver: driver, tab: tab} do
    assert {:ok, _} =
             Driver.request(driver, "stream_start", %{"tab_id" => tab, "viewer_id" => "old"})

    assert eventually(fn -> match?({:ok, %{"data" => _}}, Driver.frame(driver, tab)) end)
    conn = :sys.get_state(driver).commands.conn
    :sys.suspend(conn)
    GenServer.cast(driver, {:stop_stream, tab, "old"})
    assert :sys.get_state(driver).pending != nil
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:started,
         Driver.request(driver, "stream_start", %{"tab_id" => tab, "viewer_id" => "new"})}
      )
    end)

    assert eventually(fn -> :queue.len(:sys.get_state(driver).queue) == 1 end)
    :sys.resume(conn)
    assert_receive {:started, {:ok, %{"streaming" => true}}}, 10_000
    assert eventually(fn -> match?({:ok, %{"data" => _}}, Driver.frame(driver, tab)) end)
    {:ok, before} = Driver.frame(driver, tab)
    Process.sleep(120)
    set_content(driver, tab, "<body style='background:red'>New viewer</body>")

    assert eventually(fn ->
             case Driver.frame(driver, tab) do
               {:ok, %{"sequence" => sequence}} -> sequence > before["sequence"]
               _ -> false
             end
           end)
  end

  test "frames remain available during a wait and disconnect never replays input", %{
    driver: driver,
    tab: tab
  } do
    assert {:ok, _} = Driver.request(driver, "stream_start", %{"tab_id" => tab})
    assert eventually(fn -> match?({:ok, %{"data" => _}}, Driver.frame(driver, tab)) end)
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:waited,
         Driver.request(driver, "wait", %{
           "tab_id" => tab,
           "text" => "absent",
           "timeout_ms" => 5000
         })}
      )
    end)

    assert eventually(fn -> :sys.get_state(driver).pending != nil end)
    assert {:ok, %{"data" => _}} = Driver.frame(driver, tab)

    assert {:error, :browser_driver_busy} =
             Driver.request(driver, "input", %{
               "tab_id" => tab,
               "input" => %{"type" => "text", "text" => "never"}
             })

    conn = :sys.get_state(driver).commands.conn
    monitor = Process.monitor(driver)
    GenServer.stop(conn, :normal)
    assert_receive {:waited, {:error, :browser_outcome_unknown}}, 5000
    assert_receive {:DOWN, ^monitor, :process, ^driver, _}, 5000
  end

  defp set_content(driver, tab, html) do
    eval(
      driver,
      tab,
      "document.open(); document.write(#{Jason.encode!(html)}); document.close();"
    )
  end

  defp eval(driver, tab, expression) do
    state = :sys.get_state(driver).commands

    assert {:ok, result} =
             Connection.command(
               state.conn,
               "Runtime.evaluate",
               %{expression: expression, returnByValue: true},
               state.tabs[tab]
             )

    refute result["exceptionDetails"]
    result["result"]["value"]
  end

  defp eventually(fun, count \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, count) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(50)
          eventually(fun, count - 1)
        )
  end
end
