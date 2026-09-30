defmodule SalixAgent.BrowserStorageTest do
  use ExUnit.Case, async: false
  alias SalixAgent.Browser
  alias SalixAgent.Browser.{Driver, Connection}
  alias SalixStore.{BrowserBindings, BrowserSettings, BrowserStorage, Ids, Repo}
  @moduletag :browser_local
  @moduletag timeout: 120_000

  # Real Chromium and SQL exercise the complete browser lifecycle. Only the
  # Cloudflare acquisition/deletion HTTP boundary is replaced locally.
  defmodule Provider do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
    def create(_, _), do: GenServer.call(__MODULE__, :create, 20_000)
    def close(row, _), do: GenServer.call(__MODULE__, {:close, row.provider_id}, 20_000)
    def connection(row, _), do: GenServer.call(__MODULE__, {:connection, row.provider_id})
    def status(row, _), do: GenServer.call(__MODULE__, {:status, row.provider_id})
    def fail_status(value), do: GenServer.call(__MODULE__, {:fail_status, value})
    def fail_close(value), do: GenServer.call(__MODULE__, {:fail_close, value})
    @impl true
    def init(_), do: {:ok, %{browsers: %{}, fail_close: false, fail_status: false}}
    @impl true
    def handle_call(:create, _, state) do
      id = Ecto.UUID.generate()
      directory = Path.join(System.tmp_dir!(), "comma-browser-storage-#{id}")
      File.mkdir_p!(directory)

      port =
        Port.open(
          {:spawn_executable, System.fetch_env!("BROWSER_DRIVER_CHROMIUM")},
          [
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
          ]
        )

      {:os_pid, pid} = Port.info(port, :os_pid)
      path = Path.join(directory, "DevToolsActivePort")
      wait_file(path, 200)
      [number, endpoint | _] = File.read!(path) |> String.split("\n")
      row = %{pid: pid, directory: directory, url: "ws://127.0.0.1:#{number}#{endpoint}"}
      {:reply, {:ok, %{"sessionId" => id}}, put_in(state.browsers[id], row)}
    end

    def handle_call({:connection, id}, _, state),
      do: {:reply, [url: (state.browsers[id] || %{url: "ws://127.0.0.1:1/expired"}).url], state}

    def handle_call({:fail_status, value}, _, state),
      do: {:reply, :ok, %{state | fail_status: value}}

    def handle_call({:status, _}, _, %{fail_status: true} = state),
      do: {:reply, {:error, :browser_provider_unavailable}, state}

    def handle_call({:status, id}, _, state),
      do:
        {:reply, {:ok, if(Map.has_key?(state.browsers, id), do: :active, else: :expired)}, state}

    def handle_call({:fail_close, value}, _, state),
      do: {:reply, :ok, %{state | fail_close: value}}

    def handle_call({:close, _}, _, %{fail_close: true} = state),
      do: {:reply, {:error, :browser_provider_unavailable}, state}

    def handle_call({:close, id}, _, state) do
      if row = state.browsers[id], do: stop(row)
      {:reply, {:ok, %{}}, %{state | browsers: Map.delete(state.browsers, id)}}
    end

    @impl true
    def handle_info(_, state), do: {:noreply, state}
    @impl true
    def terminate(_, state), do: Enum.each(state.browsers, fn {_, row} -> stop(row) end)

    defp stop(row) do
      System.cmd("kill", ["-TERM", to_string(row.pid)], stderr_to_stdout: true)
      wait_dead(row.pid, 100)
      File.rm_rf!(row.directory)
    end

    defp wait_dead(_, 0), do: :ok

    defp wait_dead(pid, n) do
      case System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true) do
        {_, 0} ->
          Process.sleep(20)
          wait_dead(pid, n - 1)

        _ ->
          :ok
      end
    end

    defp wait_file(_, 0), do: raise("Chromium did not start")

    defp wait_file(path, n) do
      if File.exists?(path),
        do: :ok,
        else:
          (
            Process.sleep(25)
            wait_file(path, n - 1)
          )
    end
  end

  defmodule Page do
    def init(opts), do: opts

    def call(conn, _) do
      conn = Plug.Conn.fetch_cookies(conn)

      {conn, script} =
        case conn.request_path do
          "/login" ->
            {Plug.Conn.put_resp_cookie(conn, "login", "secret-login",
               http_only: true,
               same_site: "Lax"
             ), "localStorage.setItem('account','shared-account');"}

          "/logout" ->
            {Plug.Conn.delete_resp_cookie(conn, "login"), "localStorage.clear();"}

          _ ->
            {conn, ""}
        end

      cookie = Jason.encode!(conn.req_cookies["login"])

      Plug.Conn.send_resp(
        Plug.Conn.put_resp_content_type(conn, "text/html"),
        200,
        "<script>window.initial=localStorage.getItem('account');window.cookie=#{cookie};#{script}</script><body><input id='entry' autofocus>Storage test</body>"
      )
    end
  end

  setup do
    old_key = Application.get_env(:salix_store, :compute_workload_credential_secret)
    old_provider = Application.get_env(:salix_agent, :browser_provider)

    Application.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("test", 16)
    )

    Application.put_env(:salix_agent, :browser_provider, Provider)
    start_supervised!(Provider)

    unless Process.whereis(SalixAgent.Browser.Supervisor),
      do:
        start_supervised!(
          {DynamicSupervisor, name: SalixAgent.Browser.Supervisor, strategy: :one_for_one}
        )

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    owner = Browser.owner(%{agent_id: Ids.new_agent_id(group), session_id: "first-task"})
    other = Browser.owner(%{agent_id: Ids.new_agent_id(group), session_id: "second-task"})

    assert {:ok, _} =
             BrowserSettings.put(tenant, %{
               "mode" => "override",
               "account_id" => String.duplicate("a", 32),
               "api_token" => "local"
             })

    server =
      start_supervised!({Bandit, plug: Page, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      if old_key,
        do: Application.put_env(:salix_store, :compute_workload_credential_secret, old_key),
        else: Application.delete_env(:salix_store, :compute_workload_credential_secret)

      if old_provider,
        do: Application.put_env(:salix_agent, :browser_provider, old_provider),
        else: Application.delete_env(:salix_agent, :browser_provider)

      import Ecto.Query
      Repo.delete_all(from(r in BrowserBindings.Row, where: r.tenant_id == ^tenant))
      Repo.delete_all(BrowserStorage.query(owner))
      Repo.delete_all(from(r in BrowserSettings.Row, where: r.scope == ^tenant))
    end)

    %{owner: owner, other: other, base: "http://127.0.0.1:#{port}"}
  end

  test "another task restores HttpOnly login and local storage before its first page script; logout and clear survive",
       %{owner: owner, other: other, base: base} do
    tab = open(owner)
    assert {:error, :browser_shared_profile_in_use} = Browser.execute(other, "open", %{})
    navigate(owner, tab, base <> "/login")
    assert {:ok, _} = Browser.execute(owner, "take_control", %{}, "human")
    {:ok, driver} = Driver.ensure(BrowserBindings.get(owner))
    send(driver, :checkpoint)

    assert eventually(fn ->
             match?(
               {:ok, %{"cookies" => [%{"value" => "secret-login"}]}},
               BrowserStorage.load(owner)
             )
           end)

    assert BrowserBindings.get(owner).control == "human"
    assert {:ok, saved} = BrowserStorage.load(owner)
    assert [%{"httpOnly" => true, "value" => "secret-login"}] = saved["cookies"]
    assert saved["origins"][base] == [["account", "shared-account"]]
    refute inspect(Repo.one(BrowserStorage.query(owner))) =~ "secret-login"
    # Restore must not run on a CDP reconnect to the same browser.
    eval(owner, tab, "localStorage.setItem('account','newer-value')")
    Driver.stop(BrowserBindings.get(owner))
    assert eval(owner, tab, "localStorage.getItem('account')") == "newer-value"
    assert {:ok, %{status: "closed", storage_error: nil}} = Browser.execute(owner, "close", %{})

    tab = open(other)
    navigate(other, tab, base <> "/page")
    assert eval(other, tab, "window.initial") == "newer-value"
    assert eval(other, tab, "window.cookie") == "secret-login"
    assert eval(other, tab, "document.cookie") == ""
    navigate(other, tab, String.replace(base, "127.0.0.1", "localhost") <> "/page")
    assert eval(other, tab, "window.initial") == nil
    assert eval(other, tab, "window.cookie") == nil
    # Capture an origin even after navigating away, then preserve its deletions.
    navigate(other, tab, base <> "/logout")
    navigate(other, tab, String.replace(base, "127.0.0.1", "localhost") <> "/page")
    assert {:ok, %{storage_error: nil}} = Browser.execute(other, "close", %{})
    tab = open(owner)
    navigate(owner, tab, base <> "/page")
    assert eval(owner, tab, "window.initial") == nil
    assert eval(owner, tab, "window.cookie") == nil
    navigate(owner, tab, base <> "/login")
    assert {:ok, _} = Browser.checkpoint(owner)
    assert {:error, false_reason} = Browser.execute(owner, "clear_storage", %{})
    assert false_reason == :unsupported_browser_operation
    assert {:ok, %{status: "closed"}} = Browser.execute(owner, "clear_storage", %{}, "human")
    assert {:ok, %{"cookies" => [], "origins" => %{}}} = BrowserStorage.load(owner)
    tab = open(other)
    navigate(other, tab, base <> "/page")
    assert eval(other, tab, "window.initial") == nil
    assert eval(other, tab, "window.cookie") == nil
    assert {:ok, _} = Browser.execute(other, "close", %{})
  end

  test "provider close failure retains ownership; recovery preserves the last saved checkpoint",
       %{owner: owner, other: other, base: base} do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")
    assert {:ok, _} = Browser.checkpoint(owner)
    Provider.fail_close(true)
    assert {:error, :browser_provider_unavailable} = Browser.execute(owner, "close", %{})
    assert {:error, :browser_shared_profile_in_use} = Browser.execute(other, "open", %{})
    Provider.fail_close(false)

    assert {:ok, %{storage_error: "browser_storage_not_saved"}} =
             Browser.execute(owner, "close", %{})

    tab = open(other)
    navigate(other, tab, base <> "/page")
    assert eval(other, tab, "window.initial") == "shared-account"
    assert {:ok, _} = Browser.execute(other, "close", %{})
  end

  test "unreadable saved storage never publishes a fresh browser as ready", %{
    owner: owner,
    other: other,
    base: base
  } do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")
    assert {:ok, _} = Browser.execute(owner, "close", %{})
    Repo.update_all(BrowserStorage.query(owner), set: [ciphertext: "corrupt"])
    assert {:error, :browser_storage_unavailable} = Browser.execute(other, "open", %{})
    assert BrowserBindings.get(other).status == "restoring"
    assert {:error, :browser_not_ready} = Browser.execute(other, "tabs", %{})
    assert {:error, :browser_shared_profile_in_use} = Browser.execute(owner, "open", %{})
    assert {:ok, %{status: "closed"}} = Browser.execute(other, "clear_storage", %{}, "human")
    assert {:ok, _} = Browser.execute(owner, "open", %{})
    assert {:ok, _} = Browser.execute(owner, "close", %{})
  end

  @tag :review_regression
  test "more than 64 origins and cookies survive replacement without a lifetime origin cap", %{
    owner: owner,
    other: other,
    base: base
  } do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")
    row = BrowserBindings.get(owner)
    {:ok, driver} = Driver.ensure(row)
    conn = :sys.get_state(driver).commands.conn
    origins = Map.new(1..70, fn i -> {"http://site-#{i}.test", [["account", "saved-#{i}"]]} end)

    assert {:ok, _} =
             Driver.call(row, "storage_restore", %{"cookies" => [], "origins" => origins})

    Enum.each(Map.keys(origins), &Connection.remember_origin(conn, &1))
    assert {:ok, %{storage_error: nil}} = Browser.execute(owner, "close", %{})
    assert {:ok, saved} = BrowserStorage.load(owner)
    assert map_size(saved["origins"]) == 71
    assert [%{"value" => "secret-login"}] = saved["cookies"]
    open(other)
    assert {:ok, %{storage_error: nil}} = Browser.execute(other, "close", %{})
    assert {:ok, restored} = BrowserStorage.load(other)
    assert restored["origins"] == saved["origins"]
    assert restored["cookies"] == saved["cookies"]
  end

  @tag :review_regression
  test "human input and agent commands remain usable during a background checkpoint", %{
    owner: owner,
    base: base
  } do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")

    for principal <- [:agent, "human"] do
      if principal == "human",
        do: assert({:ok, _} = Browser.execute(owner, "take_control", %{}, principal))

      {:ok, driver} = Driver.ensure(BrowserBindings.get(owner))
      conn = :sys.get_state(driver).commands.conn
      :sys.suspend(conn)

      try do
        checkpoint = Task.async(fn -> Browser.checkpoint(owner) end)
        assert eventually(fn -> not is_nil(:sys.get_state(driver).pending) end)
        operation = if principal == :agent, do: "snapshot", else: "input"

        command =
          Task.async(fn ->
            Browser.execute(
              owner,
              operation,
              %{"tab_id" => tab, "input" => %{"type" => "text", "text" => "typed-during-save"}},
              principal
            )
          end)

        Process.sleep(50)
        :sys.resume(conn)
        assert {:ok, _} = Task.await(command, 20_000)
        Task.await(checkpoint, 20_000)
        assert BrowserBindings.get(owner).pending == nil
      after
        :sys.resume(conn)
      end
    end

    assert BrowserBindings.get(owner).control == "human"
    assert eval(owner, tab, "document.querySelector('#entry').value") == "typed-during-save"
    assert {:ok, _} = Browser.execute(owner, "close", %{})
  end

  @tag :review2_regression
  test "reopening the caller's browser after a pause preserves its provider and tabs", %{
    owner: owner,
    base: base
  } do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")
    provider = BrowserBindings.get(owner).provider_id

    Repo.update_all(BrowserBindings.query(owner),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -901)]
    )

    assert {:ok, _} = Browser.execute(owner, "open", %{})
    assert BrowserBindings.get(owner).provider_id == provider
    assert {:ok, %{"tabs" => tabs}} = Browser.execute(owner, "tabs", %{})
    assert Enum.any?(tabs, &(&1["tab_id"] == tab))
    assert {:ok, _} = Browser.execute(owner, "close", %{})
  end

  @tag :self_expiry_regression
  test "self-open replaces an expired provider and restores its saved login", %{
    owner: owner,
    base: base
  } do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")
    assert {:ok, _} = Browser.checkpoint(owner)
    expired = BrowserBindings.get(owner)
    assert {:ok, _} = Provider.close(expired, nil)
    # Deterministically reproduce open after the dead CDP driver has stopped.
    :ok = Driver.stop(expired)
    tab = open(owner)
    current = BrowserBindings.get(owner)
    assert current.provider_id != expired.provider_id
    navigate(owner, tab, base <> "/page")
    assert eval(owner, tab, "window.initial") == "shared-account"
    assert eval(owner, tab, "window.cookie") == "secret-login"
    Provider.fail_status(true)
    assert {:error, :browser_provider_unavailable} = Browser.execute(owner, "open", %{})
    assert BrowserBindings.get(owner).provider_id == current.provider_id
    assert BrowserBindings.get(owner).status == "ready"
    Provider.fail_status(false)
    assert {:ok, _} = Browser.execute(owner, "close", %{})
  end

  @tag :lost_create_regression
  test "another task recovers a lost create only after its expiry bound", %{
    owner: owner,
    other: other
  } do
    {:ok, settings} = BrowserSettings.resolve(owner.tenant_id)
    {:ok, creating} = BrowserBindings.reserve(owner, settings)
    assert {:error, :browser_shared_profile_in_use} = Browser.execute(other, "open", %{})
    assert BrowserBindings.get(owner).pending == creating.pending

    Repo.update_all(BrowserBindings.query(owner),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -121)]
    )

    open(other)
    assert BrowserBindings.get(owner).status == "closed"

    assert {:error, :browser_operation_superseded} =
             BrowserBindings.record_provider(creating, "late-provider")

    assert {:error, :browser_operation_superseded} =
             BrowserBindings.finish(creating, %{status: "ready"})

    assert {:ok, _} = Browser.execute(other, "close", %{})
  end

  for handoff <- [false, true] do
    @tag :review2_regression
    test "a live browser remains owned through a long pause, handoff=#{handoff}", %{
      owner: owner,
      other: other,
      base: base
    } do
      tab = open(owner)
      navigate(owner, tab, base <> "/login")
      if unquote(handoff), do: assert({:ok, _} = Browser.execute(owner, "request_control", %{}))
      provider = BrowserBindings.get(owner).provider_id

      Repo.update_all(BrowserBindings.query(owner),
        set: [updated_at: DateTime.add(DateTime.utc_now(), -901)]
      )

      assert {:error, :browser_shared_profile_in_use} = Browser.execute(other, "open", %{})
      assert BrowserBindings.get(owner).provider_id == provider
      assert BrowserBindings.get(owner).status == "ready"

      if unquote(handoff),
        do: assert({:ok, _} = Browser.execute(owner, "take_control", %{}, "human"))

      assert {:ok, _} = Browser.execute(owner, "close", %{})
    end
  end

  @tag :review2_regression
  test "a failed later export reports partial persistence and retains saved cookies", %{
    owner: owner,
    base: base
  } do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")
    row = BrowserBindings.get(owner)
    {:ok, driver} = Driver.ensure(row)
    conn = :sys.get_state(driver).commands.conn

    origins =
      Map.new(1..5, fn i ->
        value = if i == 5, do: String.duplicate("x", 2_200_000), else: "small"
        {"http://partial-#{i}.test", [["value", value]]}
      end)

    assert {:ok, _} =
             Driver.call(row, "storage_restore", %{"cookies" => [], "origins" => origins})

    for i <- 1..5, do: Connection.remember_origin(conn, "http://partial-#{i}.test")

    assert {:ok, %{status: "closed", storage_error: "browser_storage_partially_saved"}} =
             Browser.execute(owner, "close", %{})

    assert {:ok, saved} = BrowserStorage.load(owner)
    assert [%{"value" => "secret-login"}] = saved["cookies"]
    assert saved["origins"][base] == [["account", "shared-account"]]
    refute Map.has_key?(saved["origins"], "http://partial-5.test")
  end

  test "a later task recovers provider expiry but status failure cannot release ownership", %{
    owner: owner,
    other: other,
    base: base
  } do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")
    assert {:ok, _} = Browser.checkpoint(owner)
    assert {:ok, _} = Provider.close(BrowserBindings.get(owner), nil)
    Provider.fail_status(true)
    assert {:error, :browser_provider_unavailable} = Browser.execute(other, "open", %{})
    assert BrowserBindings.get(owner).status == "ready"
    assert BrowserBindings.get(other) == nil
    Provider.fail_status(false)
    tab = open(other)
    assert BrowserBindings.get(owner).status == "closed"
    navigate(other, tab, base <> "/page")
    assert eval(other, tab, "window.initial") == "shared-account"
    assert eval(other, tab, "window.cookie") == "secret-login"
    assert {:ok, _} = Browser.execute(other, "close", %{})
  end

  test "the Group byte budget evicts the least recently used storage and restoration preserves recent data",
       %{owner: owner, other: other, base: base} do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")
    row = BrowserBindings.get(owner)
    {:ok, driver} = Driver.ensure(row)
    conn = :sys.get_state(driver).commands.conn

    origins =
      Map.new(1..5, fn i ->
        {"http://old-#{i}.test", [["large", String.duplicate("x", 230_000)]]}
      end)

    assert {:ok, _} =
             Driver.call(row, "storage_restore", %{"cookies" => [], "origins" => origins})

    for i <- 1..5, do: Connection.remember_origin(conn, "http://old-#{i}.test")
    # A real use makes this origin recent before the final checkpoint.
    navigate(owner, tab, base <> "/page")
    assert {:ok, %{storage_error: nil}} = Browser.execute(owner, "close", %{})
    assert {:ok, saved} = BrowserStorage.load(owner)
    assert byte_size(Jason.encode!(saved)) <= 1_048_576
    refute Map.has_key?(saved["origins"], "http://old-1.test")
    assert Map.has_key?(saved["origins"], "http://old-5.test")
    assert saved["origins"][base] == [["account", "shared-account"]]
    tab = open(other)
    navigate(other, tab, base <> "/page")
    assert eval(other, tab, "window.initial") == "shared-account"
    assert eval(other, tab, "window.cookie") == "secret-login"
    assert {:ok, _} = Browser.execute(other, "close", %{})
  end

  @tag :review3_regression
  test "passive frames, reconnects and saves cannot retain or restart an idle browser", %{
    owner: owner,
    other: other,
    base: base
  } do
    tab = open(owner)
    navigate(owner, tab, base <> "/login")
    row = BrowserBindings.get(owner)
    {:ok, driver} = Driver.ensure(row)
    monitor = Process.monitor(driver)
    age_driver(driver)

    for i <- 1..3 do
      assert {:ok, _} =
               Driver.call(row, "stream_start", %{
                 "tab_id" => tab,
                 "viewer_id" => "viewer-#{i}"
               })

      assert {:ok, _} = Driver.frame(driver, tab)
      assert {:ok, _} = Browser.checkpoint(owner)

      assert {:ok, _} =
               Driver.request(driver, "stream_stop", %{
                 "tab_id" => tab,
                 "viewer_id" => "viewer-#{i}"
               })
    end

    assert_receive {:DOWN, ^monitor, :process, ^driver, :normal}, 3000

    for _ <- 1..3 do
      assert {:error, :browser_driver_unavailable} = Driver.observe(row)
      assert {:error, :browser_driver_unavailable} = Driver.call(row, "storage_export")
    end

    assert {:error, :browser_shared_profile_in_use} = Browser.execute(other, "open", %{})
    assert {:ok, _} = Provider.close(row, nil)
    tab = open(other)
    navigate(other, tab, base <> "/page")
    assert eval(other, tab, "window.initial") == "shared-account"
    assert eval(other, tab, "window.cookie") == "secret-login"
    assert {:ok, _} = Browser.execute(other, "close", %{})
  end

  @tag :review3_regression
  test "human control retains an idle driver only while its lease is active", %{owner: owner} do
    open(owner)
    assert {:ok, _} = Browser.execute(owner, "request_control", %{})
    assert {:ok, _} = Browser.execute(owner, "take_control", %{}, "human")
    row = BrowserBindings.get(owner)
    {:ok, driver} = Driver.ensure(row)
    monitor = Process.monitor(driver)
    age_driver(driver)
    refute_receive {:DOWN, ^monitor, :process, ^driver, _}, 1500
    :ok = BrowserBindings.heartbeat(owner, "human")
    send(driver, :idle)
    refute_receive {:DOWN, ^monitor, :process, ^driver, _}, 100

    Repo.update_all(BrowserBindings.query(owner),
      set: [controller_expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    send(driver, :idle)
    assert_receive {:DOWN, ^monitor, :process, ^driver, :normal}, 1000
    # Explicit human interaction may reconnect while the provider is still live.
    assert {:ok, _} = Browser.execute(owner, "take_control", %{}, "human")
    assert {:ok, replacement} = Driver.observe(row)
    assert replacement != driver
    assert {:ok, _} = Browser.execute(owner, "close", %{})
  end

  @tag :review3_regression
  test "explicit commands renew inactivity but pending handoff alone does not", %{owner: owner} do
    open(owner)
    row = BrowserBindings.get(owner)
    {:ok, driver} = Driver.ensure(row)
    monitor = Process.monitor(driver)
    age_driver(driver)
    assert {:ok, _} = Browser.execute(owner, "tabs", %{})
    refute_receive {:DOWN, ^monitor, :process, ^driver, _}, 1500
    assert {:ok, _} = Browser.execute(owner, "request_control", %{})
    age_driver(driver)
    assert_receive {:DOWN, ^monitor, :process, ^driver, :normal}, 3000
    assert BrowserBindings.get(owner).control == "handoff_pending"
    assert {:ok, _} = Browser.execute(owner, "close", %{})
  end

  defp age_driver(driver) do
    :sys.replace_state(driver, fn state ->
      Process.cancel_timer(state.idle)

      %{
        state
        | last_activity: System.monotonic_time(:millisecond) - 600_001,
          idle: Process.send_after(driver, :idle, 1000)
      }
    end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(25)
          eventually(fun, attempts - 1)
        )
  end

  defp open(owner) do
    assert {:ok, %{"tabs" => [%{"tab_id" => tab} | _]}} = Browser.execute(owner, "open", %{})
    tab
  end

  defp navigate(owner, tab, url),
    do: assert({:ok, _} = Browser.execute(owner, "navigate", %{"tab_id" => tab, "url" => url}))

  defp eval(owner, tab, expression) do
    row = BrowserBindings.get(owner)
    {:ok, pid} = Driver.ensure(row)
    assert {:ok, _} = Driver.request(pid, "tabs", %{})
    state = :sys.get_state(pid).commands

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
end
