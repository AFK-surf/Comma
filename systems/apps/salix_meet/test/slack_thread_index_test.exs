defmodule SalixMeet.SlackThreadIndexTest do
  use SystemsClock.Case, async: false

  alias SalixMeet.SlackThreadIndex
  alias SalixStore.S3

  setup do
    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      if previous_s3,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_s3),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)

    owner = %{
      "tenant_id" => "t-index",
      "group_id" => "g-index",
      "connect_id" => "c-index"
    }

    {:ok, owner: owner}
  end

  test "a Slack thread owner is immutable and the same claim is idempotent", %{owner: owner} do
    assert {:ok, %{"meeting_id" => "mtg-owner"}} =
             SlackThreadIndex.claim(owner, "C1", "123.456", "mtg-owner")

    assert {:ok, %{"meeting_id" => "mtg-owner"}} =
             SlackThreadIndex.claim(owner, "C1", "123.456", "mtg-owner")

    assert {:error, {:thread_owned, "mtg-owner"}} =
             SlackThreadIndex.claim(owner, "C1", "123.456", "mtg-other")

    assert {:ok, %{"meeting_id" => "mtg-owner"}} =
             SlackThreadIndex.fetch(owner, "C1", "123.456")
  end

  test "concurrent different claims elect exactly one immutable owner", %{owner: owner} do
    results =
      1..12
      |> Task.async_stream(
        fn index ->
          SlackThreadIndex.claim(owner, "C1", "123.456", "mtg-owner-#{index}")
        end,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, %{"meeting_id" => winner}}] =
             Enum.filter(results, &match?({:ok, _record}, &1))

    assert Enum.all?(results, fn
             {:ok, %{"meeting_id" => ^winner}} -> true
             {:error, {:thread_owned, ^winner}} -> true
             _other -> false
           end)

    assert {:ok, %{"meeting_id" => ^winner}} =
             SlackThreadIndex.fetch(owner, "C1", "123.456")
  end
end
