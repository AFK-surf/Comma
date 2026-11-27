defmodule SalixIM.Ports.Collaborations do
  @moduledoc """
  Shared tasks (`Comma.Collaborations`, in the product), as Salix IM reaches
  their owner from the Router chat. Salix cannot depend on the product, so the
  product sets the module that implements this behaviour at start
  (`config :salix_im, :collaborations`). Without it, `start_from_router/5`
  answers `{:error, :collaborations_unavailable}`.

  `start_from_router/5` starts a shared task of `user_id` with `people` (user
  ids of their People) and its first message `content`, as they asked in the
  Router chat of `group_id`. The product checks that the person is the Group's
  Workspace owner and that each person is one of their People; `key` makes a
  second start the first one.
  """

  @callback start_from_router(
              group_id :: String.t(),
              user_id :: String.t(),
              people :: [String.t()],
              content :: String.t(),
              key :: String.t()
            ) :: {:ok, %{String.t() => term()}} | {:error, term()}

  def start_from_router(group_id, user_id, people, content, key) do
    case SystemsRuntime.get_env(:salix_im, :collaborations) do
      nil -> {:error, :collaborations_unavailable}
      module -> module.start_from_router(group_id, user_id, people, content, key)
    end
  end
end
