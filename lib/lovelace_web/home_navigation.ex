defmodule LovelaceWeb.HomeNavigation do
  @moduledoc "Local, account-scoped destinations shared by links and LiveView navigation."

  def workspace_path(id), do: "/workspaces/" <> segment(id)
  def account_path(id), do: "/accounts/" <> segment(id) <> "/mail"

  def connections_path(provider \\ :index)
  def connections_path(:index), do: "/connections"
  def connections_path(provider), do: "/connections/#{provider}"

  def mail_path(mail, changes \\ %{}) do
    mail = Map.merge(mail, changes)

    base =
      if mail.scope == :home,
        do: account_path(mail.account_id),
        else:
          workspace_path(mail.workspace_id) <> "/accounts/" <> segment(mail.account_id) <> "/mail"

    base = if mail.thread_id, do: base <> "/threads/" <> segment(mail.thread_id), else: base
    query(base, q: mail.query, page_token: mail.page_token)
  end

  def current(%{assigns: %{connections: true} = a}),
    do: connections_path(a.connection_view)

  def current(%{assigns: %{scenes: true, scene_page: page}}),
    do: query("/scenes", page: if(page > 1, do: page))

  def current(%{assigns: %{mail: %{account_id: id} = mail}}) when not is_nil(id),
    do: mail_path(mail)

  def current(%{assigns: %{selected: %{id: id}, mail: %{adding: true}}}),
    do: workspace_path(id) <> "/integrations"

  def current(%{assigns: %{selected: %{id: id}}}), do: workspace_path(id)
  def current(%{assigns: %{home: true}}), do: "/"
  def current(_socket), do: "/workspaces"

  # Accept old bookmarks, but never generate query-string navigation again.
  def destination(:index, %{"connections" => provider})
      when provider in ["gmail", "calendar", "gemini"],
      do: destination(:connection, %{"provider" => provider})

  def destination(:index, %{"calendar" => _}),
    do: destination(:connection, %{"provider" => "calendar"})

  def destination(:index, %{"workspace" => id}),
    do: destination(:workspace, %{"workspace_id" => id})

  def destination(:index, %{"gmail" => _}),
    do: destination(:connection, %{"provider" => "gmail"})

  def destination(action, params) do
    params = Map.take(params, keys(action))

    with {:ok, provider} <- provider(params),
         {:ok, page} <- page(params),
         {:ok, query} <- text(params["q"], 1024),
         {:ok, token} <- text(params["page_token"], 2048),
         {:ok, thread} <- thread(params["thread_id"]),
         {:ok, workspace} <- uuid(params["workspace_id"]),
         {:ok, account} <- uuid(params["account_id"]) do
      {:ok,
       %{
         action: action,
         provider: if(action == :connections, do: :index, else: provider),
         page: page,
         workspace_id: workspace,
         account_id: account,
         query: query,
         page_token: token,
         thread_id: thread
       }}
    end
  end

  defp keys(:connection), do: ["provider"]
  defp keys(:scenes), do: ["page"]
  defp keys(action) when action in [:workspace, :integration_add], do: ["workspace_id"]
  defp keys(:inbox), do: ["account_id", "q", "page_token"]
  defp keys(:thread), do: ["account_id", "thread_id", "q", "page_token"]
  defp keys(:workspace_inbox), do: ["workspace_id", "account_id", "q", "page_token"]
  defp keys(:workspace_thread), do: ["workspace_id", "account_id", "thread_id", "q", "page_token"]
  defp keys(_action), do: []

  defp provider(%{"provider" => provider}) when provider in ["gmail", "gemini", "calendar"],
    do:
      {:ok,
       Map.fetch!(%{"gmail" => :gmail, "gemini" => :gemini, "calendar" => :calendar}, provider)}

  defp provider(%{"provider" => _}), do: :error
  defp provider(_), do: {:ok, :gmail}

  defp page(%{"page" => page}) when is_binary(page) and byte_size(page) <= 8 do
    case Integer.parse(page) do
      {number, ""} when number > 0 and number <= 1_000_000 -> {:ok, number}
      _ -> :error
    end
  end

  defp page(%{"page" => _}), do: :error
  defp page(_), do: {:ok, 1}

  defp thread(nil), do: {:ok, nil}

  defp thread(value) when is_binary(value) do
    if byte_size(value) <= 128 && Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, value),
      do: {:ok, value},
      else: :error
  end

  defp thread(_), do: :error

  defp text(nil, _max), do: {:ok, nil}

  defp text(value, max) when is_binary(value) and byte_size(value) <= max * 4 do
    if String.valid?(value) && String.length(value) <= max &&
         !String.contains?(value, ["\u0000", "\r", "\n"]),
       do: {:ok, if(value == "", do: nil, else: value)},
       else: :error
  end

  defp text(_, _), do: :error
  defp uuid(nil), do: {:ok, nil}
  defp uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp uuid(_), do: :error

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp query(path, values) do
    case Enum.reject(values, fn {_key, value} -> is_nil(value) end) do
      [] -> path
      values -> path <> "?" <> URI.encode_query(values)
    end
  end
end
