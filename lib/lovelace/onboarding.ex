defmodule Lovelace.Onboarding do
  @moduledoc "Resumable local-owner setup guidance, not verification of Google's console settings."
  use Ash.Domain
  require Ash.Query

  alias Lovelace.Onboarding.State
  alias Lovelace.Security.Vault

  @owner %{role: :local_owner}
  @personal "00000000-0000-4000-8000-000000000001"
  @steps [:project, :authentication, :audience, :client, :connect, :complete]

  resources do
    resource State do
      define :start_progress, action: :start
    end

    resource Lovelace.Onboarding.Operation do
      define :save_credentials, action: :save_credentials, args: [:client_id, :client_secret]
    end
  end

  def steps, do: @steps
  def personal_workspace_id, do: @personal
  def path(step) when step in @steps, do: "/onboarding/#{step}"
  def parse_step(value), do: Enum.find(@steps, &(Atom.to_string(&1) == value))

  @doc "Explicitly starts fresh setup; existing guide progress is never reset."
  def start(opts \\ []) do
    with {:ok, _workspace} <- Lovelace.Workspaces.initialize_personal(%{}, opts) do
      start_progress(%{}, opts)
    end
  end

  def progress(opts \\ []), do: Ash.get(State, 1, Keyword.put(opts, :error?, false))

  @doc "Only call after unlock. No guide row means an existing installation, not pending setup."
  def entry_path do
    if Vault.open?() do
      case progress(actor: @owner) do
        {:ok, %{finished: false, step: step}} -> path(step)
        {:ok, _} -> "/"
        _ -> "/onboarding"
      end
    else
      "/unlock"
    end
  end

  @doc "True only for an explicitly started, unfinished guide while the vault is open."
  def pending? do
    Vault.open?() and match?({:ok, %{finished: false}}, progress(actor: @owner))
  end

  def continue(step, opts \\ []) when step in @steps do
    with {:ok, state} <- start(opts),
         {:ok, next} <- next_step(step, state) do
      Ash.update(state, %{step: next}, Keyword.put(opts, :action, :advance))
    end
  end

  def finish(opts \\ []) do
    with {:ok, state} <- start(opts) do
      Ash.update(state, %{}, Keyword.put(opts, :action, :finish))
    end
  end

  # This is observed local connection/read state, not a new provider request or
  # a claim that console settings have been verified. One account is enough to
  # offer the first-read path; each account remains independently scoped.
  def connection(opts \\ []) do
    Lovelace.Mail.WorkspaceAccount
    |> Ash.Query.for_read(:read, %{workspace_id: @personal})
    |> Ash.Query.filter(account.status != :disconnected)
    |> Ash.Query.sort(created_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.load(:account)
    |> Ash.read(opts)
    |> case do
      {:ok, [%{account: account}]} ->
        {:ok,
         Map.take(account, [
           :id,
           :status,
           :last_success_at,
           :last_error,
           :inbox_unread_at,
           :inbox_unread_error
         ])}

      {:ok, []} ->
        {:ok, nil}

      _ ->
        {:error, :unavailable}
    end
  end

  defp next_step(:project, _), do: {:ok, :authentication}
  defp next_step(:authentication, _), do: {:ok, :audience}
  defp next_step(:audience, _), do: {:ok, :client}
  defp next_step(:client, %{credentials_saved: true}), do: {:ok, :connect}
  defp next_step(:connect, _), do: {:ok, :complete}
  defp next_step(_, _), do: {:error, :save_credentials_first}
end
