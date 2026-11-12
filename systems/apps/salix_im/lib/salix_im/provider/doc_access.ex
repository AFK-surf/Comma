defmodule SalixIM.Provider.DocAccess do
  @moduledoc """
  The next step after Feishu or Lark refuses a document, spreadsheet or Base
  call, for the identity that made it. `SalixIM.Provider.Feishu` and
  `SalixIM.Provider.Lark` add it to the provider's own error text.

  The steps follow one order. Read or write as the app. When the app is
  refused, use the signed-in account of the person who asked; a write as
  that person needs their agreement first, because the edit history shows
  them as the author. When that person has no account, or it expired, ask
  them to sign in. A table read or a write as a person needs user scopes the
  default sign-in does not ask for; the step names them (`on_demand_scopes/0`
  of the OAuth adapters), and a sign-in that asks for them keeps the default
  ones. When their account is refused too, offer to ask the owner for access
  as them. A scope the app does not offer is fixed only by a tenant admin,
  never by sharing the document.
  """

  # Refusals of a document, wiki node, spreadsheet or Base to the identity
  # that asked: 131006 wiki or sheet node, 3380002 docs_ai, 1254302 Base
  # role, 91403 spreadsheet, and the Drive and Docx permission codes.
  @denied_codes ~w(131006 3380002 1254302 91403 2889902 1770032 1063002)
  @app_scope_code "99991672"
  @user_scope_code "99991679"

  @document_reads ~w(fetch_doc list_doc_comments fetch_doc_media)
  @table_reads ~w(get_base list_base_fields list_base_records get_sheet get_sheet_range)
  @writes ~w(update_doc insert_doc_media add_doc_comment reply_doc_comment
             resolve_doc_comment)

  @doc """
  The result of `api`, with the next step added to a refusal. `connect` is
  the connect the call ran with: one that carries a `user_access_token` acted
  as a person. Other results and other operations pass through unchanged.
  """
  @spec next_step(term(), String.t(), map()) :: term()
  def next_step({:error, reason}, api, connect) when is_binary(reason) do
    with [prefix, name] <- String.split(api, ".", parts: 2),
         action when not is_nil(action) <- action(name),
         step when is_binary(step) <- step(code(reason), reason, prefix, action, person?(connect)) do
      {:error, reason <> step}
    else
      _none -> {:error, reason}
    end
  end

  def next_step(result, _api, _connect), do: result

  defp action(name) when name in @document_reads, do: :read
  defp action(name) when name in @table_reads, do: :table_read
  defp action(name) when name in @writes, do: :write
  defp action(_name), do: nil

  defp person?(%{"user_access_token" => token}), do: is_binary(token) and token != ""
  defp person?(_connect), do: false

  defp code(reason) do
    case Regex.run(~r/\berror (\d+)\b/, reason) do
      [_, code] -> code
      nil -> nil
    end
  end

  defp step(@app_scope_code, reason, prefix, action, _person?) do
    " Next: the app lacks the #{product(prefix)} scope #{scopes(reason)}. Only a tenant admin can fix this: enable it in the #{product(prefix)} developer console and publish a new app version. Sharing the document does not help. Until then, " <>
      as_person(prefix, action)
  end

  defp step(@user_scope_code, reason, prefix, _action, _person?) do
    " Next: this person's sign-in lacks the #{product(prefix)} scope #{scopes(reason)}. Call oauth.request_authorization with provider #{prefix}, their alias and scopes [#{grant(reason, prefix)}], and continue when it completes. If the authorization page refuses it (error 20027), a tenant admin must enable these as user scopes in the #{product(prefix)} developer console and publish a new app version. Sharing the document does not help."
  end

  defp step(code, _reason, prefix, action, false) when code in @denied_codes,
    do: " Next: the app may not #{verb(action)} it. " <> as_person(prefix, action)

  defp step(code, _reason, prefix, action, true)
       when code in @denied_codes and action in [:read, :table_read],
       do:
         " Next: this person cannot open it either. Offer to ask the owner for access as them with #{prefix}.request_doc_access, and call it only after they agree."

  defp step(code, _reason, prefix, :write, true) when code in @denied_codes,
    do:
      " Next: this person cannot edit it either. Offer to ask the owner for edit access as them with #{prefix}.request_doc_access and perm edit, and call it only after they agree."

  defp step(_code, _reason, _prefix, _action, _person?), do: nil

  defp as_person(prefix, :read),
    do:
      "read it again with account=<the signed-in account of the person who asked> (#{prefix}.list_accounts). If they have none or it is expired, call oauth.request_authorization with provider #{prefix} and continue when it completes."

  defp as_person(prefix, :table_read),
    do:
      "read it again with account=<the signed-in account of the person who asked> (#{prefix}.list_accounts). If they have none, it is expired, or their sign-in lacks the table scopes, call oauth.request_authorization with provider #{prefix}, their alias (or a new one) and scopes [#{on_demand(prefix, "tables")}], and read as them when it completes."

  defp as_person(prefix, :write),
    do:
      "ask the person who asked whether you may write it as them: the edit history will show them as the author. Only after they agree, write it again with account=<their signed-in account> (#{prefix}.list_accounts). If they have none, it is expired, or their sign-in lacks the write scopes, call oauth.request_authorization with provider #{prefix}, their alias (or a new one) and scopes [#{on_demand(prefix, "document_writes")}], and write as them when it completes."

  defp verb(:write), do: "edit"
  defp verb(_read), do: "open"

  # The user scopes a need asks for beyond the default sign-in, as the
  # provider's sign-in names them.
  defp on_demand(prefix, need), do: Enum.join(adapter(prefix).on_demand_scopes()[need], ", ")

  defp adapter("lark"), do: SalixStore.OAuth.Adapters.Lark
  defp adapter(_feishu), do: SalixStore.OAuth.Adapters.Feishu

  defp product("lark"), do: "Lark"
  defp product(_feishu), do: "Feishu"

  # The scopes a refusal names, `[a, b]` in Feishu's and Lark's text: any
  # one of them is enough.
  defp named_scopes(reason) do
    case Regex.run(~r/\[([\w:.\-]+(?:,\s*[\w:.\-]+)*)\]/, reason) do
      [_, list] -> String.split(list, ~r/,\s*/, trim: true)
      nil -> []
    end
  end

  defp scopes(reason) do
    case named_scopes(reason) do
      [] -> "it names"
      named -> Enum.join(named, ", ")
    end
  end

  # What a new sign-in asks for: the on-demand scopes among those named, so
  # the sign-in adds them to the default one; else every scope named.
  defp grant(reason, prefix) do
    named = named_scopes(reason)
    on_demand = adapter(prefix).on_demand_scopes() |> Map.values() |> List.flatten()

    case Enum.filter(named, &(&1 in on_demand)) do
      [] when named == [] -> "the scopes the error names"
      [] -> Enum.join(named, ", ")
      wanted -> Enum.join(wanted, ", ")
    end
  end
end
