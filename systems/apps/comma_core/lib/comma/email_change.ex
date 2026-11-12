defmodule Comma.EmailChange do
  @moduledoc """
  A registered User changes the email they sign in with.

  Only the User's email changes. The User id stays, and with it the
  Workspaces, their Tasks and files, billing, Auth Sessions and Login
  Identities (Google and Apple match the provider's subject, not the email).

  Self-service needs both mailboxes, one code each:

    1. `request_current_code/2` mails a code to the account email.
    2. `request_new_code/2` checks that code and mails a code to the new email.
    3. `confirm/2` checks the new email's code and changes the email.

  A person who cannot read the account mailbox any more asks support. An
  operator changes the email in Comma Admin (`change/2`) after checking who
  they are.

  The new email must not belong to another account. Its owner can delete that
  account first (`Comma.AccountDeletion`), which frees the email when the
  seven days of the deletion are over; until then the change is refused with
  the deletion time. Accounts with a review login code keep their email.

  The email an account gives up gets no registration credits on a new account
  (`released_email?/1`), as after a deletion.
  """

  import Ecto.Query

  alias Comma.Accounts.{Email, Repository, User}
  alias Comma.{Accounts, AuthChallenges, Repo}

  @doc "Mails the signed-in User's account email the code that starts the change."
  def request_current_code(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with {:ok, user} <- changeable_user(user_id) do
      AuthChallenges.request_email_change("email_change_current", user.email, user_id, %{}, attrs)
    end
  end

  @doc """
  Checks the account email's code (`challenge_id`, `code`) and mails a code to
  the new `email`. The new email's challenge remembers the account email it
  replaces, so a change made meanwhile voids it.
  """
  def request_new_code(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    # The code is checked before the new email's owner is looked up, so a
    # signed-in User cannot probe which emails have accounts without codes.
    with {:ok, user} <- changeable_user(user_id),
         {:ok, email} <- valid_email(user, attrs["email"]),
         {:ok, current} <-
           AuthChallenges.verify_email_change("email_change_current", user_id, attrs),
         :ok <- still_current(current, user),
         :ok <- free(email) do
      AuthChallenges.request_email_change(
        "email_change_new",
        email,
        user_id,
        %{"replaces" => user.email},
        attrs
      )
    end
  end

  @doc "Checks the new email's code (`challenge_id`, `code`) and changes the email."
  def confirm(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with {:ok, _user} <- changeable_user(user_id),
         {:ok, challenge} <-
           AuthChallenges.verify_email_change("email_change_new", user_id, attrs) do
      apply_change(user_id, challenge["email"], challenge["replaces"])
    end
  end

  @doc "An operator changes a User's email (Comma Admin). No code is asked."
  def change(user_id, email) when is_binary(user_id) do
    with {:ok, user} <- changeable_user(user_id),
         {:ok, email} <- new_email(user, email) do
      apply_change(user_id, email, user.email)
    else
      {:error, {:email_pending_deletion, _scheduled_at}} -> {:error, :email_pending_deletion}
      {:error, _reason} = error -> error
    end
  end

  @doc "Whether an account gave up this email before."
  def released_email?(email) when is_binary(email) do
    case Comma.AccountDeletion.email_hash(email) do
      {:ok, hash} ->
        Repo.exists?(from(r in "comma_released_emails", where: r.email_hash == ^hash))

      {:error, _reason} ->
        false
    end
  end

  defp changeable_user(user_id) do
    case Repository.get_user(user_id) do
      {:ok, %User{kind: "registered", status: "active", review_login_code_hash: nil} = user} ->
        {:ok, user}

      {:ok, %User{}} ->
        {:error, :forbidden}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp new_email(user, email) do
    with {:ok, normalized} <- valid_email(user, email),
         :ok <- free(normalized) do
      {:ok, normalized}
    end
  end

  defp valid_email(%User{email: current}, email) do
    case Email.normalize_recipient(email) do
      {:ok, ^current} -> {:error, :same_email}
      {:ok, normalized} -> {:ok, normalized}
      {:error, :invalid_email} -> {:error, :invalid_email}
    end
  end

  # A code mailed before support changed the email does not start a change.
  defp still_current(%{"email" => email}, %User{email: email}), do: :ok
  defp still_current(_challenge, _user), do: {:error, :email_changed}

  defp free(email) do
    case Repo.one(from(u in User, where: u.email == ^email, select: u.deletion_scheduled_at)) do
      nil ->
        if Repo.exists?(from(u in User, where: u.email == ^email)),
          do: {:error, :email_taken},
          else: :ok

      %DateTime{} = scheduled_at ->
        {:error, {:email_pending_deletion, scheduled_at}}
    end
  end

  defp apply_change(user_id, email, replaces) do
    case Comma.AccountDeletion.email_hash(replaces) do
      {:ok, released} -> apply_change(user_id, email, replaces, released)
      {:error, _reason} -> {:error, :auth_unavailable}
    end
  end

  defp apply_change(user_id, email, replaces, released) do
    Repo.transaction(fn ->
      user = Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"))

      cond do
        not match?(%User{kind: "registered", status: "active", review_login_code_hash: nil}, user) ->
          Repo.rollback(:forbidden)

        user.email != replaces ->
          Repo.rollback(:email_changed)

        true ->
          :ok = Comma.Billing.SignupCredits.reserve_gmail_history([replaces, email])

          case Comma.Auth.Abuse.retire_email(replaces) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          case user |> User.changeset(%{email: email}) |> Repo.update() do
            {:ok, updated} ->
              Repo.insert_all(
                "comma_released_emails",
                [
                  %{email_hash: released, released_at: SystemsClock.timestamp(:utc_datetime_usec)}
                ],
                on_conflict: :nothing
              )

              Accounts.public_user(updated)

            {:error, %Ecto.Changeset{errors: [email: _]}} ->
              Repo.rollback(:email_taken)

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, user} ->
        Comma.Analytics.identify(user_id)
        {:ok, user}

      {:error, _reason} = error ->
        error
    end
  end
end
