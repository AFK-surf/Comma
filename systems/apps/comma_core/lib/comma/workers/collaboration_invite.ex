defmodule Comma.Workers.CollaborationInvite do
  @moduledoc """
  The email that tells someone a host invited them to a Task together
  (`Comma.Collaborations`): to a person on Comma at their account's address
  (linking to Comma's Inbox), or to an external email guest at that address
  (linking directly to `<web_origin>/c/<invite_token>`). One email per seat
  (`unique`), or one per manual host resend (`enqueue_resend/2` keyed by the
  rotated token).
  """
  use Oban.Worker,
    queue: :comma_notifications,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args]]

  require Logger

  alias Comma.Data.TaskCollaborator
  alias Comma.Repo

  @doc "Queues the initial email of each seat id."
  def enqueue(ids) when is_list(ids) do
    Enum.each(ids, fn id ->
      case %{"collaborator_id" => id} |> new() |> then(&Oban.insert(Comma.Oban, &1)) do
        {:ok, _job} -> :ok
        {:error, reason} -> Logger.warning("invite email not queued reason=#{inspect(reason)}")
      end
    end)
  end

  @doc "Queues a manual host resend for an external email seat's rotated token."
  def enqueue_resend(id, token) when is_binary(id) and is_binary(token) do
    case %{"collaborator_id" => id, "token" => token}
         |> new()
         |> then(&Oban.insert(Comma.Oban, &1)) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("invite resend email not queued reason=#{inspect(reason)}")
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"collaborator_id" => id} = args}) do
    adapter = Comma.EmailDelivery.impl()
    expected_token = args["token"]

    with %TaskCollaborator{} = row <- Repo.get(TaskCollaborator, id),
         true <- eligible_row?(row, expected_token),
         {:ok, host} <- Comma.Accounts.get_user(row.host_user_id),
         email when is_binary(email) and email != "" <- address(row),
         false <- Comma.GuestMode.guest_email?(email),
         true <- function_exported?(adapter, :send_notice, 4) do
      # One line: a name is never a mail header's line break.
      host_name =
        if(host["name"] in [nil, ""], do: host["email"], else: host["name"])
        |> String.replace(~r/[\r\n]+/, " ")

      {hint, action, url} = invite_copy_and_url(row, email)

      notice =
        Comma.EmailDelivery.invitation(%{
          host: %{name: host_name, email: host["email"]},
          task_title: row.title,
          body:
            "Work on the task below together in Comma. A Comma Worker does the work for you both.",
          hint: hint,
          action: action,
          url: url
        })

      case adapter.send_notice(email, notice.subject, notice.text, notice.html) do
        :ok -> :ok
        {:error, :recipient_rejected} -> {:cancel, :recipient_rejected}
        {:error, reason} -> {:error, reason}
      end
    else
      # The seat was answered, rotated, or taken out, or nothing can send it: no email.
      _ -> :ok
    end
  end

  defp eligible_row?(
         %TaskCollaborator{status: status, invite_token: token, user_id: nil},
         expected
       )
       when is_binary(expected) do
    status in ["invited", "active"] and token == expected
  end

  defp eligible_row?(%TaskCollaborator{status: "invited"}, nil), do: true
  defp eligible_row?(_row, _expected), do: false

  defp invite_copy_and_url(%TaskCollaborator{user_id: nil, invite_token: token}, email)
       when is_binary(token) and token != "" do
    {
      "Verify #{email} to open this shared task in your browser — no account required. Link expires in 7 days.",
      "Open shared task",
      guest_invite_url(token)
    }
  end

  defp invite_copy_and_url(%TaskCollaborator{user_id: nil}, email) do
    {
      "Sign up to Comma with #{email}, then join it from your Inbox.",
      "View invitation",
      inbox_url()
    }
  end

  defp invite_copy_and_url(_row, _email) do
    {
      "Join or decline it in your Comma Inbox.",
      "View invitation",
      inbox_url()
    }
  end

  defp address(%TaskCollaborator{user_id: nil, invited_email: email}), do: email

  defp address(%TaskCollaborator{user_id: id}) do
    case Comma.Accounts.get_user(id) do
      {:ok, user} -> user["email"]
      _ -> nil
    end
  end

  defp web_origin,
    do: String.trim_trailing(SystemsRuntime.fetch_env!(:comma_web, :web_cookie_origin), "/")

  defp inbox_url, do: web_origin() <> "/inbox"
  defp guest_invite_url(token), do: web_origin() <> "/c/" <> token
end
