defmodule SalixAgent.BrowserLiveTest do
  use ExUnit.Case, async: false
  require Ecto.Query
  alias SalixStore.{BrowserSettings, BrowserBindings, Ids, Repo}
  alias SalixAgent.Browser
  @moduletag :browser_live
  @moduletag timeout: 120_000
  test "real provider through stored settings, tool entry, serialized control and driver frames" do
    unless Process.whereis(SalixAgent.Browser.Supervisor),
      do:
        start_supervised!(
          {DynamicSupervisor, name: SalixAgent.Browser.Supervisor, strategy: :one_for_one}
        )

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    ctx = %{agent_id: Ids.new_agent_id(group), session_id: "browser-live-test"}
    owner = Browser.owner(ctx)
    old = Application.get_env(:salix_store, :compute_workload_credential_secret)

    Application.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("live-test-only", 4)
    )

    token = System.fetch_env!("CF_BROWSER_TOKEN_FILE") |> File.read!() |> String.trim()
    account = System.fetch_env!("CF_BROWSER_ACCOUNT_ID")

    on_exit(fn ->
      Browser.execute(owner, "close", %{})
      Repo.delete_all(BrowserBindings.query(owner))
      Repo.delete_all(Ecto.Query.from(r in BrowserSettings.Row, where: r.scope == ^tenant))

      if old,
        do: Application.put_env(:salix_store, :compute_workload_credential_secret, old),
        else: Application.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    assert {:ok, :ok} =
             BrowserSettings.put(tenant, %{
               "mode" => "override",
               "account_id" => account,
               "api_token" => token,
               "allowed_domains" => ["example.com"]
             })

    opened = SalixAgent.Tools.Browser.call("open", %{}, ctx) |> Jason.decode!()
    assert is_list(opened["tabs"]), "open failed: #{inspect(Map.take(opened, ["error"]))}"
    assert [%{"tab_id" => tab} | _] = opened["tabs"]
    refute Jason.encode!(opened) =~ token

    assert {:ok, _} =
             Browser.execute(owner, "navigate", %{"tab_id" => tab, "url" => "https://example.com"})

    row = BrowserBindings.get(owner)
    assert {:ok, pid} = SalixAgent.Browser.Driver.ensure(row)

    assert {:ok, _} =
             SalixAgent.Browser.Driver.request(pid, "stream_start", %{
               "tab_id" => tab,
               "viewer_id" => "live-test"
             })

    frame =
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case SalixAgent.Browser.Driver.frame(pid, tab) do
          {:ok, %{"data" => data} = frame} when byte_size(data) > 100 ->
            {:halt, frame}

          _ ->
            Process.sleep(100)
            {:cont, nil}
        end
      end)

    assert is_map(frame)
    assert {:ok, snapshot} = Browser.execute(owner, "snapshot", %{"tab_id" => tab})
    assert URI.parse(snapshot["url"]).host == "example.com"

    # Set a form through the private CDP seam. Agents cannot evaluate arbitrary scripts.
    state = :sys.get_state(pid).commands

    html =
      "<input aria-label='Name'><button onclick=\"document.querySelector('output').textContent=document.querySelector('input').value\">Save</button><output></output>"

    assert {:ok, _} =
             SalixAgent.Browser.Connection.command(
               state.conn,
               "Runtime.evaluate",
               %{
                 expression:
                   "document.open();document.write(#{Jason.encode!(html)});document.close();"
               },
               state.tabs[tab]
             )

    assert {:ok, _} =
             SalixAgent.Browser.Connection.command(
               state.conn,
               "Runtime.evaluate",
               %{
                 expression:
                   "document.body.insertAdjacentHTML('beforeend', #{Jason.encode!("<input type='number' aria-label='Count' value='123' oninput=\"document.getElementById('number-state').textContent=this.value\"><output id='number-state'>123</output><button>Save   <b>changes</b></button>")})"
               },
               state.tabs[tab]
             )

    assert {:ok, form} = Browser.execute(owner, "snapshot", %{"tab_id" => tab})
    input = Enum.find(form["elements"], &(&1["name"] == "Name"))["ref"]
    button = Enum.find(form["elements"], &(&1["name"] == "Save"))["ref"]

    count = Enum.find(form["elements"], &(&1["name"] == "Count"))["ref"]

    assert {:ok, _} =
             Browser.execute(owner, "fill", %{"tab_id" => tab, "ref" => count, "text" => ""})

    assert {:ok, %{"result" => %{"value" => ["", ""]}}} =
             SalixAgent.Browser.Connection.command(
               state.conn,
               "Runtime.evaluate",
               %{
                 expression:
                   "[document.querySelector('[type=number]').value, document.getElementById('number-state').textContent]",
                 returnByValue: true
               },
               state.tabs[tab]
             )

    assert {:ok, _} =
             Browser.execute(owner, "wait", %{
               "tab_id" => tab,
               "text" => "Save changes",
               "timeout_ms" => 500
             })

    assert {:ok, _} =
             Browser.execute(owner, "fill", %{
               "tab_id" => tab,
               "ref" => input,
               "text" => "agent text"
             })

    assert {:ok, _} = Browser.execute(owner, "click", %{"tab_id" => tab, "ref" => button})
    assert {:ok, _} = Browser.execute(owner, "wait", %{"tab_id" => tab, "text" => "agent text"})
    assert {:ok, %{"data" => jpeg}} = Browser.execute(owner, "screenshot", %{"tab_id" => tab})
    assert <<255, 216, _::binary>> = Base.decode64!(jpeg)
    assert {:ok, _} = Browser.execute(owner, "click", %{"tab_id" => tab, "ref" => input})
    assert {:ok, _} = Browser.execute(owner, "press", %{"tab_id" => tab, "key" => "Control+a"})
    assert {:ok, _} = Browser.execute(owner, "take_control", %{}, "viewer")

    assert {:error, :browser_human_control} =
             Browser.execute(owner, "click", %{"tab_id" => tab, "x" => 10, "y" => 10})

    assert {:ok, _} =
             Browser.execute(
               owner,
               "input",
               %{"tab_id" => tab, "input" => %{"type" => "text", "text" => "中文"}},
               "viewer"
             )

    for type <- ~w(keyDown keyUp) do
      assert {:ok, _} =
               Browser.execute(
                 owner,
                 "input",
                 %{
                   "tab_id" => tab,
                   "input" => %{"type" => type, "key" => "Tab", "code" => "Tab", "keyCode" => 9}
                 },
                 "viewer"
               )
    end

    assert {:ok, _} = Browser.execute(owner, "return_control", %{"tab_id" => tab}, "viewer")
    assert {:ok, _} = Browser.execute(owner, "press", %{"tab_id" => tab, "key" => "Enter"})
    assert {:ok, _} = Browser.execute(owner, "wait", %{"tab_id" => tab, "text" => "中文"})
    assert {:ok, observed} = Browser.execute(owner, "snapshot", %{"tab_id" => tab})
    old_ref = Enum.find(observed["elements"], &(&1["name"] == "Save"))["ref"]
    :ok = SalixAgent.Browser.Driver.stop(row)
    assert {:ok, _} = Browser.execute(owner, "tabs", %{})
    assert {:ok, _} = Browser.execute(owner, "snapshot", %{"tab_id" => tab})

    assert {:error, "stale_element"} =
             Browser.execute(owner, "click", %{"tab_id" => tab, "ref" => old_ref})

    assert {:ok, _} = Browser.execute(owner, "close", %{})
  end

  test "real Cloudflare replacement restores Group cookies and local storage across tasks" do
    unless Process.whereis(SalixAgent.Browser.Supervisor),
      do:
        start_supervised!(
          {DynamicSupervisor, name: SalixAgent.Browser.Supervisor, strategy: :one_for_one}
        )

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    first = Browser.owner(%{agent_id: Ids.new_agent_id(group), session_id: "storage-first"})
    second = Browser.owner(%{agent_id: Ids.new_agent_id(group), session_id: "storage-second"})
    old = Application.get_env(:salix_store, :compute_workload_credential_secret)

    Application.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("live-storage-test", 4)
    )

    on_exit(fn ->
      for owner <- [first, second] do
        case BrowserBindings.get(owner) do
          %{provider_id: id, status: status} when is_binary(id) and status != "closed" ->
            assert {:ok, _} = Browser.execute(owner, "close", %{})

          _ ->
            :ok
        end

        Repo.delete_all(BrowserBindings.query(owner), log: false)
      end

      Repo.delete_all(SalixStore.BrowserStorage.query(first), log: false)

      Repo.delete_all(Ecto.Query.from(r in BrowserSettings.Row, where: r.scope == ^tenant),
        log: false
      )

      if old,
        do: Application.put_env(:salix_store, :compute_workload_credential_secret, old),
        else: Application.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    token = System.fetch_env!("CF_BROWSER_TOKEN_FILE") |> File.read!() |> String.trim()

    assert {:ok, :ok} =
             BrowserSettings.put(tenant, %{
               "mode" => "override",
               "account_id" => System.fetch_env!("CF_BROWSER_ACCOUNT_ID"),
               "api_token" => token,
               "allowed_domains" => ["example.com"],
               "operation_timeout_ms" => 30000
             })

    assert {:ok, %{"tabs" => [%{"tab_id" => tab} | _]}} = Browser.execute(first, "open", %{})

    assert {:ok, _} =
             Browser.execute(first, "navigate", %{"tab_id" => tab, "url" => "https://example.com"})

    state = live_commands(first)

    assert {:ok, _} =
             SalixAgent.Browser.Connection.command(
               state.conn,
               "Runtime.evaluate",
               %{
                 expression: "localStorage.setItem('comma-storage-test','shared');",
                 returnByValue: true
               },
               state.tabs[tab]
             )

    assert {:ok, _} =
             SalixAgent.Browser.Connection.command(state.conn, "Storage.setCookies", %{
               cookies: [
                 %{
                   name: "comma-storage-test",
                   value: "shared",
                   domain: "example.com",
                   path: "/",
                   secure: true,
                   httpOnly: true,
                   sameSite: "Lax"
                 }
               ]
             })

    holder = BrowserBindings.get(first)
    assert {:ok, :active} = Browser.provider().status(holder, token)
    assert {:ok, %{storage_error: nil}} = Browser.checkpoint(first)
    assert {:ok, _} = Browser.execute(first, "request_control", %{})

    Repo.update_all(BrowserBindings.query(first),
      set: [updated_at: DateTime.add(DateTime.utc_now(), -901)]
    )

    assert {:ok, _} = Browser.execute(first, "open", %{})
    assert BrowserBindings.get(first).provider_id == holder.provider_id
    assert {:error, :browser_shared_profile_in_use} = Browser.execute(second, "open", %{})
    {:ok, driver} = SalixAgent.Browser.Driver.observe(holder)
    monitor = Process.monitor(driver)

    :sys.replace_state(driver, fn state ->
      Process.cancel_timer(state.idle)

      %{
        state
        | last_activity: System.monotonic_time(:millisecond) - 600_001,
          idle: Process.send_after(driver, :idle, 2000)
      }
    end)

    assert {:ok, _} = SalixAgent.Browser.Driver.call(holder, "stream_start", %{"tab_id" => tab})
    assert {:ok, _} = SalixAgent.Browser.Driver.frame(driver, tab)
    assert_receive {:DOWN, ^monitor, :process, ^driver, :normal}, 5000
    assert {:error, :browser_driver_unavailable} = SalixAgent.Browser.Driver.observe(holder)

    assert {:error, :browser_driver_unavailable} =
             SalixAgent.Browser.Driver.call(holder, "storage_export")

    # The provider ends the session while the SQL binding still owns it.
    assert {:ok, _} = Browser.provider().close(holder, token)
    assert {:ok, :expired} = Browser.provider().status(holder, token)
    assert {:ok, _} = Browser.execute(first, "open", %{})
    replacement = BrowserBindings.get(first)
    assert replacement.provider_id != holder.provider_id
    restored = live_commands(first)

    assert {:ok, %{"cookies" => restored_cookies}} =
             SalixAgent.Browser.Connection.command(restored.conn, "Storage.getCookies")

    assert Enum.any?(
             restored_cookies,
             &(&1["name"] == "comma-storage-test" && &1["value"] == "shared")
           )

    assert {:ok, _} = Browser.provider().close(replacement, token)
    assert {:ok, %{"tabs" => [%{"tab_id" => tab} | _]}} = Browser.execute(second, "open", %{})

    assert {:ok, _} =
             Browser.execute(second, "navigate", %{
               "tab_id" => tab,
               "url" => "https://example.com"
             })

    state = live_commands(second)

    assert {:ok, %{"result" => %{"value" => "shared"}}} =
             SalixAgent.Browser.Connection.command(
               state.conn,
               "Runtime.evaluate",
               %{expression: "localStorage.getItem('comma-storage-test')", returnByValue: true},
               state.tabs[tab]
             )

    assert {:ok, %{"cookies" => cookies}} =
             SalixAgent.Browser.Connection.command(state.conn, "Storage.getCookies")

    assert Enum.any?(
             cookies,
             &(&1["name"] == "comma-storage-test" && &1["value"] == "shared" && &1["httpOnly"])
           )

    assert {:ok, %{status: "closed"}} =
             Browser.execute(second, "clear_storage", %{}, "test-human")

    assert {:ok, %{"cookies" => [], "origins" => %{}}} = SalixStore.BrowserStorage.load(first)
  end

  defp live_commands(owner) do
    {:ok, pid} = SalixAgent.Browser.Driver.ensure(BrowserBindings.get(owner))
    :sys.get_state(pid).commands
  end
end
