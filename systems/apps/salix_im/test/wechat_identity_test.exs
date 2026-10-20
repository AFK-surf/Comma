defmodule SalixIM.WeChatIdentityTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle
  alias SalixIM.ProviderIdentity
  alias SalixStore.{CasRecord, Keys}
  alias SalixStore.S3.Fake

  setup do
    if SystemsRuntime.Proc.whereis(Fake), do: Fake.reset(), else: start_supervised!(Fake)
    :ok
  end

  test "an old delayed release cannot erase the replacement bot owner" do
    key = Keys.ctl_im_provider_identity("wechat", "bot")
    assert :ok = ProviderIdentity.reserve({"wechat", "bot"}, "tenant", "group", "old")

    delayed =
      SystemsRuntime.Task.async(fn ->
        SystemsRuntime.Proc.receive do
          :release -> ProviderIdentity.release_provider("wechat", "bot", "old")
        end
      end)

    on_exit(fn ->
      if SystemsRuntime.Proc.alive?(delayed.pid), do: SystemsRuntime.Proc.exit(delayed.pid, :kill)
    end)

    Fake.set_fault_for(delayed.pid, {:pause, :get, key})
    SystemsRuntime.Proc.send(delayed.pid, :release)
    assert wait_paused(100)
    assert :ok = ProviderIdentity.release_provider("wechat", "bot", "old")
    assert :ok = ProviderIdentity.reserve({"wechat", "bot"}, "tenant", "group", "new")
    assert :ok = Fake.release_pause()
    assert :ok = settled_await(delayed)
    assert {:ok, %{"connect_id" => "new"} = record} = CasRecord.get(key)
    refute record["released_at"]
    assert {:error, _} = ProviderIdentity.reserve({"wechat", "bot"}, "other", "other", "third")
  end

  defp wait_paused(0), do: false

  defp wait_paused(attempts) do
    if Fake.paused?() do
      true
    else
      SystemsClock.sleep(10)
      wait_paused(attempts - 1)
    end
  end
end
