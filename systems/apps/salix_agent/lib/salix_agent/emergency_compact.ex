defmodule SalixAgent.EmergencyCompact do
  @moduledoc false

  @max_message_bytes 1_000
  @replacement "[emergency-compacted non-model message over 1000 bytes]"

  @doc false
  def event(session_id, through_id) when is_binary(session_id) and is_integer(through_id) do
    %{
      "type" => "session_microcompact",
      "session_id" => session_id,
      "non_model_messages_over_bytes_through" => through_id,
      "non_model_message_max_bytes" => @max_message_bytes,
      "new_content" => @replacement
    }
  end

  @doc false
  def result(through_id) when is_integer(through_id) do
    %{
      "status" => "emergency_compacted",
      "through_id" => through_id,
      "max_bytes" => @max_message_bytes,
      "replacement" => @replacement
    }
  end
end
