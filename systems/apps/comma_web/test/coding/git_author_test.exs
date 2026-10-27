defmodule CommaWeb.Coding.GitAuthorTest do
  use ExUnit.Case, async: false

  alias CommaWeb.Coding.GitAuthor

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "a coding sandbox commits as the Task owner's name and email, or their email's local part" do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])

    {:ok, named} =
      Comma.Accounts.create_user(%{"email" => "ann-#{suffix}@example.com", "name" => "Ann Lee"})

    assert GitAuthor.identity(named["id"]) ==
             {:ok, %{name: "Ann Lee", email: "ann-#{suffix}@example.com"}}

    {:ok, unnamed} = Comma.Accounts.create_user(%{"email" => "bo-#{suffix}@example.com"})
    assert {:ok, %{name: "bo-" <> _}} = GitAuthor.identity(unnamed["id"])

    assert GitAuthor.identity("usr_unknown") == {:error, :not_found}
  end
end
