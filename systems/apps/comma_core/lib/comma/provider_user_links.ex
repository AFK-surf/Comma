defmodule Comma.ProviderUserLinks do
  @moduledoc """
  Which Comma account a chat app's user is: a Slack user of one connect (or a
  user of another provider's connect), linked to one Comma User.

  A Router serving that chat user asks for a link when it needs their account
  (`start/4`, from the user's server-sealed principal, never from the model).
  The link token is posted to them in the chat; whoever opens it signed in to
  Comma and confirms becomes the linked account (`accept/3`), replacing any
  earlier link of that chat user. A pending link expires after an hour. The
  person sees and removes their links in Settings. Account deletion removes
  them. See `docs/architecture/DOMAIN_CONCEPTS.md` (Task Request).
  """

  import Ecto.Query

  alias Comma.Data.ProviderUserLink
  alias Comma.Repo

  @link_ttl_seconds 3600
  @token_bytes 32
  @token_pattern ~r/\A[A-Za-z0-9_-]{43}\z/
  @list_limit 50

  @doc "The Comma User a chat user is linked to, or `:none`."
  def resolve(connect_id, subject_id) when is_binary(connect_id) and is_binary(subject_id) do
    case Repo.one(
           from(l in ProviderUserLink,
             where:
               l.connect_id == ^connect_id and l.subject_id == ^subject_id and
                 l.status == "active",
             select: l.user_id
           )
         ) do
      user_id when is_binary(user_id) -> {:ok, user_id}
      nil -> :none
    end
  end

  @doc """
  A pending link for a chat user who has none yet (`token`, `id`,
  `expires_at` in Unix seconds): a pending one still valid is given again, so
  asking twice posts the same link. `about`: what the chat app says of them,
  `"email"`, `"workspace"` (its workspace's or tenant's name, else the
  organization's) and `"bot"` (the connect's), shown with the link.
  """
  def start(provider, connect_id, subject_id, subject_name, about \\ %{})
      when is_binary(provider) and is_binary(connect_id) and is_binary(subject_id) do
    now = now()

    pending =
      Repo.one(
        from(l in ProviderUserLink,
          where:
            l.connect_id == ^connect_id and l.subject_id == ^subject_id and
              l.status == "pending" and l.link_expires_at > ^now,
          order_by: [desc: l.inserted_at],
          limit: 1
        )
      )

    case pending do
      %ProviderUserLink{} = link ->
        {:ok, pending_view(link)}

      nil ->
        %ProviderUserLink{
          id: new_id(),
          provider: provider,
          connect_id: connect_id,
          subject_id: subject_id,
          subject_name: short(subject_name),
          subject_email: short(about["email"]),
          subject_workspace: short(about["workspace"]),
          subject_bot: short(about["bot"]),
          status: "pending",
          link_token: new_token(),
          link_expires_at: DateTime.add(now, @link_ttl_seconds, :second)
        }
        |> Repo.insert()
        |> case do
          {:ok, link} -> {:ok, pending_view(link)}
          {:error, _changeset} -> {:error, :provider_links_unavailable}
        end
    end
  end

  @doc "Whether the chat user's active link does not say yet which account it is (its name, email, workspace or bot)."
  def unknown_account?(connect_id, subject_id)
      when is_binary(connect_id) and is_binary(subject_id) do
    Repo.exists?(
      from(l in ProviderUserLink,
        where:
          l.connect_id == ^connect_id and l.subject_id == ^subject_id and l.status == "active" and
            (is_nil(l.subject_name) or is_nil(l.subject_email) or
               is_nil(l.subject_workspace) or is_nil(l.subject_bot))
      )
    )
  end

  @doc "Fills in what the chat user's active link does not say yet of its account (`about` as in `start/5`)."
  def remember(connect_id, subject_id, about) when is_map(about) do
    [
      subject_name: "name",
      subject_email: "email",
      subject_workspace: "workspace",
      subject_bot: "bot"
    ]
    |> Enum.each(fn {field, key} ->
      case short(about[key]) do
        nil ->
          :ok

        value ->
          from(l in ProviderUserLink,
            where:
              l.connect_id == ^connect_id and l.subject_id == ^subject_id and
                l.status == "active" and is_nil(field(l, ^field))
          )
          |> Repo.update_all(set: [{field, value}, updated_at: now()])
      end
    end)

    :ok
  end

  @doc """
  Records an Agent tool call that waits for a pending link (its capability
  request: `tenant_id`, `group_id`, `request_id`); linking ends every wait.
  The same chat user can wait in several conversations at once, all on the
  one link.
  """
  def await(link_id, waiting) when is_binary(link_id) and is_map(waiting) do
    from(l in ProviderUserLink, where: l.id == ^link_id and l.status == "pending")
    |> Repo.update_all(push: [waiting_requests: waiting], set: [updated_at: now()])
    |> case do
      {1, _} ->
        :ok

      # Linked between the call finding no link and recording its wait: the
      # wait is over already.
      {0, _} ->
        case Repo.get(ProviderUserLink, link_id) do
          %ProviderUserLink{status: "active"} -> end_wait(waiting)
          _expired_or_gone -> :ok
        end
    end
  end

  @doc "What a link would make, for the person about to confirm it."
  def preview(_user, session, token) do
    with :ok <- full_session(session),
         {:ok, link} <- open_link(token) do
      {:ok,
       %{
         "provider" => link.provider,
         "name" => link.subject_name,
         "email" => link.subject_email,
         "workspace" => link.subject_workspace,
         "bot" => link.subject_bot
       }}
    end
  end

  @doc """
  Links the chat user of a pending link to the signed-in User. An earlier link
  of that chat user ends.
  """
  def accept(user, session, token) do
    with :ok <- full_session(session),
         {:ok, link} <- open_link(token) do
      now = now()

      Repo.transaction(fn ->
        from(l in ProviderUserLink,
          where:
            l.connect_id == ^link.connect_id and l.subject_id == ^link.subject_id and
              l.id != ^link.id
        )
        |> Repo.delete_all()

        # What waits is read as the link turns active (RETURNING gives the
        # row as updated, so the waits stay on it): a wait recorded up to
        # that moment is ended too, and none can be recorded after it.
        from(l in ProviderUserLink,
          where: l.id == ^link.id and l.status == "pending",
          select: l.waiting_requests
        )
        |> Repo.update_all(
          set: [
            status: "active",
            user_id: user["id"],
            link_token: nil,
            linked_at: now,
            updated_at: now
          ]
        )
        |> case do
          {1, [_]} = updated -> updated
          {0, _} -> Repo.rollback(:not_found)
        end
      end)
      |> case do
        {:ok, {1, [waiting]}} ->
          Enum.each(waiting, &end_wait/1)
          {:ok, view(Repo.get!(ProviderUserLink, link.id))}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Each Agent that posted the link goes on with the person's request.
  defp end_wait(%{"tenant_id" => tenant, "group_id" => group, "request_id" => request})
       when is_binary(tenant) and is_binary(group) and is_binary(request) do
    case SalixAgent.CapabilityRequests.complete_account_link(group, request, tenant) do
      {:ok, _completed} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp end_wait(_waiting), do: :ok

  defp pending_view(%ProviderUserLink{} = link),
    do: %{"id" => link.id, "token" => link.link_token, "expires_at" => unix(link.link_expires_at)}

  @doc "The signed-in User's chat accounts."
  def list(user, session) do
    with :ok <- full_session(session) do
      {:ok,
       from(l in ProviderUserLink,
         where: l.user_id == ^user["id"] and l.status == "active",
         order_by: [desc: l.linked_at, desc: l.id],
         limit: @list_limit
       )
       |> Repo.all()
       |> Enum.map(&view/1)}
    end
  end

  @doc "Removes one of the signed-in User's links."
  def remove(user, session, link_id) do
    with :ok <- full_session(session) do
      case from(l in ProviderUserLink,
             where: l.id == ^to_string(link_id) and l.user_id == ^user["id"]
           )
           |> Repo.delete_all() do
        {1, _} -> :ok
        {0, _} -> {:error, :not_found}
      end
    end
  end

  @doc "Whether a string has the shape of a link token. Grants nothing."
  def valid_token?(token) when is_binary(token), do: Regex.match?(@token_pattern, token)
  def valid_token?(_token), do: false

  defp open_link(token) do
    now = now()

    with true <- valid_token?(token),
         %ProviderUserLink{status: "pending"} = link <-
           Repo.get_by(ProviderUserLink, link_token: token),
         :gt <- DateTime.compare(link.link_expires_at, now) do
      {:ok, link}
    else
      _ -> {:error, :not_found}
    end
  end

  defp view(%ProviderUserLink{} = link),
    do: %{
      "id" => link.id,
      "provider" => link.provider,
      "name" => link.subject_name,
      "email" => link.subject_email,
      "workspace" => link.subject_workspace,
      "bot" => link.subject_bot,
      "linked_at" => unix(link.linked_at)
    }

  defp full_session(%{"restricted" => true}), do: {:error, :forbidden}
  defp full_session(_session), do: :ok

  defp short(name) when is_binary(name) and name != "", do: String.slice(name, 0, 200)
  defp short(_name), do: nil

  defp new_id,
    do: "pul_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

  defp new_token,
    do: @token_bytes |> SystemsRuntime.Proc.random_bytes() |> Base.url_encode64(padding: false)

  defp now, do: SystemsClock.utc_now()

  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)
  defp unix(_value), do: nil
end
