defmodule CommaWeb.Coding.GitAuthor do
  @moduledoc """
  Who a coding sandbox commits as (`config :salix_web, :coding_git_author`,
  `SalixWeb.CodingSandboxes`): the Comma user who owns the Task, by their
  account's name and email. A user with no name commits by their email's
  local part.
  """

  def identity(user_id) when is_binary(user_id) do
    with {:ok, %{"email" => email} = user} when is_binary(email) and email != "" <-
           Comma.Accounts.get_user(user_id) do
      name =
        case user["name"] do
          name when is_binary(name) and name != "" -> name
          _ -> email |> String.split("@") |> hd()
        end

      {:ok, %{name: name, email: email}}
    else
      _ -> {:error, :not_found}
    end
  end

  def identity(_user_id), do: {:error, :not_found}
end
