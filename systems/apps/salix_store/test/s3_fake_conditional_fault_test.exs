defmodule SalixStore.S3FakeConditionalFaultTest do
  use ExUnit.Case, async: false

  alias SalixStore.S3
  alias SalixStore.S3.Fake

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, Fake)

    if Process.whereis(Fake) do
      Fake.reset()
    else
      start_supervised!(Fake)
    end

    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)
    :ok
  end

  test "ambiguous_after on an if-match put lands exactly one conditional update" do
    key = key("ambiguous-after-cas")

    assert {:ok, %{etag: e0}} = S3.put(key, "v0")

    :ok = Fake.set_fault({:ambiguous_after, :put, key})

    assert {:error, {:ambiguous, :injected}} = S3.put(key, "v1", if_match: e0)
    assert {:ok, %{body: "v1", etag: e1}} = S3.get(key)
    refute e1 == e0

    assert {:error, :precondition_failed} = S3.put(key, "v2", if_match: e0)
    assert {:ok, %{body: "v1"}} = S3.get(key)
  end

  test "ambiguous_before on an if-match put preserves the live etag" do
    key = key("ambiguous-before-cas")

    assert {:ok, %{etag: e0}} = S3.put(key, "v0")

    :ok = Fake.set_fault({:ambiguous_before, :put, key})

    assert {:error, {:ambiguous, :injected}} = S3.put(key, "v1", if_match: e0)
    assert {:ok, %{body: "v0", etag: ^e0}} = S3.get(key)

    assert {:ok, %{etag: e1}} = S3.put(key, "v1", if_match: e0)
    refute e1 == e0
  end

  test "precondition_after models the adapter-classified retried conditional 412" do
    key = key("precondition-after-cas")

    assert {:ok, %{etag: e0}} = S3.put(key, "v0")

    :ok = Fake.set_fault({:precondition_after, :put, key})

    # The write lands; the reply is the AMBIGUOUS classification the AWS
    # adapter produces for a retried conditional 412 — never a clean
    # conflict a CAS caller could take as permission to re-run.
    assert {:error, {:ambiguous, :conditional_retry_412}} = S3.put(key, "v1", if_match: e0)
    assert {:ok, %{body: "v1", etag: e1}} = S3.get(key)
    refute e1 == e0

    # A stale etag on a FIRST attempt is a clean conflict.
    assert {:error, :precondition_failed} = S3.put(key, "v2", if_match: e0)
    assert {:ok, %{body: "v1"}} = S3.get(key)
  end

  test "precondition_after on a conditional DELETE lands the delete and stays ambiguous" do
    key = key("precondition-after-delete")

    assert {:ok, %{etag: e0}} = S3.put(key, "v0")

    :ok = Fake.set_fault({:precondition_after, :delete, key})

    # Symmetric with the PUT contract: the delete lands, and the reply is
    # the adapter's ambiguous retried-conditional classification — a caller
    # settling by read-back sees the key gone but must not treat the 412 as
    # proof its own delete did NOT land.
    assert {:error, {:ambiguous, :conditional_retry_412}} = S3.delete(key, if_match: e0)
    assert {:error, :not_found} = S3.get(key)

    # A conditional delete of the now-missing key on a FIRST attempt is a
    # clean conflict.
    assert {:error, :precondition_failed} = S3.delete(key, if_match: e0)
  end

  test "a paused GET returns its captured snapshot after concurrent mutation" do
    key = key("paused-get")
    assert {:ok, %{etag: e0}} = S3.put(key, "before")

    read =
      Task.async(fn ->
        receive do
          :read -> S3.get(key)
        end
      end)

    :ok = Fake.set_fault_for(read.pid, {:pause, :get, key})
    send(read.pid, :read)
    assert wait_until(&Fake.paused?/0)

    assert {:ok, %{etag: e1}} = S3.put(key, "after", if_match: e0)
    refute e1 == e0
    assert :ok = Fake.release_pause()

    assert {:ok, %{body: "before", etag: ^e0}} = Task.await(read)
    assert {:ok, %{body: "after", etag: ^e1}} = S3.get(key)
  end

  defp key(tag), do: "fake-contract/#{tag}/#{System.unique_integer([:positive])}"

  defp wait_until(fun, attempts \\ 80)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(fun, 0), do: fun.()
end
