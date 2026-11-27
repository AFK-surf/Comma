defmodule CommaWeb.NativePushListenerTest do
  # Every Comma Pod runs CommaWeb.NativePushListener, and its wakeups are
  # cluster-wide Comma.Oban jobs. These tests drive the recovery passes of
  # two Pods over the same APNs address, one of them the Comma.Oban leader.
  use SystemsClock.Case, async: false
  require SystemsRuntime.Proc
  import Ecto.Query
  alias Comma.{Accounts, Repo}
  alias Comma.Notifications.Target
  alias CommaWeb.NativePushListener

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    on_exit(fn -> CommaWeb.TestRepoSandbox.stop_owner(owner) end)

    unless Oban.whereis(Comma.Oban),
      do:
        start_supervised!(
          {Oban, name: Comma.Oban, repo: Repo, testing: :manual, queues: false, plugins: false}
        )

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "listener-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    group = "grp_listener_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    Repo.insert!(%Target{
      auth_session_id: session["id"],
      kind: "device",
      token: String.duplicate("a", 64),
      environment: "production",
      bundle_id: "surf.comma.ios",
      workspace_id: "wsp_listener",
      group_id: group,
      expires_at: DateTime.add(SystemsClock.utc_now(), 86_400)
    })

    %{group: group}
  end

  test "the recovery passes of several Pods enqueue one Group's wakeups once, not once per Pod",
       %{group: group} do
    leader = pod(group, true)
    follower = pod(group, false)

    {:noreply, _leader} = NativePushListener.handle_info({:recover, nil}, leader)
    # The wakeups run and finish before the next Pod's pass, as in production.
    finish_wakeups()
    {:noreply, follower} = NativePushListener.handle_info({:recover, nil}, follower)

    assert fanouts(group) == [{"activity", "completed"}, {"router", "completed"}]
    assert follower.groups == %{}
  end

  # A Pod whose listener already holds this Group's subscription relay.
  defp pod(group, leader?) do
    relay =
      SystemsRuntime.Proc.spawn(fn ->
        SystemsRuntime.Proc.receive do
          :stop -> :ok
        end
      end)

    %{groups: %{group => {relay, make_ref()}}, cycle: MapSet.new(), leader?: fn -> leader? end}
  end

  defp finish_wakeups do
    Repo.update_all(from(j in Oban.Job, where: j.state == "available"),
      set: [state: "completed", completed_at: SystemsClock.utc_now()]
    )
  end

  defp fanouts(group) do
    from(j in Oban.Job,
      where: j.worker == "Comma.Workers.NativePushFanout" and j.args["group_id"] == ^group,
      order_by: [j.args["mode"], j.state],
      select: {j.args["mode"], j.state}
    )
    |> Repo.all()
  end
end
