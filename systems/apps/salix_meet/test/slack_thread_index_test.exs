defmodule SalixMeet.SlackThreadIndexTest do
  use ExUnit.Case, async: false

  alias SalixMeet.SlackThreadIndex
  alias SalixStore.S3

  setup do
    previous_s3 = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      if previous_s3,
        do: Application.put_env(:salix_store, :s3_backend, previous_s3),
        else: Application.delete_env(:salix_store, :s3_backend)
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

  test "malformed and scope-mismatched durable owners fail closed", %{owner: owner} do
    assert {:ok, record} = SlackThreadIndex.claim(owner, "C1", "123.456", "mtg-owner")
    key = only_index_key(owner)

    assert {:ok, _etag} = S3.put(key, "not-json")

    assert {:error, :invalid_slack_thread_index} =
             SlackThreadIndex.fetch(owner, "C1", "123.456")

    mismatched = Map.put(record, "connect_id", "c-other")
    assert {:ok, _etag} = S3.put(key, Jason.encode!(mismatched))

    assert {:error, :invalid_slack_thread_index} =
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

  test "ambiguous and late-precondition writes reconcile to the durable owner", %{owner: owner} do
    assert :ok =
             SalixStore.S3.Fake.set_fault({:ambiguous_after, :put, :any})

    assert {:ok, %{"meeting_id" => "mtg-ambiguous"}} =
             SlackThreadIndex.claim(owner, "C1", "123.456", "mtg-ambiguous")

    assert :ok =
             SalixStore.S3.Fake.set_fault({:precondition_after, :put, :any})

    assert {:ok, %{"meeting_id" => "mtg-precondition"}} =
             SlackThreadIndex.claim(owner, "C1", "789.000", "mtg-precondition")

    assert {:ok, %{"meeting_id" => "mtg-ambiguous"}} =
             SlackThreadIndex.fetch(owner, "C1", "123.456")

    assert {:ok, %{"meeting_id" => "mtg-precondition"}} =
             SlackThreadIndex.fetch(owner, "C1", "789.000")
  end

  defp only_index_key(owner) do
    assert {:ok, [%{key: key}]} =
             S3.list_all("meet/sources/slack/#{owner["group_id"]}/")

    key
  end
end
