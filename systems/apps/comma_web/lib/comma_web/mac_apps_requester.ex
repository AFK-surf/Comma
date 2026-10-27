defmodule CommaWeb.MacAppsRequester do
  @moduledoc """
  Who asked for a turn that reaches a member's own Mac (the Mac apps plugin,
  SalixMCP.Provider). A person's own turn counts, and so does a Worker's turn in
  an ordinary Task the Router created from that person's own request: the
  Router hands Mac work to Workers like any other. Background work, scheduled
  and Loop Tasks, and other members' requests have no requester here.
  """

  def requester(ctx) do
    case CommaWeb.Stations.requester(ctx) do
      {:ok, _user_id} = ok -> ok
      _ -> SalixIM.TaskExecution.task_requester(ctx)
    end
  end
end
