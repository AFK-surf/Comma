defmodule SalixAgent.PreparedBlobCleanupTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.{AgentWorkspace, PreparedBlobCleanup}
  alias SalixStore.{Keys, S3}

  defmodule BlockingIntentReadBackend do
    @control_key {__MODULE__, :control}

    def configure(test_pid), do: SystemsRuntime.PersistentTerm.put(@control_key, test_pid)
    def clear, do: SystemsRuntime.PersistentTerm.erase(@control_key)

    def put(key, body, opts), do: S3.Fake.put(key, body, opts)
    def multipart_create(key, opts), do: S3.Fake.multipart_create(key, opts)

    def get(key, opts) do
      case {String.starts_with?(key, Keys.prepared_blob_cleanup_prefix()),
            SystemsRuntime.PersistentTerm.get(@control_key, nil)} do
        {true, test_pid} when SystemsRuntime.Proc.is_process(test_pid) ->
          SystemsRuntime.Proc.send(
            test_pid,
            {:cleanup_intent_read_blocked, SystemsRuntime.Proc.self()}
          )

          SystemsRuntime.Proc.receive do
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

    def configure(allowed), do: SystemsRuntime.PersistentTerm.put(@control_key, allowed)
    def clear, do: SystemsRuntime.PersistentTerm.erase(@control_key)

    def put(key, body, opts), do: S3.Fake.put(key, body, opts)
    def get(key, opts), do: S3.Fake.get(key, opts)
    def list(prefix, opts), do: S3.Fake.list(prefix, opts)
    def head(key), do: S3.Fake.head(key)
    def delete(key, opts), do: S3.Fake.delete(key, opts)

    def multipart_uploads(prefix, opts) do
      if SystemsRuntime.PersistentTerm.get(@control_key, false),
        do: S3.Fake.multipart_uploads(prefix, opts),
        else: {:error, {:http, 403}}
    end

    def multipart_abort(key, upload_id) do
      if SystemsRuntime.PersistentTerm.get(@control_key, false),
        do: S3.Fake.multipart_abort(key, upload_id),
        else: {:error, {:http, 403}}
    end
  end

  setup do
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    case SystemsRuntime.Proc.whereis(S3.Fake) do
      nil -> start_supervised!(S3.Fake)
      _pid -> S3.Fake.reset()
    end

    on_exit(fn ->
      BlockingIntentReadBackend.clear()
      MultipartCleanupPolicyBackend.clear()

      if is_nil(previous_backend),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    :ok
  end

  test "a killed multipart preparation is aborted by its durable cleanup intent" do
    parent = SystemsRuntime.Proc.self()
    first_part = String.duplicate("x", 5 * 1024 * 1024)

    stream =
      Stream.concat(
        [first_part],
        Stream.resource(
          fn -> :waiting end,
          fn :waiting ->
            SystemsRuntime.Proc.send(parent, :first_part_uploaded)

            SystemsRuntime.Proc.receive do
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

    settle_receive(:first_part_uploaded)
    assert S3.Fake.pending_multipart_uploads() == 1

    SystemsRuntime.Proc.exit(pid, :kill)
    settle_receive({:DOWN, ^monitor, :process, ^pid, :killed})

    assert {:ok, %{cleaned: 1, retained: 0}} =
             PreparedBlobCleanup.sweep_once(grace_seconds: 0)

    assert S3.Fake.pending_multipart_uploads() == 0
    assert {:ok, %{objects: []}} = S3.list("blobs/")
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

  defp valid_agent_id do
    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    SalixStore.Ids.new_agent_id(group_id)
  end
end
