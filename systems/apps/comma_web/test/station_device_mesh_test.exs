defmodule CommaWeb.StationDeviceMeshTest do
  @moduledoc """
  A device's own station asks, with the proof of its key on its Connector run,
  for what it needs to serve its owner on the mesh (`relay_register` with
  `mesh`). It joins no roster. A device whose owner may admit no one is told
  nothing, a station that does not ask is told nothing, and a revocation in the
  Group reaches the run.
  """
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.CommaWeb"]

  import Ecto.Query, only: [from: 2]

  alias Comma.{Accounts, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias SalixEnv.ConnectorTokens
  alias SalixStore.Ids
  alias SalixStore.Stations.{Events, Revocations}

  defmodule Connector do
    @moduledoc "A desktop station's Connector: it tells the test what Salix says and answers it."
    use WebSockex

    def start(token, test_pid, headers \\ []) do
      ws = String.replace(SalixWeb.Application.base_url(), "http://", "ws://")
      query = URI.encode_query(%{"name" => "mac", "os" => "darwin"})

      WebSockex.start(ws <> "/v1/connect?" <> query, __MODULE__, test_pid,
        extra_headers: [{"authorization", "Bearer " <> token} | headers]
      )
    end

    @impl true
    def handle_frame({:text, raw}, test_pid) do
      case Jason.decode!(raw) do
        %{"type" => "connected"} = connected ->
          SystemsRuntime.Proc.send(test_pid, {:connected, connected})
          {:ok, test_pid}

        %{"type" => "heartbeat"} ->
          {:reply, {:text, Jason.encode!(%{"type" => "heartbeat"})}, test_pid}

        %{"type" => "request", "id" => id, "method" => method} = request ->
          SystemsRuntime.Proc.send(test_pid, {:asked, method, request["params"]})
          reply = %{"type" => "response", "id" => id, "result" => %{"ok" => true}}
          {:reply, {:text, Jason.encode!(reply)}, test_pid}

        %{"type" => type, "id" => id} = answer when type in ["response", "error"] ->
          SystemsRuntime.Proc.send(test_pid, {:answer, id, answer})
          {:ok, test_pid}

        _ ->
          {:ok, test_pid}
      end
    end

    @impl true
    def handle_cast({:send, frame}, test_pid),
      do: {:reply, {:text, Jason.encode!(frame)}, test_pid}

    @impl true
    def handle_disconnect(status, test_pid) do
      SystemsRuntime.Proc.send(test_pid, {:gone, status.reason})
      {:ok, test_pid}
    end
  end

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    prior = SystemsRuntime.get_env(:comma_core, :stations)
    prior_salix = SystemsRuntime.get_env(:salix_store, :stations)
    SalixStore.Repo.delete_all(SalixStore.Stations.SigningKeys.Key)
    SystemsRuntime.put_env(:salix_store, :stations, kek: SystemsRuntime.Proc.random_bytes(32))

    SystemsRuntime.put_env(:comma_core, :stations,
      origin: "https://api.comma.test",
      relay_urls: ["https://relay.comma.test"]
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:comma_core, :stations, prior || [])
      SystemsRuntime.put_env(:salix_store, :stations, prior_salix || [])
      CommaWeb.TestRepoSandbox.stop_owner(owner)
    end)

    {:ok, user} = Accounts.create_user(%{"email" => email("owner")})
    {:ok, tenant: nil, workspace: workspace!(user), user: user}
  end

  # In steps, the socket's heartbeats answered meanwhile.
  defp a_minute_passes do
    for _ <- 1..12 do
      SystemsClock.advance(5_000)
      settle()
    end
  end

  defp email(who), do: "#{who}-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"

  defp workspace!(user) do
    {:ok, %{"tenant_id" => tenant}} = Salix.Control.Tenants.create(%{"name" => "Device mesh"})

    {:ok, %{"group_id" => group}} =
      Salix.Control.Groups.create(%{"name" => "Device mesh"}, tenant)

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_device_mesh_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "device-mesh-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "device-mesh-test",
        name: "Device mesh",
        status: "active"
      })

    member!(workspace, user, "owner")
    workspace
  end

  defp member!(workspace, user, role) do
    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: role,
      status: "active"
    })
  end

  # A desktop's Connector for `owner` connects, and proves its key with `extra`.
  defp connect_and_prove(workspace, owner, extra) do
    {:ok, credential} =
      ConnectorTokens.create_group_connector_token(
        workspace.salix_group_id,
        workspace.salix_tenant_id,
        %{"meta" => %{"owner_user_id" => owner}}
      )

    prove(credential["token"], extra)
  end

  # The sandbox of a coding Task that `requester` asked for connects as its Workload, and proves its key with `extra`.
  # It runs and has its Task already, so its run is the Workload's current one.
  defp sandbox_connects_and_proves(workspace, requester, extra, conversation \\ nil) do
    {:ok, workload} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: workspace.salix_tenant_id,
        group_id: workspace.salix_group_id,
        conversation_id: conversation || "screen-" <> SystemsRuntime.Proc.uuid(),
        workspace: "comma:" <> workspace.salix_group_id,
        repo: %{"owner" => "acme", "name" => "api"},
        requester: requester
      })

    {:ok, workload} =
      SalixStore.CodingSandboxes.update(workload.id, fn w ->
        {:ok, Map.merge(w.spec, %{"state" => "ready", "invited" => true})}
      end)

    {:ok, token} =
      SalixStore.Compute.WorkloadCredential.issue_connect(workload.id, workload.generation)

    Process.put(:sandbox_workload, workload.id)
    prove(token, extra, [{"x-salix-credential-kind", "workload"}])
  end

  defp prove(token, extra, headers \\ []) do
    {:ok, pid} = Connector.start(token, SystemsRuntime.Proc.self(), headers)
    Process.put(:device_mesh_connector, pid)

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(pid), do: SystemsRuntime.Proc.exit(pid, :kill)
    end)

    settle_receive({:connected, connected})
    {public, private} = SystemsRuntime.Proc.generate_key(:eddsa, :ed25519)

    message =
      "comma-salix-relay-v1:" <>
        connected["connector_run_id"] <> ":" <> connected["relay_challenge"]

    params =
      Map.merge(
        %{
          "endpoint_id" => Base.encode16(public, case: :lower),
          "signature" =>
            Base.encode64(SystemsRuntime.Proc.sign(:eddsa, :none, message, [private, :ed25519]))
        },
        extra
      )

    WebSockex.cast(
      pid,
      {:send,
       %{"type" => "request", "id" => "prove", "method" => "relay_register", "params" => params}}
    )

    settle_receive({:answer, "prove", answer})
    assert answer["type"] == "response"
    answer["result"]
  end

  test "the owner's device is told the Group's facts when it asks, and joins no roster", ctx do
    assert %{"ok" => true, "mesh" => mesh} =
             connect_and_prove(ctx.workspace, ctx.user["id"], %{"mesh" => true})

    assert mesh["owner"] == ctx.user["id"]
    assert mesh["workspace"] == ctx.workspace.salix_group_id
    assert mesh["relay_urls"] == ["https://relay.comma.test"]
    assert mesh["route_policy"] == "salix-first"
    assert [%{"kty" => "OKP"} | _] = mesh["grant_keys"]["keys"]

    assert SalixStore.Stations.roster(ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id) ==
             []
  end

  test "a station that does not ask, a station from before, is told nothing", ctx do
    assert connect_and_prove(ctx.workspace, ctx.user["id"], %{}) == %{"ok" => true}
  end

  test "a device whose owner is read-only or out of the Group is told nothing, so it admits no one",
       ctx do
    {:ok, viewer} = Accounts.create_user(%{"email" => email("viewer")})
    member!(ctx.workspace, viewer, "viewer")
    assert connect_and_prove(ctx.workspace, viewer["id"], %{"mesh" => true}) == %{"ok" => true}

    {:ok, stranger} = Accounts.create_user(%{"email" => email("stranger")})
    assert connect_and_prove(ctx.workspace, stranger["id"], %{"mesh" => true}) == %{"ok" => true}
  end

  test "a revocation in the Group reaches the run that asked", ctx do
    connect_and_prove(ctx.workspace, ctx.user["id"], %{"mesh" => true})
    scope = {ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id}

    Revocations.revoke([scope], "sub", ctx.user["id"])
    |> Events.publish()

    settle_receive({:asked, "station_mesh", %{"mesh" => mesh}})
    assert [%{"kind" => "sub", "id" => id}] = mesh["revocations"]
    assert id == ctx.user["id"]
  end

  defmodule RevokedWhileRead do
    @moduledoc "The control plane, with a revocation committed just as the first read of the facts is made."
    def device_mesh(tenant, group, owner) do
      told = Comma.Stations.device_mesh(tenant, group, owner)

      if Process.get(:revoked) != true and SystemsRuntime.get_env(:salix_web, :revoke_while_read) do
        Process.put(:revoked, true)

        Revocations.revoke([{tenant, group}], "sub", owner)
        |> Events.publish()
      end

      told
    end
  end

  test "a revocation made while the first facts are read comes after them, numbered later", ctx do
    prior = SystemsRuntime.get_env(:salix_web, :station_control_plane)
    SystemsRuntime.put_env(:salix_web, :station_control_plane, RevokedWhileRead)
    SystemsRuntime.put_env(:salix_web, :revoke_while_read, true)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_web, :station_control_plane, prior)
      SystemsRuntime.delete_env(:salix_web, :revoke_while_read)
    end)

    assert %{"mesh" => first, "mesh_seq" => 0} =
             connect_and_prove(ctx.workspace, ctx.user["id"], %{"mesh" => true})

    assert first["revocations"] == []
    settle_receive({:asked, "station_mesh", %{"seq" => 1, "mesh" => mesh}})
    assert [%{"kind" => "sub"}] = mesh["revocations"]
  end

  test "an owner who lost their role is heard of within a minute, and the numbers go on", ctx do
    {:ok, demoted} = Accounts.create_user(%{"email" => email("demoted")})
    member!(ctx.workspace, demoted, "member")

    assert %{"mesh" => %{"owner" => owner}, "mesh_seq" => 0} =
             connect_and_prove(ctx.workspace, demoted["id"], %{"mesh" => true})

    assert owner == demoted["id"]

    a_minute_passes()
    settle_receive({:asked, "station_mesh", %{"seq" => 1, "mesh" => %{"owner" => _}}})

    Repo.update_all(
      from(m in WorkspaceMembership,
        where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^demoted["id"]
      ),
      set: [role: "viewer"]
    )

    a_minute_passes()
    settle_receive({:asked, "station_mesh", %{"seq" => 2, "mesh" => nil}})
  end

  test "pushes are numbered as their changes are heard", ctx do
    connect_and_prove(ctx.workspace, ctx.user["id"], %{"mesh" => true})
    scope = {ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id}

    Revocations.revoke([scope], "sub", "someone") |> Events.publish()
    settle_receive({:asked, "station_mesh", %{"seq" => 1}})
    Revocations.revoke([scope], "sid", "another") |> Events.publish()
    settle_receive({:asked, "station_mesh", %{"seq" => 2, "mesh" => mesh}})
    assert length(mesh["revocations"]) == 2
  end

  defmodule HeldRead do
    @moduledoc """
    The control plane, counting its reads and telling the test of each. The test says what a read does, by its number:
    held until let go and then what it is given, `:die`, `:raise`, or by default what is there.
    """
    def device_mesh(tenant, group, owner) do
      {test, counter, plan} = SystemsRuntime.get_env(:salix_web, :held_read)
      :counters.add(counter, 1, 1)
      read = :counters.get(counter, 1)
      witness_read(test, read)
      SystemsRuntime.Proc.send(test, {:reading, read, SystemsRuntime.Proc.self()})

      case Map.get(plan, read) do
        :never ->
          SystemsRuntime.Proc.receive do
            :never -> :ok
          end

        {:held, answer} ->
          SystemsRuntime.Proc.receive do
            :go_on -> answer
          end

        :die ->
          SystemsRuntime.Proc.exit(SystemsRuntime.Proc.self(), :kill)

        :raise ->
          raise "the control plane failed"

        nil ->
          Comma.Stations.device_mesh(tenant, group, owner)
      end
    end

    # The read's end is watched before the test hears of the read, and told as `{:read_ended, read, pid, reason}`.
    # A monitor the test set on hearing of it would answer `:noproc` for a read already gone, and say nothing of why.
    defp witness_read(test, read) do
      reader = SystemsRuntime.Proc.self()

      SystemsRuntime.Proc.spawn(fn ->
        watching = SystemsRuntime.Proc.monitor(reader)
        SystemsRuntime.Proc.send(reader, {:witnessing, read})

        SystemsRuntime.Proc.receive do
          {:DOWN, ^watching, :process, ^reader, reason} ->
            SystemsRuntime.Proc.send(test, {:read_ended, read, reader, reason})
        end
      end)

      SystemsRuntime.Proc.receive do
        {:witnessing, ^read} -> :ok
      end
    end
  end

  defp held_reads(plan) do
    prior = SystemsRuntime.get_env(:salix_web, :station_control_plane)
    SystemsRuntime.put_env(:salix_web, :station_control_plane, HeldRead)

    SystemsRuntime.put_env(
      :salix_web,
      :held_read,
      {SystemsRuntime.Proc.self(), :counters.new(1, []), plan}
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_web, :station_control_plane, prior)
      SystemsRuntime.delete_env(:salix_web, :held_read)
    end)
  end

  test "a later deny is not overtaken: one read at a time, so a higher number is read after",
       ctx do
    # The first change's read ends last and finds a deny. As they raced, a later change's grant, read before it, would
    # go out with the higher number and the station would drop the deny.
    held_reads(%{2 => {:held, {:ok, nil}}})
    %{"mesh_seq" => 0} = connect_and_prove(ctx.workspace, ctx.user["id"], %{"mesh" => true})
    settle_receive({:reading, 1, _})
    scope = {ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id}

    Revocations.revoke([scope], "sid", "first") |> Events.publish()
    settle_receive({:reading, 2, held})

    # Heard while it is read: no second read begins, and nothing is said yet.
    Revocations.revoke([scope], "sid", "second") |> Events.publish()
    Revocations.revoke([scope], "sid", "third") |> Events.publish()
    settle()
    refute_received {:reading, 3, _}
    refute_received {:asked, "station_mesh", _}

    SystemsRuntime.Proc.send(held, :go_on)
    settle_receive({:asked, "station_mesh", %{"seq" => 1, "mesh" => nil}})

    # Then one read for all that was heard meanwhile, numbered after, and it finds them all.
    settle_receive({:reading, 3, _})
    settle_receive({:asked, "station_mesh", %{"seq" => 2, "mesh" => mesh}})
    assert length(mesh["revocations"]) == 3
    settle()
    refute_received {:reading, 4, _}
    refute_received {:asked, "station_mesh", _}
  end

  test "a read that fails says no one is admitted, and the numbers go on", ctx do
    held_reads(%{2 => :raise})
    %{"mesh_seq" => 0} = connect_and_prove(ctx.workspace, ctx.user["id"], %{"mesh" => true})
    scope = {ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id}

    Revocations.revoke([scope], "sid", "first") |> Events.publish()
    settle_receive({:asked, "station_mesh", %{"seq" => 1, "mesh" => nil}})

    Revocations.revoke([scope], "sid", "second") |> Events.publish()
    settle_receive({:asked, "station_mesh", %{"seq" => 2, "mesh" => %{"owner" => _}}})
  end

  test "a read that never returns gets a deadline: it says no one is admitted, and later changes get through",
       ctx do
    held_reads(%{2 => :never})
    %{"mesh_seq" => 0} = connect_and_prove(ctx.workspace, ctx.user["id"], %{"mesh" => true})
    settle_receive({:reading, 1, _})
    scope = {ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id}

    Revocations.revoke([scope], "sid", "first") |> Events.publish()
    settle_receive({:reading, 2, stuck})

    # Heard behind it, and nothing moves until the deadline.
    Revocations.revoke([scope], "sid", "second") |> Events.publish()
    settle()
    refute_received {:reading, 3, _}
    refute_received {:asked, "station_mesh", _}

    for _ <- 1..6 do
      SystemsClock.advance(5_000)
      settle()
    end

    settle_receive({:read_ended, 2, ^stuck, reason})
    assert reason == :killed
    settle_receive({:asked, "station_mesh", %{"seq" => 2, "mesh" => nil}})

    # What was heard behind it is read now, numbered after the deny.
    settle_receive({:reading, 3, _})
    settle_receive({:asked, "station_mesh", %{"seq" => 3, "mesh" => mesh}})
    assert length(mesh["revocations"]) == 2

    # And the slot is free for what comes after.
    Revocations.revoke([scope], "sid", "third") |> Events.publish()
    settle_receive({:asked, "station_mesh", %{"seq" => 4, "mesh" => %{"owner" => _}}})
  end

  test "a read under way goes with its socket", ctx do
    held_reads(%{2 => :never})
    %{"mesh_seq" => 0} = connect_and_prove(ctx.workspace, ctx.user["id"], %{"mesh" => true})
    settle_receive({:reading, 1, _})
    scope = {ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id}

    Revocations.revoke([scope], "sid", "first") |> Events.publish()
    settle_receive({:reading, 2, stuck})

    connector = Process.get(:device_mesh_connector)
    SystemsRuntime.Proc.exit(connector, :kill)
    settle_receive({:read_ended, 2, ^stuck, reason})
    assert reason == :killed
  end

  test "a read that dies ends the run, so nothing waits behind it", ctx do
    held_reads(%{2 => :die})
    %{"mesh_seq" => 0} = connect_and_prove(ctx.workspace, ctx.user["id"], %{"mesh" => true})
    settle_receive({:reading, 1, _})
    scope = {ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id}

    Revocations.revoke([scope], "sid", "first") |> Events.publish()
    settle_receive({:reading, 2, _})
    settle_receive({:gone, _})
    refute_received {:asked, "station_mesh", _}
  end

  test "a Task's open streams are told when its sandbox's station says something new of itself, once for each change",
       ctx do
    tenant = ctx.workspace.salix_tenant_id
    group = ctx.workspace.salix_group_id
    assert sandbox_connects_and_proves(ctx.workspace, ctx.user["id"], %{}) == %{"ok" => true}
    settle()
    {:ok, workload} = SalixStore.CodingSandboxes.get(Process.get(:sandbox_workload))
    task = workload.spec["conversation_id"]
    :ok = SalixWeb.CodingSandboxes.subscribe_station(tenant, task, SystemsRuntime.Proc.self())
    connector = Process.get(:device_mesh_connector)

    says = fn capabilities ->
      WebSockex.cast(
        connector,
        {:send, %{"type" => "metadata", "capabilities" => capabilities}}
      )

      settle()
    end

    device = fn ->
      {:ok, device} = SalixEnv.Registry.get_device(tenant, group, workload.spec["device_id"])
      device
    end

    # It serves its display: told once, after it is kept.
    says.(%{"screen_view" => true})
    settle_receive({:coding_sandbox_said, ^task})
    assert SalixWeb.CodingSandboxes.serves_screen?(device.())
    refute SalixWeb.CodingSandboxes.screen_active?(device.())

    # Said again with nothing new of it (its system information): no one is told.
    says.(%{"screen_view" => true, "tasks" => 2})
    refute_received {:coding_sandbox_said, _}

    # A Session's browser opened on the display, then its runtime's process went.
    says.(%{"screen_view" => true, "screen_active" => true})
    settle_receive({:coding_sandbox_said, ^task})
    assert SalixWeb.CodingSandboxes.screen_active?(device.())

    says.(%{"screen_view" => true})
    settle_receive({:coding_sandbox_said, ^task})
    refute SalixWeb.CodingSandboxes.screen_active?(device.())
  end

  test "what a sandbox's station said and Salix did not keep is still new when it says it again",
       ctx do
    tenant = ctx.workspace.salix_tenant_id
    assert sandbox_connects_and_proves(ctx.workspace, ctx.user["id"], %{}) == %{"ok" => true}
    settle()
    {:ok, workload} = SalixStore.CodingSandboxes.get(Process.get(:sandbox_workload))
    task = workload.spec["conversation_id"]
    :ok = SalixWeb.CodingSandboxes.subscribe_station(tenant, task, SystemsRuntime.Proc.self())
    connector = Process.get(:device_mesh_connector)

    says = fn ->
      WebSockex.cast(
        connector,
        {:send, %{"type" => "metadata", "capabilities" => %{"screen_view" => true}}}
      )

      settle()
    end

    # The first write keeps nothing (the run's record is not there); the next is kept.
    writes = :counters.new(1, [])
    previous = SystemsRuntime.get_env(:salix_web, :connector_control_executor)

    SystemsRuntime.put_env(:salix_web, :connector_control_executor, fn
      %{kind: :metadata} ->
        :counters.add(writes, 1, 1)
        if :counters.get(writes, 1) == 1, do: {:error, :not_found}, else: :ok

      _heartbeat ->
        :ok
    end)

    on_exit(fn -> SystemsRuntime.put_env(:salix_web, :connector_control_executor, previous) end)

    says.()
    refute_received {:coding_sandbox_said, _}
    says.()
    settle_receive({:coding_sandbox_said, ^task})
  end

  test "the person whose message the Router made a sandbox Task from may see its screen, though the Task names no owner",
       ctx do
    tenant = ctx.workspace.salix_tenant_id
    group = ctx.workspace.salix_group_id
    owner = ctx.user["id"]

    # The server writes who asked as it makes the Task, where no other create may
    # (`SalixIM.SourceRefProtection`): this test makes it as that server does.
    contracts = SystemsRuntime.get_env(:salix_im, :protected_source_ref_contracts)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_im, :protected_source_ref_contracts, contracts)
    end)

    SystemsRuntime.put_env(:salix_im, :protected_source_ref_contracts, [])

    {:ok, %{"conversation_id" => task}} =
      SalixIM.ConversationServer.create_group_conversation(group, %{
        "kind" => "agent_task",
        "title" => "Look at a page",
        "source_refs" => %{"ifc_requester" => "comma_user|" <> owner}
      })

    SystemsRuntime.put_env(:salix_im, :protected_source_ref_contracts, contracts)

    assert sandbox_connects_and_proves(ctx.workspace, nil, %{}, task) == %{"ok" => true}
    settle()
    {:ok, workload} = SalixStore.CodingSandboxes.get(Process.get(:sandbox_workload))

    {:ok, _} =
      SalixEnv.Registry.update_meta(workload.spec["connector_run_id"], fn meta ->
        Map.put(meta, "capabilities", %{"screen_view" => true})
      end)

    show = &SalixWeb.CodingSandboxes.show_screen(tenant, group, task, &1)
    {:ok, other} = Accounts.create_user(%{"email" => email("other")})
    member!(ctx.workspace, other, "member")
    assert show.(other["id"]) == {:error, :forbidden}
    refute_received {:asked, "station_mesh", _}

    assert show.(owner) == {:ok, workload.spec["device_id"]}
    settle_receive({:asked, "station_mesh", %{"mesh" => %{"owner" => ^owner}}})
  end

  test "a sandbox's station is told whom to show its screen only when the Task's owner asks, and nothing is kept for it",
       ctx do
    tenant = ctx.workspace.salix_tenant_id
    group = ctx.workspace.salix_group_id
    owner = ctx.user["id"]

    # It may ask as a device's station does: a Workload's is told nothing.
    assert sandbox_connects_and_proves(ctx.workspace, owner, %{"mesh" => true}) == %{"ok" => true}
    settle()
    {:ok, workload} = SalixStore.CodingSandboxes.get(Process.get(:sandbox_workload))
    task = workload.spec["conversation_id"]
    show = &SalixWeb.CodingSandboxes.show_screen(tenant, group, task, &1)

    # A station that has not said it serves a screen (an image from before).
    assert show.(owner) == {:error, :sandbox_has_no_screen}

    {:ok, _} =
      SalixEnv.Registry.update_meta(workload.spec["connector_run_id"], fn meta ->
        Map.put(meta, "capabilities", %{"screen_view" => true})
      end)

    # Another member, and an owner who lost the role, are refused, and the station hears nothing.
    {:ok, other} = Accounts.create_user(%{"email" => email("other")})
    member!(ctx.workspace, other, "member")
    assert show.(other["id"]) == {:error, :forbidden}
    refute_received {:asked, "station_mesh", _}

    assert show.(owner) == {:ok, workload.spec["device_id"]}
    settle_receive({:asked, "station_mesh", %{"seq" => seq, "mesh" => mesh}})
    assert mesh["owner"] == owner
    assert mesh["workspace"] == group
    assert [%{"kty" => "OKP"} | _] = mesh["grant_keys"]["keys"]
    assert seq > 0

    # No check follows: the station hears again only when the owner asks again.
    a_minute_passes()
    settle()
    refute_received {:asked, "station_mesh", _}

    Repo.update_all(
      from(m in WorkspaceMembership,
        where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^owner
      ),
      set: [role: "viewer"]
    )

    assert show.(owner) == {:error, :forbidden}
    refute_received {:asked, "station_mesh", _}
  end

  test "a revocation does not reach a run that did not ask", ctx do
    connect_and_prove(ctx.workspace, ctx.user["id"], %{})
    scope = {ctx.workspace.salix_tenant_id, ctx.workspace.salix_group_id}

    Revocations.revoke([scope], "sub", ctx.user["id"])
    |> Events.publish()

    settle()
    refute_received {:asked, "station_mesh", _}
  end
end
