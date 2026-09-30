defmodule SalixAgent.HistoricalTelegramReplyFixture do
  @moduledoc """
  Deterministic provider for replaying an old Telegram reply through the real
  runtime before switching to the live model. Owns the provider response format;
  the E2E asserts captured delivery and settled state, not generated transcripts.
  """
  @behaviour SalixAgent.LLM

  @impl true
  def complete(_messages, _tools) do
    send(
      Application.fetch_env!(:salix_agent, :live_llm_test_capture_pid),
      {:historical_reply_request, self()}
    )

    receive do
      {:historical_reply, response} -> response
    after
      5_000 -> raise "timed out replaying the earlier Telegram response"
    end
  end

  def respond(pid, id, args) do
    send(pid, {:historical_reply, {:assistant, "", [%{id: id, name: "call", args: args}]}})
  end

  def finish(pid) do
    send(
      pid,
      {:historical_reply,
       {:assistant, "", [%{id: "historical-end", name: "end_turn", args: %{"outcome" => "done"}}]}}
    )
  end
end
