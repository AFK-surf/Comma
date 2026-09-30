defmodule SalixIM.LocalFileDeliveryTest do
  use ExUnit.Case, async: false

  alias SalixIM.ConversationDelivery

  defmodule Import do
    @behaviour SalixIM.Ports.LocalFileImport

    @impl true
    def materialize_delivery(agent_id, delivery) do
      send(:persistent_term.get({__MODULE__, :owner}), {:materialize, agent_id, delivery})

      case :persistent_term.get({__MODULE__, :result}) do
        :success ->
          file = %{
            "file_name" => "report.txt",
            "mime_type" => "text/plain",
            "path" => "/attachments/local/msg1_exact/opaque-report.txt",
            "size" => 5,
            "type" => "file"
          }

          {:ok, [file], [file]}

        :unavailable ->
          {:error, :local_file_unavailable}
      end
    end
  end

  setup do
    previous_import = Application.get_env(:salix_im, :local_file_import_mod)
    Application.put_env(:salix_im, :local_file_import_mod, Import)
    :persistent_term.put({Import, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({Import, :owner})
      :persistent_term.erase({Import, :result})
      restore(:local_file_import_mod, previous_import)
    end)

    :ok
  end

  test "delivers only the materialized VFS file and never the opaque local ref" do
    :persistent_term.put({Import, :result}, :success)
    delivery = delivery()
    agent_id = delivery["participant_agent_id"]

    assert {:ok, ^agent_id, payload, _opts} = ConversationDelivery.materialize_agent(delivery)
    assert_receive {:materialize, ^agent_id, ^delivery}

    assert [
             %{
               "path" => "/attachments/local/msg1_exact/opaque-report.txt",
               "type" => "file"
             }
           ] = Jason.decode!(payload.content)

    assert [
             %{
               "path" => "/attachments/local/msg1_exact/opaque-report.txt",
               "type" => "file"
             }
           ] = payload.trusted_attachment_refs

    refute payload.content =~ "lfi1_"
  end

  test "device unavailability remains retryable under the delivery owner's bounded lease" do
    :persistent_term.put({Import, :result}, :unavailable)

    assert {:error, :local_file_unavailable, true} =
             ConversationDelivery.materialize_agent(delivery())

    refute_received {:agent_delivery, _, _, _}
  end

  defp delivery do
    group_id = SalixAgent.TestSupport.new_group_id()

    %{
      "agent_group_id" => group_id,
      "conversation_id" => SalixStore.Ids.new_conversation_id(),
      "conversation_kind" => "user_chat",
      "message_content" => [
        %{
          "display_name" => "report.txt",
          "local_file_ref" => "lfi1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          "media_type" => "text/plain",
          "size" => 5,
          "type" => "local_file"
        }
      ],
      "message_created_at" => 1,
      "message_id" => SalixStore.Ids.new_message_id(),
      "participant_actor_type" => "agent",
      "participant_agent_id" => SalixStore.Ids.new_agent_id(group_id),
      "participant_id" => SalixStore.Ids.new_participant_id(),
      "participant_payload" => %{"session_id" => SalixStore.Ids.new_session_id()},
      "participant_role_label" => "agent",
      "source_actor_type" => "user"
    }
  end

  defp restore(key, nil), do: Application.delete_env(:salix_im, key)
  defp restore(key, value), do: Application.put_env(:salix_im, key, value)
end
