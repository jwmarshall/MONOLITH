defmodule Monolith.MailCacheLimitsTest.Provider do
  @moduledoc false

  def start do
    Agent.start_link(fn -> %{payload: %{}, calls: []} end, name: __MODULE__)
  end

  def payload(payload), do: Agent.update(__MODULE__, &Map.put(&1, :payload, payload))
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))

  @spec refresh(binary()) :: {:ok, Monolith.Google.OAuthProvider.tokens()}
  def refresh(token) do
    record({:refresh, token})
    {:ok, %{access_token: "synthetic-access", expires_in: 3600}}
  end

  @spec thread(binary(), binary()) :: {:ok, Monolith.Mail.Provider.thread()}
  def thread(_token, id) do
    record({:thread, id})
    {:ok, Agent.get(__MODULE__, & &1.payload)}
  end

  defp record(call),
    do: Agent.update(__MODULE__, &Map.update!(&1, :calls, fn calls -> [call | calls] end))
end

defmodule Monolith.MailCacheLimitsTest do
  use Monolith.DataCase, async: false
  use Oban.Testing, repo: Monolith.Repo, engine: Oban.Engines.Lite

  alias Monolith.Google.Access
  alias Monolith.Mail
  alias Monolith.Mail.CacheEntry
  alias Monolith.MailCacheLimitsTest.Provider

  @owner %{role: :local_owner}
  @entry_limit 5 * 1024 * 1024
  @account_limit 25 * 1024 * 1024
  @moduletag timeout: 120_000

  setup do
    {:ok, _} = Monolith.TestMail.start()
    {:ok, _} = Provider.start()
    previous = Keyword.take(Application.get_all_env(:monolith), [:gmail_provider, :gmail_vault])
    Application.put_env(:monolith, :gmail_provider, Provider)
    Application.put_env(:monolith, :gmail_vault, Monolith.TestMailVault)

    on_exit(fn ->
      for key <- [:gmail_provider, :gmail_vault] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:monolith, key, value)
          :error -> Application.delete_env(:monolith, key)
        end
      end
    end)

    workspace = Monolith.Workspaces.create_workspace!("Cache budget fixture", actor: @owner)

    accounts =
      for subject <- ["cache-a", "cache-b"] do
        {:ok, account} =
          Access.accept(
            workspace.id,
            %{subject: subject, email: "#{subject}@example.invalid"},
            "synthetic-#{subject}"
          )

        account
      end

    [a, b] = accounts
    %{workspace: workspace, a: a, b: b}
  end

  test "real action publication stores exact JSON bytes and exactly seven days of retention", %{
    workspace: workspace,
    a: a
  } do
    payload = thread_payload("retention", 4096)
    Provider.payload(payload)

    assert {:ok, %{error: nil, cached: false, data: data, fetched_at: fetched_at}} =
             Mail.thread(workspace.id, a.id, "retention", actor: @owner)

    assert data == payload
    assert [entry] = entries(a)
    assert entry.bytes == byte_size(Jason.encode!(data))
    assert entry.payload == data
    assert entry.fetched_at == fetched_at
    assert DateTime.diff(entry.expires_at, entry.fetched_at, :microsecond) == 604_800_000_000
    assert entry.generation == a.generation
    assert [{:refresh, "synthetic-cache-a"}, {:thread, "retention"}] = Provider.calls()
  end

  test "five MiB JSON is accepted but even one byte over is never persisted", %{
    workspace: workspace,
    a: a
  } do
    Provider.payload(thread_payload("boundary", @entry_limit))

    assert {:ok, %{error: nil, data: data}} =
             Mail.thread(workspace.id, a.id, "boundary", actor: @owner)

    assert byte_size(Jason.encode!(data)) == @entry_limit
    assert [entry] = entries(a)
    assert entry.bytes == @entry_limit

    oversized = thread_payload("oversized", @entry_limit + 1)
    assert byte_size(Jason.encode!(oversized)) == @entry_limit + 1
    Provider.payload(oversized)

    assert {:ok, %{data: nil, error: :provider}} =
             Mail.thread(workspace.id, a.id, "oversized", actor: @owner)

    assert [retained] = entries(a)
    assert retained.id == entry.id
    assert retained.payload == entry.payload
    assert {:thread, "oversized"} in Provider.calls()

    # Rejected forced replacement must not overwrite a valid cached response either.
    assert {:ok, %{error: :provider, stale: true, data: stale}} =
             Mail.thread(workspace.id, a.id, "boundary", %{force: true}, actor: @owner)

    assert byte_size(Jason.encode!(stale)) == @entry_limit
    assert [retained] = entries(a)
    assert retained.id == entry.id
    assert retained.bytes == @entry_limit
    assert retained.fetched_at == entry.fetched_at
  end

  test "actual JSON byte budget evicts the oldest below 120 entries and preserves another account",
       %{
         workspace: workspace,
         a: a,
         b: b
       } do
    Provider.payload(thread_payload("other-account", 8192))
    assert {:ok, %{error: nil}} = Mail.thread(workspace.id, b.id, "other-account", actor: @owner)
    assert [other_before] = entries(b)
    response_bytes = div(9 * 1024 * 1024, 2)

    for index <- 1..6 do
      id = "large-#{index}"
      payload = thread_payload(id, response_bytes)
      assert byte_size(Jason.encode!(payload)) == response_bytes
      assert response_bytes <= @entry_limit
      Provider.payload(payload)

      assert {:ok, %{error: nil, cached: false, data: data}} =
               Mail.thread(workspace.id, a.id, id, actor: @owner)

      assert byte_size(Jason.encode!(data)) == response_bytes
    end

    retained = entries(a)
    assert length(retained) == 5
    assert length(retained) < 120

    assert MapSet.new(Enum.map(retained, & &1.key)) ==
             MapSet.new(for index <- 2..6, do: "thread:large-#{index}")

    actual_bytes = Enum.map(retained, &byte_size(Jason.encode!(&1.payload)))
    assert Enum.map(retained, & &1.bytes) == actual_bytes
    assert Enum.sum(actual_bytes) == 5 * response_bytes
    assert Enum.sum(actual_bytes) <= @account_limit
    assert 6 * response_bytes > @account_limit
    assert [other_after] = entries(b)
    assert other_after == other_before
    assert other_after.bytes == byte_size(Jason.encode!(other_after.payload))
    assert Enum.count(Provider.calls(), &match?({:thread, _}, &1)) == 7
  end

  defp thread_payload(id, target_bytes) do
    payload = %{
      "id" => id,
      "messages" => [
        %{
          "id" => "synthetic-message",
          "from" => "sender@example.invalid",
          "to" => "owner@example.invalid",
          "date" => "2026-01-01",
          "subject" => "Synthetic retention fixture",
          "text" => ""
        }
      ]
    }

    padding = target_bytes - byte_size(Jason.encode!(payload))
    phrase = "Synthetic body. "

    text =
      String.duplicate(phrase, div(padding, byte_size(phrase))) <>
        String.duplicate("x", rem(padding, byte_size(phrase)))

    put_in(payload, ["messages", Elixir.Access.at(0), "text"], text)
  end

  defp entries(account),
    do:
      CacheEntry
      |> Ash.Query.for_read(:read, %{account_id: account.id}, actor: @owner)
      |> Ash.read!()
end
