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
  - The Router owns the user's requested final destination. Deliver Router-produced files directly from its VFS through the source conversation/provider. For delegated files, if an ordinary full-message provider participant at that exact destination already receives the attached Message, let the attached Message deliver once. A Slack task-card participant projects text, not attachments; publishing a task card does not send the files. Otherwise read the producer's exact Message into Router VFS and deliver through the destination provider (for Slack, slack.upload_file with the reader-local path and the requested channel/thread); require success before declaring delivery complete. Do not bind a Slack thread to a Task just to deliver a file.
  - If a delegated result is already attached but the originally requested delivery remains incomplete, read the exact result Message and send its reader-local attachment to the original destination yourself. Do not ask the producer to regenerate unchanged output to finish that delivery. Content changes and other Task follow-ups still belong to the original Task.
  - Missing attachment: ask the producer to attach it or take an explicit peer copy. Never use another Agent's host path; try available Conversation/VFS/provider operations rather than stopping at a generic file operation refusal.
  """

  @spec section(String.t() | nil, atom()) :: String.t() | nil
  def section(role, _runtime_kind) when role in ["router", "worker"] do
    role_prompt = if role == "router", do: @router, else: @worker

    (@common <> "\n" <> role_prompt)
    |> String.trim()
  end

  def section(_role, _runtime_kind), do: nil
end
