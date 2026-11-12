defmodule SalixAgent.QueueYieldGuardTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.QueueYieldGuard

  test "only answering, delegating, waiting on running calls and ending stay allowed" do
    for name <- ~w(end_turn wait_for im_api.internal.task.create
                   im_api.internal.send_message im_api.slack.reply_message
                   im_api.feishu.reply_text im_api.slack.update_message
                   im_api.slack.post_task_card im_api.slack.leave_thread) do
      assert QueueYieldGuard.allowed?(name), name
    end

    for name <-
          ~w(fs.read_file fs.edit_file web.http_request web.search env.exec tool_call.get_status
                   im_api.internal.update_conversation im_api.internal.reply_message
                   im_api.slack.post_channel_message im_api.telegram.send_message) do
      refute QueueYieldGuard.allowed?(name), name
    end

    refute QueueYieldGuard.allowed?(nil)
  end

  test "a session that is not a Router's is never guarded" do
    refute QueueYieldGuard.engaged?(%{}, "router")
    assert QueueYieldGuard.check(%{}, "worker") == nil
  end
end
