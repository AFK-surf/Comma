defmodule Salix.Control.IntegrationMaterializationLifecycleTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

  alias Salix.Control.IntegrationMaterializationLifecycle

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case start_supervised(SalixStore.S3.Fake) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend) end)
  end

  test "a same-body follower replays only after the creator commits" do
    test_process = SystemsRuntime.Proc.self()
    identity = %{"kind" => "managed_oauth", "provider" => "github", "alias" => "github"}

    creator =
      SystemsRuntime.Task.async(fn ->
        IntegrationMaterializationLifecycle.run(
          "tenant",
          "group",
          identity,
          "github",
          fn ->
            SystemsRuntime.Proc.send(test_process, :creator_entered)

            SystemsRuntime.Proc.receive(
              do: (:release_creator -> {:ok, %{"materialization_id" => "one"}})
            )
          end
        )
      end)

    settle_receive(:creator_entered)

    follower =
      SystemsRuntime.Task.async(fn ->
        IntegrationMaterializationLifecycle.run(
          "tenant",
          "group",
          identity,
          "github",
          fn ->
            SystemsRuntime.Proc.send(test_process, :follower_executed)
            {:ok, %{"materialization_id" => "two"}}
          end
        )
      end)

    settle_refute_receive(:follower_executed, 150)
    SystemsRuntime.Proc.send(creator.pid, :release_creator)

    assert settled_await(creator) == {:ok, %{"materialization_id" => "one"}}
    assert settled_await(follower) == {:ok, %{"materialization_id" => "one"}}
    settle_refute_receive(:follower_executed)
  end

  test "a failed creator cannot make its follower consume pending state" do
    test_process = SystemsRuntime.Proc.self()
    identity = %{"kind" => "managed_oauth", "provider" => "github", "alias" => "github"}

    creator =
      SystemsRuntime.Task.async(fn ->
        IntegrationMaterializationLifecycle.run(
          "tenant",
          "group",
          identity,
          "github",
          fn ->
            SystemsRuntime.Proc.send(test_process, :creator_entered)
            SystemsRuntime.Proc.receive(do: (:fail_creator -> {:error, :provider_failed}))
          end
        )
      end)

    settle_receive(:creator_entered)

    follower =
      SystemsRuntime.Task.async(fn ->
        IntegrationMaterializationLifecycle.run(
          "tenant",
          "group",
          identity,
          "github",
          fn -> {:ok, %{"materialization_id" => "recovered"}} end
        )
      end)

    SystemsRuntime.Proc.send(creator.pid, :fail_creator)
    assert settled_await(creator) == {:error, :provider_failed}
    assert settled_await(follower) == {:ok, %{"materialization_id" => "recovered"}}
  end
end
