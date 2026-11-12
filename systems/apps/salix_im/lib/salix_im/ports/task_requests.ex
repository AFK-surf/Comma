defmodule SalixIM.Ports.TaskRequests do
  @moduledoc """
  Task requests, as Salix IM reaches their owner (`Comma.TaskRequests`, in the
  product). Salix cannot depend on the product, so the product sets the module
  that implements this behaviour at start (`config :salix_im, :task_requests`).
  Without it, `send_from_router/5` answers
  `{:error, :task_requests_unavailable}`.

  `send_from_router/5` sends `content` from `user_id` through their grant
  `grant_id`, as they asked in the Router chat of `group_id`. The product
  checks that the person is the Group's Workspace owner, their grant and its
  limits; `key` makes a second send the first one.
  """

  @callback send_from_router(
              group_id :: String.t(),
              user_id :: String.t(),
              grant_id :: String.t(),
              content :: String.t(),
              key :: String.t()
            ) :: {:ok, %{String.t() => term()}} | {:error, term()}

  def send_from_router(group_id, user_id, grant_id, content, key) do
    case SystemsRuntime.get_env(:salix_im, :task_requests) do
      nil -> {:error, :task_requests_unavailable}
      module -> module.send_from_router(group_id, user_id, grant_id, content, key)
    end
  end
end
