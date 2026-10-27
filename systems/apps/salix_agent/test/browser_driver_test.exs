defmodule SalixAgent.BrowserDriverTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
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

    # The browser keeps idle connections open, and a server process waiting on
    # one never lets the test clock settle: answer each request on its own.
    def call(conn, opts),
      do: conn |> Plug.Conn.put_resp_header("connection", "close") |> page(opts)

    defp page(%{request_path: "/slow"} = conn, _) do
      Plug.Conn.send_resp(
        conn,
        200,
        "<html><title>Slow</title><body><p>Loading</p><script>setTimeout(() => { document.body.insertAdjacentHTML('beforeend', '<button id=\"late\">Late</button>') }, 400)</script></body></html>"
      )
    end

    defp page(%{request_path: "/links"} = conn, _) do
      Plug.Conn.send_resp(
        conn,
        200,
        "<html><title>Links</title><body><a href=\"/slow\">Slow page</a> <a href=\"/empty\">No content</a></body></html>"
      )
    end

    defp page(%{request_path: "/empty"} = conn, _), do: Plug.Conn.send_resp(conn, 204, "")

    defp page(%{request_path: "/leave"} = conn, _) do
      Plug.Conn.send_resp(
        conn,
        200,
        "<html><title>Leave</title><body><button onclick=\"onbeforeunload = e => { e.preventDefault(); e.returnValue = '' }\">Arm</button></body></html>"
      )
    end

    defp page(conn, _) do
      Plug.Conn.send_resp(
        conn,
        200,
        "<html><title>Native navigation</title><body><button>Loaded</button></body></html>"
      )
    end
  end

  setup do
    directory = Path.join(System.tmp_dir!(), "browser-native-#{SystemsRuntime.Proc.uuid()}")
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

  test "snapshot outlines roles, names, states and refs that persist until navigation", %{
    driver: driver,
    tab: tab
  } do
    set_content(driver, tab, """
    <h1>Order form</h1>
    <p>Fill in the <a href="/help">help</a> page first.</p>
    <form>
      <input aria-label="Name" value="Ann">
      <label>Month <select name="month"><option value="1">January</option><option value="2" selected>February</option></select></label>
      <label><input type="checkbox" name="agree"> Agree</label>
      <input type="password" aria-label="Secret">
      <button type="submit">Save</button>
      <div hidden>Hidden text</div>
      <span style="display:none">Invisible</span>
    </form>
    <ul><li>First item</li><li>Second item</li></ul>
    """)

    assert {:ok, snapshot} = Driver.request(driver, "snapshot", %{"tab_id" => tab})
    assert snapshot["tab_id"] == tab
    assert snapshot["scope"] == "viewport"
    text = snapshot["snapshot"]
    assert text =~ ~r/^- heading "Order form" level=1$/m
    assert text =~ ~r/^- paragraph "Fill in the help page first."$/m
    assert text =~ ~r/^  - link "help" \[e\d+\] href=\/help$/m
    assert text =~ ~r/^- form$/m
    assert text =~ ~r/^  - textbox "Name" \[e\d+\] value="Ann"$/m
    assert text =~ ~r/^  - combobox "Month" \[e\d+\] value="February"$/m
    assert text =~ ~r/^    - option "February" selected$/m
    assert text =~ ~r/^  - checkbox "Agree" \[e\d+\] unchecked$/m
    assert text =~ ~r/^  - textbox "Secret" \[e\d+\] type=password empty$/m
    assert text =~ ~r/^  - button "Save" \[e\d+\]$/m
    assert text =~ ~r/^- list$/m
    assert text =~ ~r/^  - listitem "First item"$/m
    refute text =~ "Hidden text"
    refute text =~ "Invisible"
    refute snapshot["truncated"]

    save = ref_of(text, ~r/button "Save" \[(e\d+)\]/)
    assert {:ok, again} = Driver.request(driver, "snapshot", %{"tab_id" => tab})
    assert ref_of(again["snapshot"], ~r/button "Save" \[(e\d+)\]/) == save

    assert {:ok, only} =
             Driver.request(driver, "snapshot", %{"tab_id" => tab, "interactive_only" => true})

    refute only["snapshot"] =~ "paragraph"
    assert only["snapshot"] =~ ~r/button "Save" \[#{save}\]/

    agree = ref_of(text, ~r/checkbox "Agree" \[(e\d+)\]/)
    assert {:ok, receipt} = Driver.request(driver, "click", %{"tab_id" => tab, "ref" => agree})
    assert receipt["snapshot"] =~ ~r/checkbox "Agree" \[#{agree}\] checked/
    assert receipt["url"] =~ "about:blank"
    assert receipt["title"] == ""

    assert {:ok, subtree} =
             Driver.request(driver, "snapshot", %{
               "tab_id" => tab,
               "scope" => "subtree",
               "ref" => ref_of(text, ~r/combobox "Month" \[(e\d+)\]/)
             })

    assert subtree["snapshot"] =~ ~r/^- combobox "Month"/
    refute subtree["snapshot"] =~ "button"
  end

  test "actions run steps in order and report the step that cannot run", %{
    driver: driver,
    tab: tab
  } do
    set_content(driver, tab, """
    <input aria-label="Name"><input aria-label="City">
    <select aria-label="Size"><option>Small</option><option>Large</option></select>
    <button onclick="document.querySelector('output').textContent=[...document.querySelectorAll('input,select')].map(e=>e.value).join('|')">Save</button>
    <output></output>
    """)

    assert {:ok, receipt} =
             Driver.request(driver, "actions", %{
               "tab_id" => tab,
               "steps" => [
                 %{"op" => "fill", "target" => "role=textbox[name=\"Name\"]", "text" => "Ann"},
                 %{"op" => "fill", "target" => "css=[aria-label=City]", "text" => "Oslo"},
                 %{
                   "op" => "select",
                   "target" => "role=combobox[name=\"Size\"]",
                   "value" => "Large"
                 },
                 %{"op" => "click", "target" => "text=Save"},
                 %{"op" => "wait", "text" => "Ann|Oslo|Large"}
               ]
             })

    assert receipt["steps_completed"] == 5
    refute Map.has_key?(receipt, "failed_step")
    assert receipt["snapshot"] =~ ~r/status "Ann\|Oslo\|Large"/
    assert eval(driver, tab, "document.querySelector('output').textContent") == "Ann|Oslo|Large"

    assert {:ok, failed} =
             Driver.request(driver, "actions", %{
               "tab_id" => tab,
               "steps" => [
                 %{"op" => "fill", "target" => "role=textbox[name=\"Name\"]", "text" => "Bob"},
                 %{"op" => "click", "target" => "text=Missing"},
                 %{"op" => "fill", "target" => "css=[aria-label=City]", "text" => "never"}
               ]
             })

    assert failed["steps_completed"] == 1

    assert failed["failed_step"] == %{
             "index" => 1,
             "op" => "click",
             "error" => "target_not_found"
           }

    assert failed["snapshot"] =~ ~r/textbox "Name" \[e\d+\] value="Bob"/
    assert eval(driver, tab, "document.querySelector('[aria-label=City]').value") == "Oslo"

    assert {:error, "invalid_input"} =
             Driver.request(driver, "actions", %{"tab_id" => tab, "steps" => []})

    assert {:ok, bad} =
             Driver.request(driver, "actions", %{
               "tab_id" => tab,
               "steps" => [%{"op" => "screenshot"}]
             })

    assert bad["failed_step"]["error"] == "invalid_input"
  end

  test "targets resolve by text, role and CSS, and ambiguity lists candidates", %{
    driver: driver,
    tab: tab
  } do
    set_content(driver, tab, """
    <button id="primary" onclick="document.body.dataset.clicked='primary'">Save</button>
    <button onclick="document.body.dataset.clicked='draft'">Save <b>draft</b></button>
    <div role="button" tabindex="0" onclick="document.body.dataset.clicked='custom'"><span>Custom</span> action</div>
    <input placeholder="Search here">
    """)

    assert {:error, "ambiguous_target", details} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Save"})

    assert details["count"] == 2
    assert [%{"ref" => ref, "role" => "button", "name" => "Save"}, _] = details["candidates"]

    assert {:error, "ambiguous_target", _} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "role=button"})

    # A batch reports an ambiguous step with its candidates after the steps
    # that already ran.
    assert {:ok, batch} =
             Driver.request(driver, "actions", %{
               "tab_id" => tab,
               "steps" => [
                 %{
                   "op" => "fill",
                   "target" => "role=textbox[name=\"Search here\"]",
                   "text" => "q"
                 },
                 %{"op" => "click", "target" => "text=Save"}
               ]
             })

    assert batch["steps_completed"] == 1
    assert %{"index" => 1, "error" => "ambiguous_target", "count" => 2} = batch["failed_step"]
    assert [%{"ref" => ^ref}, _] = batch["failed_step"]["candidates"]
    assert batch["snapshot"] =~ ~r/textbox "Search here" \[e\d+\] value="q"/

    assert {:ok, _} = Driver.request(driver, "click", %{"tab_id" => tab, "target" => ref})
    assert eval(driver, tab, "document.body.dataset.clicked") == "primary"

    assert {:ok, _} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=\"Save draft\""})

    assert eval(driver, tab, "document.body.dataset.clicked") == "draft"

    assert {:ok, _} =
             Driver.request(driver, "click", %{
               "tab_id" => tab,
               "target" => "role=button[name=\"custom action\"]"
             })

    assert eval(driver, tab, "document.body.dataset.clicked") == "custom"
    assert {:ok, _} = Driver.request(driver, "click", %{"tab_id" => tab, "target" => "#primary"})

    assert {:ok, receipt} =
             Driver.request(driver, "fill", %{
               "tab_id" => tab,
               "target" => "role=textbox[name=\"Search here\"]",
               "text" => "query"
             })

    assert receipt["snapshot"] =~ ~r/textbox "Search here" \[e\d+\] value="query"/

    assert {:error, "target_not_found"} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Nowhere"})

    assert {:error, "invalid_input"} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "css=[["})

    assert {:error, "stale_element"} =
             Driver.request(driver, "click", %{"tab_id" => tab, "ref" => "e999"})
  end

  test "receipts report opened tabs and JavaScript dialogs", %{driver: driver, tab: tab} do
    set_content(driver, tab, """
    <a href="about:blank#popup" target="_blank">Open</a>
    <button onclick="document.body.dataset.answer = confirm('Continue?')">Ask</button>
    <button onclick="document.body.dataset.name = prompt('Name?', 'nobody')">Prompt</button>
    """)

    assert {:ok, receipt} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Open"})

    assert [%{"tab_id" => popup}] = receipt["new_tabs"]
    assert {:ok, %{"tabs" => tabs}} = Driver.request(driver, "tabs", %{})
    assert Enum.any?(tabs, &(&1["tab_id"] == popup))
    assert {:ok, _} = Driver.request(driver, "close_tab", %{"tab_id" => popup})

    assert {:ok, asked} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Ask"})

    assert asked["dialog"] == %{
             "type" => "confirm",
             "message" => "Continue?",
             "default_prompt" => ""
           }

    refute Map.has_key?(asked, "snapshot")

    assert {:error, "dialog_open", %{"dialog" => %{"type" => "confirm"}}} =
             Driver.request(driver, "snapshot", %{"tab_id" => tab})

    assert {:error, "dialog_open", _} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Prompt"})

    assert {:ok, handled} =
             Driver.request(driver, "dialog", %{"tab_id" => tab, "action" => "dismiss"})

    assert handled["handled_dialog"]["type"] == "confirm"
    assert handled["snapshot"] =~ ~r/button "Ask" \[e\d+\]/
    assert eval(driver, tab, "document.body.dataset.answer") == "false"

    assert {:ok, _} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Prompt"})

    assert {:ok, _} =
             Driver.request(driver, "dialog", %{
               "tab_id" => tab,
               "action" => "accept",
               "prompt_text" => "Ann"
             })

    assert eval(driver, tab, "document.body.dataset.name") == "Ann"

    assert {:error, "invalid_input"} =
             Driver.request(driver, "dialog", %{"tab_id" => tab, "action" => "accept"})
  end

  test "a click that navigates returns the new document, a cancelled one the old", %{
    driver: driver,
    tab: tab
  } do
    server =
      start_supervised!({Bandit, plug: Page, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _} =
             Driver.request(driver, "navigate", %{
               "tab_id" => tab,
               "url" => "http://127.0.0.1:#{port}/links"
             })

    assert {:ok, cancelled} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=No content"})

    assert cancelled["title"] == "Links"

    assert {:ok, navigated} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Slow page"})

    assert navigated["title"] == "Slow"
    assert navigated["snapshot"] =~ "Loading"
  end

  test "dialogs that hold a navigation or follow a selection are reported", %{
    driver: driver,
    tab: tab
  } do
    server =
      start_supervised!({Bandit, plug: Page, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    assert {:ok, _} =
             Driver.request(driver, "navigate", %{
               "tab_id" => tab,
               "url" => "http://127.0.0.1:#{port}/leave"
             })

    assert {:ok, _} = Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Arm"})

    # The held navigation goes to a socket the test answers itself: the
    # browser connects ahead while the dialog is open, and a server process
    # waiting on that connection would keep the test clock from settling.
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true])

    {:ok, next_port} = :inet.port(listener)

    assert {:ok, held} =
             Driver.request(driver, "navigate", %{
               "tab_id" => tab,
               "url" => "http://127.0.0.1:#{next_port}/left"
             })

    assert held["dialog"]["type"] == "beforeunload"

    assert {:ok, leaving} =
             Driver.request(driver, "dialog", %{"tab_id" => tab, "action" => "accept"})

    assert leaving["loading"]
    socket = request_socket(listener)
    body = "<html><title>Left</title><body>Left</body></html>"

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\nconnection: close\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <>
          body
      )

    :gen_tcp.close(socket)
    :gen_tcp.close(listener)

    assert {:ok, left} =
             Driver.request(driver, "wait", %{"tab_id" => tab, "url_contains" => "/left"})

    assert left["title"] == "Left"

    set_content(driver, tab, """
    <select aria-label="Size" onchange="alert('Changed')"><option>Small</option><option>Large</option></select>
    """)

    assert {:ok, selected} =
             Driver.request(driver, "select", %{
               "tab_id" => tab,
               "target" => "role=combobox[name=\"Size\"]",
               "value" => "Large"
             })

    assert selected["dialog"]["message"] == "Changed"
    assert {:ok, _} = Driver.request(driver, "dialog", %{"tab_id" => tab, "action" => "accept"})
    assert eval(driver, tab, "document.querySelector('select').value") == "Large"
  end

  test "targets skip hidden names, see into boxless containers and never click through a cover",
       %{driver: driver, tab: tab} do
    set_content(driver, tab, """
    <div style="display:contents"><button onclick="document.body.dataset.clicked='contents'">Inside contents</button></div>
    <button style="display:none">Submit</button>
    <button onclick="document.body.dataset.clicked='order'">Submit order</button>
    <div style="position:relative">
      <iframe title="Covered" style="width:300px;height:100px;border:0" srcdoc="<button style='width:280px;height:80px' onclick='parent.document.body.dataset.clicked=&quot;frame&quot;'>Covered button</button>"></iframe>
      <button style="position:absolute;left:0;top:0;width:300px;height:100px" onclick="document.body.dataset.clicked='cover'">Cover</button>
    </div>
    """)

    assert {:ok, snapshot} =
             Driver.request(driver, "wait", %{"tab_id" => tab, "text" => "Covered button"})

    assert snapshot["snapshot"] =~ ~r/^- button "Inside contents" \[e\d+\]$/m

    assert {:ok, _} =
             Driver.request(driver, "click", %{
               "tab_id" => tab,
               "target" => "role=button[name=\"Submit\"]"
             })

    assert eval(driver, tab, "document.body.dataset.clicked") == "order"

    assert {:ok, _} =
             Driver.request(driver, "click", %{
               "tab_id" => tab,
               "target" => "text=Inside contents"
             })

    assert eval(driver, tab, "document.body.dataset.clicked") == "contents"

    assert {:error, "browser_operation_failed"} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Covered button"})

    assert eval(driver, tab, "document.body.dataset.clicked") == "contents"
  end

  test "same-origin frames and shadow roots are captured and clickable", %{
    driver: driver,
    tab: tab
  } do
    set_content(driver, tab, """
    <div style="height:150px">Top</div>
    <iframe title="Inner" style="margin-left:200px;width:400px;height:300px" srcdoc="<button onclick='parent.document.body.dataset.clicked=&quot;frame&quot;' style='margin-top:120px'>Frame button</button>"></iframe>
    <my-widget></my-widget>
    <script>
      customElements.define('my-widget', class extends HTMLElement {
        connectedCallback() {
          this.attachShadow({mode: 'open'}).innerHTML = '<button>Shadow button</button>';
          this.shadowRoot.querySelector('button').onclick = () => { document.body.dataset.clicked = 'shadow' };
        }
      });
    </script>
    """)

    assert {:ok, snapshot} =
             Driver.request(driver, "wait", %{"tab_id" => tab, "text" => "Frame button"})

    assert snapshot["snapshot"] =~ ~r/^- iframe "Inner" \[e\d+\]$/m
    assert snapshot["snapshot"] =~ ~r/^  - button "Frame button" \[e\d+\]$/m
    assert snapshot["snapshot"] =~ ~r/^- button "Shadow button" \[e\d+\]$/m

    assert {:ok, _} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Frame button"})

    assert eval(driver, tab, "document.body.dataset.clicked") == "frame"

    assert {:ok, _} =
             Driver.request(driver, "click", %{"tab_id" => tab, "target" => "text=Shadow button"})

    assert eval(driver, tab, "document.body.dataset.clicked") == "shadow"
  end

  test "viewport scope follows scrolling, full scope reads everything, max_chars truncates", %{
    driver: driver,
    tab: tab
  } do
    paragraphs = Enum.map_join(1..60, "", &"<p style='height:100px'>Paragraph #{&1}</p>")
    set_content(driver, tab, paragraphs <> "<button>Bottom</button>")

    assert {:ok, top} = Driver.request(driver, "snapshot", %{"tab_id" => tab})
    assert top["snapshot"] =~ "Paragraph 1\""
    refute top["snapshot"] =~ "Paragraph 40\""
    assert top["scroll"]["y"] == 0
    assert top["scroll"]["page_height"] > top["scroll"]["viewport_height"]

    assert {:ok, scrolled} = Driver.request(driver, "scroll", %{"tab_id" => tab, "y" => 3000})
    assert scrolled["snapshot"] =~ ~r/Paragraph 3\d"/
    refute scrolled["snapshot"] =~ "Paragraph 1\""
    assert scrolled["scroll"]["y"] > 0

    assert {:ok, into_view} =
             Driver.request(driver, "scroll", %{"tab_id" => tab, "target" => "text=Bottom"})

    assert into_view["snapshot"] =~ ~r/button "Bottom" \[e\d+\]/

    assert {:ok, full} = Driver.request(driver, "snapshot", %{"tab_id" => tab, "scope" => "full"})
    assert full["snapshot"] =~ "Paragraph 1\""
    assert full["snapshot"] =~ "Paragraph 60\""
    refute full["truncated"]

    assert {:ok, short} =
             Driver.request(driver, "snapshot", %{
               "tab_id" => tab,
               "scope" => "full",
               "max_chars" => 500
             })

    assert short["truncated"]
    assert String.length(short["snapshot"]) <= 500
  end

  test "wait follows text, selectors and URLs and times out as a local failure", %{
    driver: driver,
    tab: tab
  } do
    server =
      start_supervised!({Bandit, plug: Page, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    assert {:ok, receipt} =
             Driver.request(driver, "navigate", %{
               "tab_id" => tab,
               "url" => "http://127.0.0.1:#{port}/slow"
             })

    assert receipt["title"] == "Slow"
    assert receipt["snapshot"] =~ "Loading"

    assert {:ok, waited} =
             Driver.request(driver, "wait", %{
               "tab_id" => tab,
               "selector" => "#late",
               "timeout_ms" => 5000
             })

    assert waited["snapshot"] =~ ~r/button "Late" \[e\d+\]/

    assert {:ok, _} =
             Driver.request(driver, "wait", %{"tab_id" => tab, "url_contains" => "/slow"})

    assert {:error, "wait_timeout"} =
             Driver.request(driver, "wait", %{
               "tab_id" => tab,
               "text" => "absent",
               "timeout_ms" => 200
             })

    assert {:error, "invalid_input"} = Driver.request(driver, "wait", %{"tab_id" => tab})
  end

  test "native observation, form actions, screenshot, keyboard and Unicode input", %{
    driver: driver,
    tab: tab
  } do
    set_content(driver, tab, """
    <input aria-label="Name"><button onclick="document.querySelector('output').textContent=document.querySelector('input').value">Save</button><output></output><input type="number" aria-label="Count" value="123">
    """)

    assert {:ok, snapshot} = Driver.request(driver, "snapshot", %{"tab_id" => tab})
    input = ref_of(snapshot["snapshot"], ~r/textbox "Name" \[(e\d+)\]/)
    button = ref_of(snapshot["snapshot"], ~r/button "Save" \[(e\d+)\]/)

    assert {:ok, _} =
             Driver.request(driver, "fill", %{
               "tab_id" => tab,
               "ref" => input,
               "text" => "agent text"
             })

    # A click waits until its target is actionable: the page enables the
    # button while the click is already in progress.
    eval(driver, tab, "document.querySelector('button').disabled=true")
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.Proc.spawn(fn ->
      SystemsRuntime.Proc.send(
        parent,
        {:clicked, Driver.request(driver, "click", %{"tab_id" => tab, "ref" => button})}
      )
    end)

    assert eventually(fn -> :sys.get_state(driver, :infinity).pending_op == "click" end)
    eval(driver, tab, "document.querySelector('button').disabled=false")
    settle_receive({:clicked, {:ok, _}})
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
    count = ref_of(snapshot["snapshot"], ~r/spinbutton "Count" \[(e\d+)\]/)

    assert {:ok, _} =
             Driver.request(driver, "fill", %{"tab_id" => tab, "ref" => count, "text" => "456"})

    assert eval(driver, tab, "document.querySelector('[type=number]').value") == "456"

    assert {:ok, pressed} =
             Driver.request(driver, "press", %{"tab_id" => tab, "key" => "Enter", "ref" => button})

    assert pressed["snapshot"] =~ ~r/button "Save" \[#{button}\] focused/
  end

  @tag :browser_review
  test "clearing a number field updates the application's input state", %{
    driver: driver,
    tab: tab
  } do
    set_content(driver, tab, """
    <input type="number" aria-label="Count" value="123" oninput="document.querySelector('output').textContent=this.value"><output>123</output>
    """)

    assert {:ok, snapshot} = Driver.request(driver, "snapshot", %{"tab_id" => tab})
    ref = ref_of(snapshot["snapshot"], ~r/spinbutton "Count" \[(e\d+)\]/)

    assert {:ok, _} =
             Driver.request(driver, "fill", %{"tab_id" => tab, "ref" => ref, "text" => ""})

    assert eval(driver, tab, "document.querySelector('input').value") == ""
    assert eval(driver, tab, "document.querySelector('output').textContent") == ""

    assert {:ok, _} =
             Driver.request(driver, "fill", %{"tab_id" => tab, "ref" => ref, "text" => "456"})

    assert eval(driver, tab, "document.querySelector('output').textContent") == "456"

    assert {:error, "invalid_input"} =
             Driver.request(driver, "fill", %{"tab_id" => tab, "ref" => ref, "text" => "abc"})
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

    assert {:error, "wait_timeout"} =
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

    assert {:ok, snapshot} = Driver.request(driver, "snapshot", %{"tab_id" => tab})
    old = ref_of(snapshot["snapshot"], ~r/button "Old" \[(e\d+)\]/)

    assert {:ok, receipt} =
             Driver.request(driver, "navigate", %{
               "tab_id" => tab,
               "url" => "http://127.0.0.1:#{port}/page"
             })

    assert receipt["title"] == "Native navigation"
    loaded = ref_of(receipt["snapshot"], ~r/button "Loaded" \[(e\d+)\]/)
    assert loaded != old

    assert {:error, "stale_element"} =
             Driver.request(driver, "click", %{"tab_id" => tab, "ref" => old})

    assert {:ok, %{"title" => "Native navigation", "snapshot" => text}} =
             Driver.request(driver, "snapshot", %{"tab_id" => tab})

    assert text =~ ~r/button "Loaded" \[#{loaded}\]/

    assert {:error, "invalid_url"} =
             Driver.request(driver, "navigate", %{"tab_id" => tab, "url" => "file:///etc/hosts"})

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

    assert {:ok, snapshot} = Driver.request(first, "snapshot", %{"tab_id" => tab})
    old = ref_of(snapshot["snapshot"], ~r/button "Old" \[(e\d+)\]/)

    set_content(
      first,
      tab,
      "<button onclick=\"document.body.dataset.clicked='new'\">New</button>"
    )

    stop_supervised(LocalDriver)
    {:ok, replacement} = start_supervised({LocalDriver, url: url})
    assert {:ok, _} = Driver.request(replacement, "tabs", %{})

    assert {:error, "stale_element"} =
             Driver.request(replacement, "click", %{"tab_id" => tab, "ref" => old})

    assert {:ok, snapshot} = Driver.request(replacement, "snapshot", %{"tab_id" => tab})
    current = ref_of(snapshot["snapshot"], ~r/button "New" \[(e\d+)\]/)

    assert {:error, "stale_element"} =
             Driver.request(replacement, "click", %{"tab_id" => tab, "ref" => "e999"})

    assert eval(replacement, tab, "document.body.dataset.clicked || null") == nil
    assert {:ok, _} = Driver.request(replacement, "click", %{"tab_id" => tab, "ref" => current})
    assert eval(replacement, tab, "document.body.dataset.clicked") == "new"
  end

  test "a viewer admitted during stop receives new frames", %{driver: driver, tab: tab} do
    assert {:ok, _} =
             Driver.request(driver, "stream_start", %{"tab_id" => tab, "viewer_id" => "old"})

    assert eventually(fn -> match?({:ok, %{"data" => _}}, Driver.frame(driver, tab)) end)
    conn = :sys.get_state(driver, :infinity).commands.conn
    :sys.suspend(conn, :infinity)
    GenServer.cast(driver, {:stop_stream, tab, "old"})
    assert :sys.get_state(driver, :infinity).pending != nil
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.Proc.spawn(fn ->
      SystemsRuntime.Proc.send(
        parent,
        {:started,
         Driver.request(driver, "stream_start", %{"tab_id" => tab, "viewer_id" => "new"})}
      )
    end)

    assert eventually(fn -> :queue.len(:sys.get_state(driver, :infinity).queue) == 1 end)
    :sys.resume(conn, :infinity)
    settle_receive({:started, {:ok, %{"streaming" => true}}})
    assert eventually(fn -> match?({:ok, %{"data" => _}}, Driver.frame(driver, tab)) end)
    {:ok, before} = Driver.frame(driver, tab)
    SystemsClock.sleep(120)
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
    parent = SystemsRuntime.Proc.self()

    SystemsRuntime.Proc.spawn(fn ->
      SystemsRuntime.Proc.send(
        parent,
        {:waited,
         Driver.request(driver, "wait", %{
           "tab_id" => tab,
           "text" => "absent",
           "timeout_ms" => 5000
         })}
      )
    end)

    assert eventually(fn -> :sys.get_state(driver, :infinity).pending != nil end)
    assert {:ok, %{"data" => _}} = Driver.frame(driver, tab)

    assert {:error, :browser_driver_busy} =
             Driver.request(driver, "input", %{
               "tab_id" => tab,
               "input" => %{"type" => "text", "text" => "never"}
             })

    conn = :sys.get_state(driver, :infinity).commands.conn
    monitor = SystemsRuntime.Proc.monitor(driver)
    GenServer.stop(conn, :normal)
    settle_receive({:waited, {:error, :browser_outcome_unknown}})
    settle_receive({:DOWN, ^monitor, :process, ^driver, _})
  end

  # The browser may open connections ahead and close some unused: the
  # request arrives on one of them.
  defp request_socket(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 10_000)

    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, "GET /left " <> _} -> socket
      {:error, :closed} -> request_socket(listener)
    end
  end

  defp ref_of(text, regex) do
    assert [_, ref] = Regex.run(regex, text), "no match for #{inspect(regex)} in:\n#{text}"
    ref
  end

  defp set_content(driver, tab, html) do
    eval(
      driver,
      tab,
      "document.open(); document.write(#{Jason.encode!(html)}); document.close();"
    )
  end

  defp eval(driver, tab, expression) do
    state = :sys.get_state(driver, :infinity).commands

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

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun, _retries \\ nil), do: settle_until(fun)
end
