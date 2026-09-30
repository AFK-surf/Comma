defmodule Salix.Control.IntegrationMaterializationLifecycleTest do
  use ExUnit.Case, async: false

  alias Salix.Control.IntegrationMaterializationLifecycle

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case start_supervised(SalixStore.S3.Fake) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous_backend) end)
  end

  test "a same-body follower replays only after the creator commits" do
    test_process = self()
    identity = %{"kind" => "managed_oauth", "provider" => "github", "alias" => "github"}

    creator =
      Task.async(fn ->
        IntegrationMaterializationLifecycle.run(
          "tenant",
          "group",
          identity,
          "github",
          fn ->
            send(test_process, :creator_entered)
            receive do: (:release_creator -> {:ok, %{"materialization_id" => "one"}})
          end
        )
      end)

    assert_receive :creator_entered

    follower =
      Task.async(fn ->
        IntegrationMaterializationLifecycle.run(
          "tenant",
          "group",
          identity,
          "github",
          fn ->
            send(test_process, :follower_executed)
            {:ok, %{"materialization_id" => "two"}}
          end
        )
      end)

    refute_receive :follower_executed, 150
    send(creator.pid, :release_creator)

    assert Task.await(creator) == {:ok, %{"materialization_id" => "one"}}
    assert Task.await(follower) == {:ok, %{"materialization_id" => "one"}}
    refute_receive :follower_executed
  end

  test "a failed creator cannot make its follower consume pending state" do
    test_process = self()
    identity = %{"kind" => "managed_oauth", "provider" => "github", "alias" => "github"}

    creator =
      Task.async(fn ->
        IntegrationMaterializationLifecycle.run(
          "tenant",
          "group",
          identity,
          "github",
          fn ->
            send(test_process, :creator_entered)
            receive do: (:fail_creator -> {:error, :provider_failed})
          end
        )
      end)

    assert_receive :creator_entered

    follower =
      Task.async(fn ->
        IntegrationMaterializationLifecycle.run(
          "tenant",
          "group",
          identity,
          "github",
          fn -> {:ok, %{"materialization_id" => "recovered"}} end
        )
      end)

    send(creator.pid, :fail_creator)
    assert Task.await(creator) == {:error, :provider_failed}
    assert Task.await(follower) == {:ok, %{"materialization_id" => "recovered"}}
  end
end
