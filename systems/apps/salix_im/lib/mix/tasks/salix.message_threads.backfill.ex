defmodule Mix.Tasks.Salix.MessageThreads.Backfill do
  use Mix.Task

  @shortdoc "Backfills message thread roots through the Conversation owner"
  @moduledoc """
  Convert historical reply metadata in one explicitly selected Conversation.

      mix salix.message_threads.backfill --group grp_... --conversation conv_...
      mix salix.message_threads.backfill --group grp_... --conversation conv_... --after-seq 32 --max-batches 10

  Each batch visits at most 32 messages. The result reports the next sequence
  and whether this Conversation is complete. The first rewrite saves the
  original segment under its Conversation's migrations/message_threads prefix.
  Resume a failed invocation from its last reported sequence, or from zero.
  A release must run this task after the writer cutover and before reopening
  affected conversations. See docs/salix/conversation-owner-actor.md for recovery.
  """

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          group: :string,
          conversation: :string,
          after_seq: :integer,
          max_batches: :integer
        ]
      )

    group_id = opts[:group]
    conversation_id = opts[:conversation]
    after_seq = Keyword.get(opts, :after_seq, 0)
    max_batches = Keyword.get(opts, :max_batches, 1)

    unless positional == [] and invalid == [] and SalixStore.Ids.valid_group_id?(group_id) and
             SalixStore.Ids.valid_conversation_id?(conversation_id) and after_seq >= 0 and
             max_batches in 1..100 do
      Mix.raise(
        "provide --group, --conversation, a nonnegative --after-seq, and --max-batches 1..100"
      )
    end

    Mix.Task.run("app.start")

    Enum.reduce_while(1..max_batches, after_seq, fn _batch, cursor ->
      case SalixIM.ConversationServer.backfill_message_threads(group_id, conversation_id, cursor) do
        {:ok, result} ->
          Mix.shell().info(Jason.encode!(result))
          if result.done, do: {:halt, result.after_seq}, else: {:cont, result.after_seq}

        {:error, reason} ->
          Mix.raise("message thread backfill stopped at #{cursor}: #{inspect(reason)}")
      end
    end)
  end
end
