defmodule Salix.Bindings.LocalFileImportTest do
  use ExUnit.Case, async: true

  alias Salix.Bindings.LocalFileImport

  @ref "lfi1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

  defmodule Conversations do
    def get_group_conversation_message(group_id, conversation_id, message_id) do
      send(self(), {:canonical_read, group_id, conversation_id, message_id})
      {:ok, Process.get(:canonical_message)}
    end
  end

  defmodule Refs do
    def resolve_committed(group_id, conversation_id, message, ref) do
      send(self(), {:resolved, group_id, conversation_id, message, ref})

      {:ok,
       %{
         "connection_generation" => 23,
         "connector_run_id" => "run_exact",
         "local_file_ref" => ref,
         "owner_user_id" => "user_exact",
         "stable_device_id" => "dev_exact"
       }}
    end

    def refence_committed(group_id, conversation_id, message, ref, admitted) do
      send(self(), {:refenced, group_id, conversation_id, message, ref, admitted})

      if Process.get(:read_finished) == true do
        Process.get(:refence_result, :ok)
      else
        {:error, :fence_before_read_finished}
      end
    end
  end

  defmodule Connector do
    def read_stream(run_id, request, timeout) do
      send(self(), {:read_ref, run_id, request, timeout})
      {:ok, ["bytes"], nil}
    end
  end

  defmodule Workspace do
    def operation_result(_agent_id, operation_id) do
      Process.get({:operation, operation_id}, {:error, :not_found})
    end

    def discard_prepared_write(event) do
      send(self(), {:discarded, event})
      :ok
    end
  end

  defmodule Prepare do
    def prepare_managed_write_stream(agent_id, path, stream, opts) do
      bytes = stream |> Enum.to_list() |> IO.iodata_to_binary()
      Process.put(:read_finished, true)
      send(self(), {:prepared, agent_id, path, bytes, opts})

      {:ok,
       %{
         "hash" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         "path" => path,
         "prepared_blob_cleanup" => true,
         "ref" => %{"key" => "prepared/exact"},
         "size" => byte_size(bytes),
         "type" => "vfs_write"
       }}
    end
  end

  defmodule Actor do
    def commit_workspace_operation(agent_id, operation_id, result, [event], opts) do
      send(self(), {:committed, agent_id, operation_id, result, event, opts})
      Process.put({:operation, operation_id}, {:ok, result})
      {:ok, result}
    end
  end

  defmodule AmbiguousCommitActor do
    def commit_workspace_operation(agent_id, operation_id, result, [event], opts) do
      attempt = Process.get(:ambiguous_commit_attempt, 0) + 1
      Process.put(:ambiguous_commit_attempt, attempt)
      call = {agent_id, operation_id, result, event, opts}
      send(self(), {:ambiguous_commit_attempt, attempt, call})

      case {Process.get(:ambiguous_commit_mode), attempt} do
        {mode, 1} when mode in [:settles, :settlement_read_fails] ->
          # The manifest PUT landed, but the owner did not observe its reply.
          Process.put({:operation, operation_id}, {:ok, result})
          Process.put({:cleanup_ownership, operation_id}, :prepared)
          Process.put(:first_ambiguous_commit_call, call)
          {:error, {:ambiguous, :put}}

        {:settles, 2} ->
          # The exact idempotent owner reads the already-committed operation,
          # reconciles the same managed event, and adopts cleanup ownership.
          true = Process.get(:first_ambiguous_commit_call) == call
          {:ok, committed} = Process.get({:operation, operation_id})
          Process.put({:cleanup_ownership, operation_id}, :adopted)
          send(self(), {:ambiguous_commit_reconciled, operation_id})
          {:ok, committed}

        {:settlement_read_fails, 2} ->
          # A transient readback failure cannot prove that the landed write is
          # absent. The caller must leave durable cleanup ownership intact.
          true = Process.get(:first_ambiguous_commit_call) == call
          {:error, :storage_unavailable}
      end
    end
  end

  defmodule WrongSizeConnector do
    def read_stream(_run_id, _request, _timeout), do: {:ok, ["too short"], nil}
  end

  setup do
    Process.put(:read_finished, false)
    Process.put(:refence_result, :ok)
    Process.delete(:ambiguous_commit_attempt)
    Process.delete(:ambiguous_commit_mode)
    Process.delete(:first_ambiguous_commit_call)

    Process.put(:canonical_message, %{
      "actor_type" => "user",
      "content" => [
        %{
          "display_name" => "report.txt",
          "local_file_ref" => @ref,
          "media_type" => "text/plain",
          "size" => 5,
          "type" => "local_file"
        }
      ],
      "message_id" => "msg1_exact",
      "user_id" => "user_exact"
    })

    :ok
  end

  test "re-reads the canonical message and emits only the exact read_ref tuple" do
    assert {:ok, ["bytes"], nil} =
             LocalFileImport.read_stream("grp1_exact", "cnv1_exact", "msg1_exact", @ref,
               conversations: Conversations,
               refs: Refs,
               connector: Connector,
               timeout: 10_000
             )

    assert_receive {:canonical_read, "grp1_exact", "cnv1_exact", "msg1_exact"}
    assert_receive {:resolved, "grp1_exact", "cnv1_exact", message, @ref}
    assert message == Process.get(:canonical_message)

    assert_receive {:read_ref, "run_exact",
                    %{
                      "method" => "read_ref",
                      "params" => params,
                      "type" => "request"
                    }, 10_000}

    assert params == %{
             "canonical_message_id" => "msg1_exact",
             "connection_generation" => 23,
             "connector_run_id" => "run_exact",
             "expected_max_bytes" => 5,
             "local_file_ref" => @ref,
             "owner_user_id" => "user_exact",
             "stream_lease_ms" => 60_000,
             "stable_device_id" => "dev_exact"
           }

    refute Map.has_key?(params, "path")
  end

  test "fails closed before resolution when the exact canonical message does not match" do
    Process.put(:canonical_message, %{
      "actor_type" => "user",
      "content" => [],
      "message_id" => "msg1_other",
      "user_id" => "user_exact"
    })

    assert {:error, :local_file_unavailable} =
             LocalFileImport.read_stream("grp1_exact", "cnv1_exact", "msg1_exact", @ref,
               conversations: Conversations,
               refs: Refs,
               connector: Connector
             )

    refute_received {:resolved, _, _, _, _}
    refute_received {:read_ref, _, _, _}
  end

  test "materializes a canonical ref once into a deterministic managed VFS write" do
    delivery = delivery()

    assert {:ok,
            [
              %{
                "file_name" => "report.txt",
                "mime_type" => "text/plain",
                "path" => path,
                "size" => 5,
                "type" => "file"
              } = file
            ], [trusted_file]} =
             LocalFileImport.materialize_delivery("agt1_exact", delivery,
               actor: Actor,
               connector: Connector,
               conversations: Conversations,
               prepare: Prepare,
               refs: Refs,
               workspace: Workspace
             )

    assert trusted_file == file

    assert String.starts_with?(path, "/attachments/local/msg1_exact/")
    refute String.contains?(path, @ref)
    assert_receive {:prepared, "agt1_exact", ^path, "bytes", prepare_opts}
    assert prepare_opts[:actor_type] == "user"
    assert prepare_opts[:entrypoint] == "local_file_import"

    assert_receive {:committed, "agt1_exact", operation_id, result, event, commit_opts}
    assert String.starts_with?(operation_id, "local-file-import:v1:")
    assert result["path"] == path
    assert result["source_message_id"] == "msg1_exact"
    assert result["size"] == 5
    assert event["prepared_blob_cleanup"] == true
    assert commit_opts[:actor_type] == "user"
    assert_receive {:canonical_read, "grp1_exact", "cnv1_exact", "msg1_exact"}
    assert_receive {:resolved, "grp1_exact", "cnv1_exact", _, @ref}

    assert_receive {:refenced, "grp1_exact", "cnv1_exact", _, @ref,
                    %{
                      "connection_generation" => 23,
                      "connector_run_id" => "run_exact",
                      "local_file_ref" => @ref,
                      "owner_user_id" => "user_exact",
                      "stable_device_id" => "dev_exact"
                    }}

    assert_receive {:read_ref, "run_exact", _, _}

    # An ambiguous delivery retry resolves the durable operation and neither
    # reads the host snapshot again nor creates another prepared blob.
    assert {:ok, [%{"path" => ^path, "type" => "file"} = retry_file], [retry_trusted]} =
             LocalFileImport.materialize_delivery("agt1_exact", delivery,
               actor: Actor,
               connector: Connector,
               conversations: Conversations,
               prepare: Prepare,
               refs: Refs,
               workspace: Workspace
             )

    assert retry_trusted == retry_file

    refute_received {:canonical_read, _, _, _}
    refute_received {:prepared, _, _, _, _}
    refute_received {:committed, _, _, _, _, _}
  end

  test "never commits or publishes a VFS path when streamed bytes violate the declaration" do
    assert {:error, :local_file_unavailable} =
             LocalFileImport.materialize_delivery("agt1_exact", delivery(),
               actor: Actor,
               connector: WrongSizeConnector,
               conversations: Conversations,
               prepare: Prepare,
               refs: Refs,
               workspace: Workspace
             )

    refute_received {:prepared, _, _, _, _}
    refute_received {:committed, _, _, _, _, _}
    refute_received {:discarded, _}
  end

  test "an ambiguous landed manifest PUT re-enters the exact commit owner and adopts cleanup ownership" do
    Process.put(:ambiguous_commit_mode, :settles)

    assert {:ok, [%{"path" => path, "type" => "file"}], [_trusted]} =
             LocalFileImport.materialize_delivery("agt1_exact", delivery(),
               actor: AmbiguousCommitActor,
               connector: Connector,
               conversations: Conversations,
               prepare: Prepare,
               refs: Refs,
               workspace: Workspace
             )

    assert_receive {:ambiguous_commit_attempt, 1,
                    {"agt1_exact", operation_id, result, event, commit_opts}}

    assert result["path"] == path
    assert event["path"] == path
    assert commit_opts[:entrypoint] == "local_file_import"

    assert_receive {:ambiguous_commit_attempt, 2,
                    {"agt1_exact", ^operation_id, ^result, ^event, ^commit_opts}}

    assert_receive {:ambiguous_commit_reconciled, ^operation_id}
    assert Process.get({:cleanup_ownership, operation_id}) == :adopted
    refute_received {:discarded, _}
  end

  test "a transient settlement read failure preserves cleanup ownership for a landed commit" do
    Process.put(:ambiguous_commit_mode, :settlement_read_fails)

    assert {:error, :local_file_unavailable} =
             LocalFileImport.materialize_delivery("agt1_exact", delivery(),
               actor: AmbiguousCommitActor,
               connector: Connector,
               conversations: Conversations,
               prepare: Prepare,
               refs: Refs,
               workspace: Workspace
             )

    assert_receive {:ambiguous_commit_attempt, 1,
                    {"agt1_exact", operation_id, result, event, commit_opts}}

    assert_receive {:ambiguous_commit_attempt, 2,
                    {"agt1_exact", ^operation_id, ^result, ^event, ^commit_opts}}

    assert Process.get({:cleanup_ownership, operation_id}) == :prepared
    refute_received {:discarded, _}
  end

  test "lease expiry after staging discards the event before final refence or publication" do
    Process.put(:monotonic_times, [1_000, 1_000, 61_000])

    monotonic_ms = fn ->
      [now | remaining] = Process.get(:monotonic_times)
      Process.put(:monotonic_times, remaining)
      now
    end

    assert {:error, :local_file_unavailable} =
             LocalFileImport.materialize_delivery("agt1_exact", delivery(),
               actor: Actor,
               connector: Connector,
               conversations: Conversations,
               monotonic_ms: monotonic_ms,
               prepare: Prepare,
               read_lease_ms: 60_000,
               refs: Refs,
               workspace: Workspace
             )

    assert_receive {:prepared, "agt1_exact", _path, "bytes", _opts}
    assert_receive {:discarded, _event}
    refute_received {:refenced, _, _, _, _, _}
    refute_received {:committed, _, _, _, _, _}
  end

  for mutation <- [:revoke, :reconnect, :replacement] do
    test "#{mutation} after stream admission fails the final fence and never publishes" do
      Process.put(:refence_result, {:error, :local_file_unavailable})

      assert {:error, :local_file_unavailable} =
               LocalFileImport.materialize_delivery("agt1_exact", delivery(),
                 actor: Actor,
                 connector: Connector,
                 conversations: Conversations,
                 prepare: Prepare,
                 refs: Refs,
                 workspace: Workspace
               )

      assert_receive {:prepared, "agt1_exact", _path, "bytes", _opts}
      assert_receive {:refenced, "grp1_exact", "cnv1_exact", _, @ref, admitted}
      assert admitted["connector_run_id"] == "run_exact"
      assert admitted["connection_generation"] == 23
      assert_receive {:discarded, _event}
      refute_received {:committed, _, _, _, _, _}
    end
  end

  defp delivery do
    %{
      "agent_group_id" => "grp1_exact",
      "conversation_id" => "cnv1_exact",
      "delivery_billing_context" => %{"billing_account_id" => "bill1_exact"},
      "message_content" => Process.get(:canonical_message)["content"],
      "message_id" => "msg1_exact",
      "source_actor_type" => "user"
    }
  end
end
