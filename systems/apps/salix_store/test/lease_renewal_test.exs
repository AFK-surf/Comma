defmodule SalixStore.LeaseRenewalTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Lease, S3}

  @key "ctl/test/bounded-renewal/lease.json"
  @now 1_000_000

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous) end)
    {:ok, token} = Lease.acquire(@key, "holder", now: @now)
    S3.Fake.reset_put_log()
    %{token: token}
  end

  test "frequent checks leave a fresh lease unchanged and renew at the boundary", %{token: token} do
    for elapsed <- 1..14 do
      assert {:ok, ^token} = Lease.renew_if_due(token, now: @now + elapsed * 1_000)
    end

    assert S3.Fake.put_log() == []
    assert {:ok, renewed} = Lease.renew_if_due(token, now: @now + 15_000)
    assert renewed.lease_until == @now + 45_000
    assert renewed.etag != token.etag
    assert S3.Fake.put_log() == [@key]
  end

  test "a fast-clock contender fences the old owner even before its local renewal is due", %{
    token: token
  } do
    assert {:ok, successor} = Lease.acquire(@key, "successor", now: @now + 30_001)
    S3.Fake.reset_put_log()

    assert {:error, :lost} = Lease.renew_if_due(token, now: @now + 1)
    assert {:ok, %{etag: etag}} = S3.head(@key)
    assert etag == successor.etag
    assert S3.Fake.put_log() == []
  end

  test "a deleted lease is not recreated by an early ownership check", %{token: token} do
    :ok = Lease.release(token)
    assert {:error, :lost} = Lease.renew_if_due(token, now: @now + 1)
    assert {:error, :not_found} = S3.get(@key)
    assert S3.Fake.put_log() == []
  end

  test "an unreadable fresh lease fails closed without a write", %{token: token} do
    S3.Fake.set_fault({:fail, 503, :head, @key})
    assert {:error, :lost} = Lease.renew_if_due(token, now: @now + 1)
    assert S3.Fake.put_log() == []
  end

  test "a required renewal still reports throttling and never claims extension", %{token: token} do
    S3.Fake.set_fault({:fail, 429, :put, @key})
    assert {:error, {:http, 429}} = Lease.renew_if_due(token, now: @now + 15_000)
    assert {:ok, %{etag: etag}} = S3.head(@key)
    assert etag == token.etag
  end
end
