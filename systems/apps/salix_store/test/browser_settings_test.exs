defmodule SalixStore.BrowserSettingsTest do
  use SystemsClock.Case, async: false
  alias SalixStore.{BrowserSettings, BrowserBindings, BrowserStorage, Repo}

  setup do
    Repo.query!("TRUNCATE browser_bindings, browser_settings, group_browser_storage")
    old = SystemsRuntime.get_env(:salix_store, :compute_workload_credential_secret)

    SystemsRuntime.put_env(
      :salix_store,
      :compute_workload_credential_secret,
      String.duplicate("test", 16)
    )

    on_exit(fn ->
      if old,
        do: SystemsRuntime.put_env(:salix_store, :compute_workload_credential_secret, old),
        else: SystemsRuntime.delete_env(:salix_store, :compute_workload_credential_secret)
    end)

    :ok
  end

  defp configure(scope, token \\ "secret-token"),
    do:
      BrowserSettings.put(scope, %{
        "mode" => "override",
        "account_id" => String.duplicate("a", 32),
        "api_token" => token
      })

  defp save(row, snapshot), do: BrowserStorage.save(row, snapshot, BrowserStorage.saved_at(row))

  test "inheritance, explicit disable, and invalid override never mix credential scopes" do
    assert {:ok, :ok} = configure(BrowserSettings.default_scope())
    assert {:ok, global} = BrowserSettings.resolve("tenant")
    assert global.scope == BrowserSettings.default_scope()
    assert {:ok, :ok} = BrowserSettings.put("tenant", %{"mode" => "disabled"})
    assert {:error, :browser_disabled} = BrowserSettings.resolve("tenant")

    assert {:error, :browser_token_required} =
             BrowserSettings.put("tenant", %{
               "mode" => "override",
               "account_id" => String.duplicate("b", 32)
             })

    assert {:error, :browser_disabled} = BrowserSettings.resolve("tenant")
    assert {:ok, :ok} = configure("tenant", "tenant-token")
    assert {:ok, tenant} = BrowserSettings.resolve("tenant")
    assert {:ok, "tenant-token"} = BrowserSettings.unseal(tenant.token_ciphertext, "tenant")
    assert {:error, _} = BrowserSettings.unseal(tenant.token_ciphertext, "another-tenant")
    refute inspect(BrowserSettings.view("tenant")) =~ "tenant-token"
    refute tenant.token_ciphertext =~ "tenant-token"
    assert {:ok, :ok} = BrowserSettings.put("tenant", %{"mode" => "inherit"})
    assert {:ok, ^global} = BrowserSettings.resolve("tenant")
  end

  test "pending mutation survives caller loss, rejects foreign scope, and cannot overwrite explicit close" do
    configure("tenant")
    {:ok, settings} = BrowserSettings.resolve("tenant")
    owner = %{agent_id: "agent", session_id: "session", tenant_id: "tenant", group_id: "group"}
    {:ok, row} = BrowserBindings.reserve(owner, settings)
    {:ok, _} = BrowserBindings.finish(row, %{status: "ready", provider_id: "provider"})

    assert {:error, :browser_not_found} =
             BrowserBindings.claim(%{owner | tenant_id: "foreign"}, :agent, "click")

    assert {:ok, pending} = BrowserBindings.claim(owner, :agent, "click")

    assert {:error, :browser_outcome_pending} =
             BrowserBindings.claim(owner, "viewer", "take_control")

    assert {:ok, closing} = BrowserBindings.claim(owner, :agent, "close")
    assert {:error, :browser_operation_superseded} = BrowserBindings.finish(pending, %{})
    assert {:ok, %{status: "closed"}} = BrowserBindings.finish(closing, %{status: "closed"})
  end

  test "Group admission is exclusive across Workers; stale saves and cross-Group ciphertext cannot restore credentials" do
    configure("tenant")
    {:ok, settings} = BrowserSettings.resolve("tenant")
    owner = %{agent_id: "first", session_id: "one", tenant_id: "tenant", group_id: "group"}
    other = %{owner | agent_id: "second", session_id: "two"}

    results =
      [owner, other]
      |> SystemsClock.async_stream(&BrowserBindings.reserve(&1, settings), ordered: false)
      |> Enum.map(fn {:ok, value} -> value end)

    assert [{:ok, row}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert {:error, :browser_shared_profile_in_use} in results
    assert {:ok, ready} = BrowserBindings.finish(row, %{status: "ready", provider_id: "provider"})
    assert {:ok, pending} = BrowserBindings.claim(ready, :agent, "snapshot")
    snapshot = %{"cookies" => [%{"name" => "login", "value" => "private"}], "origins" => %{}}
    assert {:ok, :saved} = save(pending, snapshot)
    assert {:ok, loaded} = BrowserStorage.load(other)
    assert Map.take(loaded, ["cookies", "origins"]) == snapshot

    assert {:ok, close} = BrowserBindings.claim(ready, :agent, "close")

    assert {:error, :browser_operation_superseded} =
             save(pending, BrowserStorage.empty())

    assert {:ok, _} = BrowserBindings.finish(close, %{status: "closed", clear_storage: true})
    assert {:error, :browser_operation_superseded} = save(pending, snapshot)
    assert {:ok, %{"cookies" => []}} = BrowserStorage.load(other)

    assert {:ok, row} = BrowserBindings.reserve(other, settings)

    assert {:ok, row} =
             BrowserBindings.finish(row, %{status: "ready", provider_id: "next-provider"})

    assert {:ok, row} = BrowserBindings.claim(row, :agent, "snapshot")
    assert {:ok, :saved} = save(row, snapshot)
    stored = Repo.one(BrowserStorage.query(other))
    foreign = %{other | group_id: "foreign"}

    Repo.insert!(%BrowserStorage.Row{
      tenant_id: "tenant",
      group_id: "foreign",
      ciphertext: stored.ciphertext
    })

    assert {:error, :browser_storage_unavailable} = BrowserStorage.load(foreign)

    assert {:error, :browser_shared_profile_in_use} =
             BrowserStorage.delete_group("tenant", "group")

    assert {:ok, _} = BrowserBindings.finish(row, %{status: "closed"})

    assert {:error, :remote_cleanup_failed} =
             BrowserStorage.delete_group("tenant", "group", fn ->
               {:error, :remote_cleanup_failed}
             end)

    assert {:ok, loaded} = BrowserStorage.load(other)
    assert loaded["cookies"] == snapshot["cookies"]
    assert {:ok, :ok} = BrowserStorage.clear_idle(other)
    assert {:ok, %{"cookies" => [], "origins" => %{}}} = BrowserStorage.load(other)
    assert :ok = BrowserStorage.delete_group("tenant", "group")
    assert {:error, :browser_group_deleted} = BrowserBindings.reserve(owner, settings)
  end

  test "a background snapshot cannot overwrite newer commands, cookie deletion, or a cleared Group" do
    configure("tenant")
    {:ok, settings} = BrowserSettings.resolve("tenant")
    owner = %{agent_id: "agent", session_id: "background", tenant_id: "tenant", group_id: "group"}
    {:ok, row} = BrowserBindings.reserve(owner, settings)
    {:ok, old} = BrowserBindings.finish(row, %{status: "ready", provider_id: "provider"})
    {:ok, command} = BrowserBindings.claim(owner, :agent, "click")
    assert {:error, :browser_operation_superseded} = BrowserBindings.expire(old)
    {:ok, current} = BrowserBindings.finish(command, %{})

    assert {:error, :browser_operation_superseded} =
             save(old, BrowserStorage.empty())

    assert {:ok, :saved} =
             save(current, %{
               "cookies" => [%{"name" => "login", "value" => "secret"}],
               "origins" => %{
                 "https://one.test" => [["a", "b"]],
                 "https://two.test" => [["c", "d"]]
               }
             })

    assert {:ok, :saved} =
             save(current, %{
               "cookies" => [],
               "origins" => %{"https://one.test" => []}
             })

    assert {:ok, saved} = BrowserStorage.load(owner)
    assert saved["cookies"] == []
    assert saved["origins"] == %{"https://two.test" => [["c", "d"]]}
    before_save = BrowserStorage.saved_at(owner)
    assert {:ok, :saved} = save(current, BrowserStorage.empty())

    assert {:error, :browser_operation_superseded} =
             BrowserStorage.save(current, saved, before_save)

    assert {:error, :browser_shared_profile_in_use} = BrowserStorage.clear_idle(owner)
    {:ok, closing} = BrowserBindings.claim(owner, :agent, "close")
    {:ok, _} = BrowserBindings.finish(closing, %{status: "closed"})
    assert {:ok, :ok} = BrowserStorage.clear_idle(owner)
    assert {:error, :browser_operation_superseded} = save(current, saved)
  end

  test "human control excludes agent actions and other viewers until grant expiry" do
    configure("tenant")
    {:ok, settings} = BrowserSettings.resolve("tenant")
    owner = %{agent_id: "agent", session_id: "session", tenant_id: "tenant", group_id: "group"}
    {:ok, row} = BrowserBindings.reserve(owner, settings)
    {:ok, _} = BrowserBindings.finish(row, %{status: "ready", provider_id: "provider"})
    {:ok, row} = BrowserBindings.claim(owner, "viewer", "take_control")

    {:ok, _} =
      BrowserBindings.finish(row, %{
        control: "human",
        controller: "viewer",
        controller_expires_at: DateTime.add(SystemsClock.utc_now(), 10)
      })

    assert {:error, :browser_human_control} = BrowserBindings.claim(owner, :agent, "click")

    assert {:error, :browser_control_conflict} =
             BrowserBindings.claim(owner, "other", "take_control")

    assert {:error, :browser_control_required} = BrowserBindings.claim(owner, "other", "input")
    BrowserBindings.release(owner, "viewer")
    assert {:error, :browser_human_control} = BrowserBindings.claim(owner, :agent, "click")
    assert {:error, :browser_control_required} = BrowserBindings.claim(owner, "viewer", "input")
    assert {:ok, _} = BrowserBindings.claim(owner, "other", "take_control")
  end
end
