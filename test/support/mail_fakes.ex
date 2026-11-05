defmodule Lovelace.TestMail do
  @moduledoc false
  def start do
    Agent.start_link(
      fn ->
        %{vault: %{}, calls: [], response: :ok, unread_response: {:ok, %{total: 7, recent: 2}}}
      end,
      name: __MODULE__
    )
  end

  def record(call),
    do: Agent.update(__MODULE__, &Map.update!(&1, :calls, fn calls -> [call | calls] end))

  def calls, do: Agent.get(__MODULE__, & &1.calls)
  def response(value), do: Agent.update(__MODULE__, &Map.put(&1, :response, value))
  def result, do: Agent.get(__MODULE__, & &1.response)
  def unread_response(value), do: Agent.update(__MODULE__, &Map.put(&1, :unread_response, value))
  def unread_result, do: Agent.get(__MODULE__, & &1.unread_response)
end

defmodule Lovelace.TestMailVault do
  @moduledoc false
  def get(id),
    do:
      Agent.get(Lovelace.TestMail, fn s ->
        case s.vault[id] do
          nil -> {:error, :not_found}
          value -> {:ok, value}
        end
      end)

  def put(id, value), do: Agent.update(Lovelace.TestMail, &put_in(&1, [:vault, id], value))

  def delete(id),
    do:
      Agent.update(
        Lovelace.TestMail,
        &Map.update!(&1, :vault, fn vault -> Map.delete(vault, id) end)
      )
end

defmodule Lovelace.TestMailReadDenied do
  @moduledoc false
  def get(_id), do: {:error, :locked}
  def put(_id, _token), do: raise("must not overwrite an unreadable credential")
  def delete(_id), do: raise("must not delete an unreadable credential")
end

defmodule Lovelace.TestMailDeleteFailure do
  @moduledoc false
  defdelegate get(id), to: Lovelace.TestMailVault
  defdelegate put(id, token), to: Lovelace.TestMailVault
  def delete(_id), do: raise("synthetic vault failure")
end

defmodule Lovelace.TestGoogle do
  @moduledoc false
  def refresh(token) do
    Lovelace.TestMail.record({:refresh, token})

    case Lovelace.TestMail.result() do
      :ok ->
        {:ok, %{access_token: "access:" <> token}}

      {:wait_thread, _} ->
        {:ok, %{access_token: "access:" <> token}}

      {:wait_attachment, _} ->
        {:ok, %{access_token: "access:" <> token}}

      {:wait, pid} ->
        send(pid, {:provider_waiting, self()})

        receive do
          :continue -> {:ok, %{access_token: "access:" <> token}}
        end

      error ->
        error
    end
  end

  def inbox_unread(token) do
    Lovelace.TestMail.record({:inbox_unread, token})

    case Lovelace.TestMail.unread_result() do
      {:raise, message} ->
        raise message

      {:throw, value} ->
        throw(value)

      {:wait, pid, result} ->
        send(pid, {:unread_waiting, self()})

        receive do
          :continue -> result
        end

      result ->
        result
    end
  end

  def inbox(token, page), do: search(token, "in:inbox", page)

  def search(token, query, page) do
    Lovelace.TestMail.record({:page, token, query, page})

    {:ok,
     %{
       threads: [
         %{
           id: "same-id",
           subject: token,
           from: "sender@example.invalid",
           snippet: "synthetic",
           unread: true,
           date: "today"
         }
       ],
       next_page_token: if(page, do: nil, else: "second")
     }}
  end

  def thread(token, id) do
    case Lovelace.TestMail.result() do
      {:wait_thread, pid} ->
        send(pid, {:thread_waiting, self()})

        receive do
          :continue -> :ok
        end

      _ ->
        :ok
    end

    {:ok,
     %{
       id: id,
       messages: [
         %{
           id: "message",
           from: "sender@example.invalid",
           to: "owner@example.invalid",
           date: "today",
           subject: token,
           text: "<script>synthetic</script>",
           attachments: [
             %{
               attachment_id: "part-a",
               filename: "note.txt",
               mime_type: "text/plain",
               size: 14
             }
           ]
         }
       ]
     }}
  end

  def attachment(token, message_id, attachment_id) do
    Lovelace.TestMail.record({:attachment, token, message_id, attachment_id})

    case Lovelace.TestMail.result() do
      {:wait_attachment, pid} ->
        send(pid, {:attachment_waiting, self()})

        receive do
          :continue -> {:ok, "synthetic file"}
        end

      _ ->
        {:ok, "synthetic file"}
    end
  end

  def revoke(token) do
    Lovelace.TestMail.record({:revoke, token})
    :ok
  end

  def authorization_url(%{state: state}),
    do:
      {:ok, "https://accounts.google.com/o/oauth2/v2/auth?" <> URI.encode_query(%{state: state})}

  def exchange_code("fake-code", _verifier, _redirect),
    do: {:ok, %{access_token: "new-access", refresh_token: "new-refresh"}}

  def exchange_code(_, _, _), do: {:error, :provider}
  def identity("new-access"), do: {:ok, %{subject: "new-subject", email: "new@example.invalid"}}
end
