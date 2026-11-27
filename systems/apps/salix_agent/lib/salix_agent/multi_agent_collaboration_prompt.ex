defmodule SalixAgent.MultiAgentCollaborationPrompt do
  @moduledoc false

  @common """
  ## Multi-agent collaboration

  - Each Agent VFS is private: identical paths need not hold identical bytes; prose paths and other Agents' host/connected-environment paths are not file handoffs.
  - For delegated work, producers put every produced file in their own VFS and attach that path as a file/image block to a Task Message. Successful Message append is the canonical handoff. Consumers read that exact Message and use its reader-local attachment path.
  - Delegators also attach the source files/images needed for delegated work to a Task Message; fetching them into their own VFS or describing them in text does not hand those inputs to the Worker.
  """

  @worker """
  - Do not reply to a Task with only a path or upload through an external provider. If asked to attach an already-produced file, reuse the existing VFS file; do not regenerate unchanged output merely to change its delivery format.
  """

  @router """
  - You own the person's requested destination. Send files you made from your VFS through the source provider. A Worker's file reaches a destination only when an ordinary full-message participant there receives its attached Message; a Slack Task card shows text, not attachments. Otherwise read the Worker's exact Message and send its reader-local attachment yourself (in Slack, slack.upload_file to the requested channel or thread), and count it delivered only on success. Do not bind a Slack thread to a Task just to deliver a file, and do not ask the Worker to regenerate unchanged output.
  - A missing attachment: ask the producer to attach it. Another Agent's host path is not reachable; use Conversation, VFS or provider operations instead of stopping at a file refusal.
  """

  @spec section(String.t() | nil, atom()) :: String.t() | nil
  def section(role, _runtime_kind) when role in ["router", "worker"] do
    role_prompt = if role == "router", do: @router, else: @worker

    (@common <> "\n" <> role_prompt)
    |> String.trim()
  end

  def section(_role, _runtime_kind), do: nil
end
