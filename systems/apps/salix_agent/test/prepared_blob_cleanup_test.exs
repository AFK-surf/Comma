defmodule SalixAgent.PreparedBlobCleanupTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentWorkspace, PreparedBlobCleanup}
  alias SalixStore.{Keys, S3}

  defmodule BlockingIntentReadBackend do
    @control_key {__MODULE__, :control}

    def configure(test_pid), do: :persistent_term.put(@control_key, test_pid)
    def clear, do: :persistent_term.erase(@control_key)

    def put(key, body, opts), do: S3.Fake.put(key, body, opts)
    def multipart_create(key, opts), do: S3.Fake.multipart_create(key, opts)

    def get(key, opts) do
      case {String.starts_with?(key, Keys.prepared_blob_cleanup_prefix()),
            :persistent_term.get(@control_key, nil)} do
        {true, test_pid} when is_pid(test_pid) ->
          send(test_pid, {:cleanup_intent_read_blocked, self()})

          receive do
            :continue_cleanup_intent_read -> S3.Fake.get(key, opts)
          end

        _other ->
          S3.Fake.get(key, opts)
      end
    end

    def list(prefix, opts), do: S3.Fake.list(prefix, opts)
    def head(key), do: S3.Fake.head(key)
    def delete(key, opts), do: S3.Fake.delete(key, opts)
    def multipart_abort(key, upload_id), do: S3.Fake.multipart_abort(key, upload_id)
    def multipart_uploads(prefix, opts), do: S3.Fake.multipart_uploads(prefix, opts)
  end

  defmodule MultipartCleanupPolicyBackend do
    @control_key {__MODULE__, :allowed}

    def configure(allowed), do: :persistent_term.put(@control_key, allowed)
    def clear, do: :persistent_term.erase(@control_key)

    def put(key, body, opts), do: S3.Fake.put(key, body, opts)
    def get(key, opts), do: S3.Fake.get(key, opts)
    def list(prefix, opts), do: S3.Fake.list(prefix, opts)
    def head(key), do: S3.Fake.head(key)
    def delete(key, opts), do: S3.Fake.delete(key, opts)

    def multipart_uploads(prefix, opts) do
      if :persistent_term.get(@control_key, false),
        do: S3.Fake.multipart_uploads(prefix, opts),
        else: {:error, {:http, 403}}
    end

    def multipart_abort(key, upload_id) do
      if :persistent_term.get(@control_key, false),
        do: S3.Fake.multipart_abort(key, upload_id),
        else: {:error, {:http, 403}}
    end
  end

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)

    case Process.whereis(S3.Fake) do
      nil -> start_supervised!(S3.Fake)
      _pid -> S3.Fake.reset()
    end

    on_exit(fn ->
      BlockingIntentReadBackend.clear()
      MultipartCleanupPolicyBackend.clear()

      if is_nil(previous_backend),
        do: Application.delete_env(:salix_store, :s3_backend),
        else: Application.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    :ok
  end

  test "a killed multipart preparation is aborted by its durable cleanup intent" do
    parent = self()
    first_part = String.duplicate("x", 5 * 1024 * 1024)

    stream =
      Stream.concat(
        [first_part],
        Stream.resource(
          fn -> :waiting end,
          fn :waiting ->
            send(parent, :first_part_uploaded)

            receive do
              :never -> {:halt, :done}
            end
          end,
          fn _ -> :ok end
        )
      )

    agent_id = valid_agent_id()

    {pid, monitor} =
      spawn_monitor(fn ->
        AgentWorkspace.prepare_managed_write_stream(agent_id, "/audio", stream)
      end)

    assert_receive :first_part_uploaded, 2_000
    assert S3.Fake.pending_multipart_uploads() == 1

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    assert {:ok, %{cleaned: 1, retained: 0}} =
             PreparedBlobCleanup.sweep_once(grace_seconds: 0)

    assert S3.Fake.pending_multipart_uploads() == 0
    assert {:ok, %{objects: []}} = S3.list("blobs/")
    assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
  end

  test "a multipart created before its upload id checkpoint is reconciled by exact blob key" do
    Application.put_env(:salix_store, :s3_backend, BlockingIntentReadBackend)
    BlockingIntentReadBackend.configure(self())
    agent_id = valid_agent_id()

    {pid, monitor} =
      spawn_monitor(fn ->
        AgentWorkspace.prepare_managed_write_stream(
          agent_id,
          "/audio",
          [String.duplicate("x", 5 * 1024 * 1024)]
        )
      end)

    assert_receive {:cleanup_intent_read_blocked, ^pid}, 2_000
    assert S3.Fake.pending_multipart_uploads() == 1

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    BlockingIntentReadBackend.clear()

    assert {:ok, %{cleaned: 1, retained: 0}} =
             PreparedBlobCleanup.sweep_once(grace_seconds: 0)

    assert S3.Fake.pending_multipart_uploads() == 0
    assert {:ok, %{objects: []}} = S3.list("blobs/")
    assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
  end

  test "missing multipart cleanup IAM retains the upload and intent until permission is restored" do
    parent = self()

    stream =
      Stream.concat(
        [String.duplicate("x", 5 * 1024 * 1024)],
        Stream.resource(
          fn -> :waiting end,
          fn :waiting ->
            send(parent, :policy_test_part_uploaded)

            receive do
              :never -> {:halt, :done}
            end
          end,
          fn _ -> :ok end
        )
      )

    {pid, monitor} =
      spawn_monitor(fn ->
        AgentWorkspace.prepare_managed_write_stream(valid_agent_id(), "/audio", stream)
      end)

    assert_receive :policy_test_part_uploaded, 2_000
    assert S3.Fake.pending_multipart_uploads() == 1
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}

    Application.put_env(:salix_store, :s3_backend, MultipartCleanupPolicyBackend)
    MultipartCleanupPolicyBackend.configure(false)

    assert {:ok, %{cleaned: 0, retained: 1}} =
             PreparedBlobCleanup.sweep_once(grace_seconds: 0)

    assert S3.Fake.pending_multipart_uploads() == 1
    assert {:ok, %{objects: [_]}} = S3.list(Keys.prepared_blob_cleanup_prefix())

    MultipartCleanupPolicyBackend.configure(true)

    assert {:ok, %{cleaned: 1, retained: 0}} =
             PreparedBlobCleanup.sweep_once(grace_seconds: 0)

    assert S3.Fake.pending_multipart_uploads() == 0
    assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
  end

  test "a committed manifest adopts its prepared body before cleanup" do
    agent_id = valid_agent_id()
    assert {:ok, event} = AgentWorkspace.prepare_managed_write(agent_id, "/transcript", "hello")

    assert {:ok, :done} =
             AgentWorkspace.seed_operation(agent_id, "op-adopt", :done, [event])

    assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
    assert {:ok, "hello"} = AgentWorkspace.read(agent_id, "/transcript")
  end

  test "a committed operation protects a shared blob when intent deletion failed" do
    source_agent = valid_agent_id()
    target_agent = valid_agent_id()
    assert {:ok, event} = AgentWorkspace.prepare_managed_write(source_agent, "/audio", "bytes")
    uuid = get_in(event, ["ref", "uuid"])
    intent_key = Keys.prepared_blob_cleanup(uuid)

    :ok = S3.Fake.set_fault({:fail, 503, :delete, intent_key})
    assert {:ok, :done} = AgentWorkspace.seed_operation(source_agent, "op-source", :done, [event])
    assert {:ok, entry} = AgentWorkspace.entry(source_agent, "/audio")
    assert {:ok, copy_event} = AgentWorkspace.prepare_copy_entry("/shared-audio", entry)

    assert {:ok, :done} =
             AgentWorkspace.seed_operation(target_agent, "op-copy", :done, [copy_event])

    assert {:ok, :done} =
             AgentWorkspace.seed_operation(source_agent, "op-delete", :done, [
               AgentWorkspace.prepare_delete("/audio")
             ])

    assert {:ok, %{cleaned: 1, retained: 0}} =
             PreparedBlobCleanup.sweep_once(grace_seconds: 0)

    assert {:ok, "bytes"} = AgentWorkspace.read(target_agent, "/shared-audio")
    assert {:ok, _} = S3.head(Keys.blob(uuid))
  end

  test "exact operation replay adopts its immutable winner after the original path changed" do
    source_agent = valid_agent_id()
    target_agent = valid_agent_id()
    assert {:ok, event} = AgentWorkspace.prepare_managed_write(source_agent, "/audio", "winner")
    uuid = get_in(event, ["ref", "uuid"])
    intent_key = Keys.prepared_blob_cleanup(uuid)

    :ok = S3.Fake.set_fault({:fail, 503, :delete, intent_key})
    assert {:ok, :done} = AgentWorkspace.seed_operation(source_agent, "op-replay", :done, [event])
    assert {:ok, entry} = AgentWorkspace.entry(source_agent, "/audio")
    assert {:ok, copy_event} = AgentWorkspace.prepare_copy_entry("/shared", entry)

    assert {:ok, :done} =
             AgentWorkspace.seed_operation(target_agent, "op-copy", :done, [copy_event])

    assert {:ok, :done} =
             AgentWorkspace.seed_operation(source_agent, "op-overwrite", :done, [
               AgentWorkspace.prepare_delete("/audio")
             ])

    assert {:ok, :done} = AgentWorkspace.seed_operation(source_agent, "op-replay", :done, [event])
    assert {:ok, "winner"} = AgentWorkspace.read(target_agent, "/shared")
    assert {:ok, _} = S3.head(Keys.blob(uuid))
    assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
  end

  test "a cleanup delete failure retains intent and retries every object" do
    agent_id = valid_agent_id()
    assert {:ok, event} = AgentWorkspace.prepare_managed_write(agent_id, "/audio", "bytes")
    uuid = get_in(event, ["ref", "uuid"])
    blob_key = Keys.blob(uuid)

    :ok = S3.Fake.set_fault({:fail, 503, :delete, blob_key})

    assert {:ok, %{cleaned: 0, retained: 1}} =
             PreparedBlobCleanup.sweep_once(grace_seconds: 0)

    assert {:ok, _} = S3.head(blob_key)
    assert {:ok, %{objects: [_]}} = S3.list(Keys.prepared_blob_cleanup_prefix())

    assert {:ok, %{cleaned: 1, retained: 0}} =
             PreparedBlobCleanup.sweep_once(grace_seconds: 0)

    assert {:error, :not_found} = S3.head(blob_key)
    assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
  end

  test "an ambiguous multipart completion keeps cleanup ownership until reconciliation" do
    agent_id = valid_agent_id()

    stream =
      Stream.map([String.duplicate("x", 5 * 1024 * 1024)], fn chunk ->
        assert {:ok, %{objects: [%{key: intent_key}]}} =
                 S3.list(Keys.prepared_blob_cleanup_prefix())

        assert {:ok, %{body: body}} = S3.get(intent_key)
        record = Jason.decode!(body)
        :ok = S3.Fake.set_fault({:ambiguous_after, :put, record["blob_key"]})
        chunk
      end)

    assert {:error, {:ambiguous, :injected}} =
             AgentWorkspace.prepare_managed_write_stream(agent_id, "/audio", stream)

    assert S3.Fake.pending_multipart_uploads() == 0
    assert {:ok, %{objects: [_]}} = S3.list("blobs/")
    assert {:ok, %{objects: [_]}} = S3.list(Keys.prepared_blob_cleanup_prefix())

    assert {:ok, %{cleaned: 1, retained: 0}} =
             PreparedBlobCleanup.sweep_once(grace_seconds: 0)

    assert {:ok, %{objects: []}} = S3.list("blobs/")
    assert {:ok, %{objects: []}} = S3.list(Keys.prepared_blob_cleanup_prefix())
  end

  test "the persistent cursor advances past retained intents without an unbounded scan" do
    for index <- 1..4 do
      assert {:ok, _event} =
               AgentWorkspace.prepare_managed_write(
                 valid_agent_id(),
                 "/artifact",
                 "body-#{index}"
               )
    end

    assert {:ok, %{objects: intents}} =
             S3.list(Keys.prepared_blob_cleanup_prefix(), max_keys: 10)

    intents
    |> Enum.take(2)
    |> Enum.each(&set_intent_updated_at(&1.key, 1_000))

    intents
    |> Enum.drop(2)
    |> Enum.each(&set_intent_updated_at(&1.key, 0))

    assert {:ok, %{cleaned: 0, retained: 2}} =
             PreparedBlobCleanup.sweep_once(now: 1_000, grace_seconds: 100, batch_size: 2)

    assert {:ok, %{cleaned: 2, retained: 0}} =
             PreparedBlobCleanup.sweep_once(now: 1_000, grace_seconds: 100, batch_size: 2)

    assert {:ok, %{objects: remaining}} =
             S3.list(Keys.prepared_blob_cleanup_prefix(), max_keys: 10)

    assert Enum.map(remaining, & &1.key) == Enum.map(Enum.take(intents, 2), & &1.key)
    assert {:ok, %{objects: remaining_blobs}} = S3.list("blobs/", max_keys: 10)
    assert length(remaining_blobs) == 2
    assert {:ok, %{body: cursor_body}} = S3.get(Keys.prepared_blob_cleanup_cursor())
    assert %{"last_key" => last_key} = Jason.decode!(cursor_body)
    assert last_key == intents |> List.last() |> Map.fetch!(:key)
  end

  defp set_intent_updated_at(key, updated_at) do
    assert {:ok, %{body: body}} = S3.get(key)
    record = Jason.decode!(body) |> Map.put("updated_at", updated_at)
    assert {:ok, _} = S3.put(key, Jason.encode!(record))
  end

  defp valid_agent_id do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    SalixStore.Ids.new_agent_id(group_id)
  end
end
