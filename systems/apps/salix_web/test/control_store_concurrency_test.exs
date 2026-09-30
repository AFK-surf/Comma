defmodule SalixWeb.ControlStoreConcurrencyTest do
  use ExUnit.Case, async: false

  alias Salix.Control.Store

  @prefix "control-store-concurrency/"

  defmodule BlockingS3 do
    @prefix "control-store-concurrency/"

    def list(@prefix, _opts) do
      objects =
        for index <- 1..10 do
          %{
            key: @prefix <> String.pad_leading(to_string(index), 2, "0"),
            etag: "etag",
            size: 1,
            last_modified: ""
          }
        end

      {:ok, %{objects: objects, next: nil}}
    end

    def list(prefix, opts), do: SalixStore.S3.Fake.list(prefix, opts)

    def get(@prefix <> _ = key, _opts) do
      owner = Application.fetch_env!(:salix_web, :control_store_concurrency_test_pid)
      send(owner, {:get_started, key, self()})

      receive do
        :release ->
          if String.ends_with?(key, "05") do
            {:error, :not_found}
          else
            {:ok, %{body: Jason.encode!(%{"key" => key}), etag: "etag", meta: %{}}}
          end
      end
    end

    def get(key, opts), do: SalixStore.S3.Fake.get(key, opts)
  end

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, BlockingS3)
    Application.put_env(:salix_web, :control_store_concurrency_test_pid, self())

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, previous_backend)
      Application.delete_env(:salix_web, :control_store_concurrency_test_pid)
    end)
  end

  test "list record hydration is ordered, error-tolerant, and bounded to eight reads" do
    reader = Task.async(fn -> Store.list_keyed_records(@prefix) end)

    first_wave = collect_started(8)
    refute_receive {:get_started, _key, _pid}, 50
    Enum.each(first_wave, fn {_key, pid} -> send(pid, :release) end)

    second_wave = collect_started(2)
    Enum.each(second_wave, fn {_key, pid} -> send(pid, :release) end)

    records = Task.await(reader)
    assert Enum.map(records, &elem(&1, 0)) == expected_keys()
  end

  defp collect_started(count) do
    for _ <- 1..count do
      assert_receive {:get_started, key, pid}, 1_000
      {key, pid}
    end
  end

  defp expected_keys do
    for index <- 1..10, index != 5 do
      @prefix <> String.pad_leading(to_string(index), 2, "0")
    end
  end
end
