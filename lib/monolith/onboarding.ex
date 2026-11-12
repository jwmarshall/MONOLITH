defmodule Monolith.Onboarding do
  @moduledoc "Resumable local-owner setup guidance, not verification of Google's console settings."
  use Ash.Domain
  require Ash.Query

  alias Monolith.Onboarding.State
  alias Monolith.Security.Vault

  @owner %{role: :local_owner}
  @steps [
    :workspace,
    :project,
    :authentication,
    :audience,
    :client,
    :connect,
    :calendar,
    :complete
  ]

  resources do
    resource State do
      define :start_progress, action: :start
    end

    resource Monolith.Onboarding.Operation do
      define :persist_credentials, action: :save_credentials, args: [:client_id, :client_secret]
      define :save_workspace, action: :save_workspace, args: [:name]
    end
  end

  def steps, do: @steps
  def path(step) when step in @steps, do: "/onboarding/#{step}"
  def parse_step(value), do: Enum.find(@steps, &(Atom.to_string(&1) == value))

  @doc "Explicitly starts fresh setup; existing guide progress is never reset."
  def start(opts \\ []), do: start_progress(%{}, opts)

  @doc "The workspace explicitly chosen for this guide, if one has been saved."
  def workspace(opts \\ []) do
    with {:ok, state} <- progress(opts) do
      if state && state.workspace_id do
        Monolith.Workspaces.get_workspace(state.workspace_id, opts)
      else
        {:ok, nil}
      end
    end
  end

  def save_credentials(client_id, client_secret, opts \\ []) do
    with {:ok, workspace} <- workspace(opts),
         :ok <- require_workspace(workspace) do
      persist_credentials(client_id, client_secret, opts)
    end
  end

  def progress(opts \\ []), do: Ash.get(State, 1, Keyword.put(opts, :error?, false))

  @doc "Only call after unlock. No guide row means an existing installation, not pending setup."
  def entry_path do
    if Vault.open?() do
      case progress(actor: @owner) do
        {:ok, %{finished: false, workspace_id: nil}} -> path(:workspace)
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
         :ok <- require_workspace(state.workspace_id),
         {:ok, next} <- next_step(step, state) do
      Ash.update(state, %{step: next}, Keyword.put(opts, :action, :advance))
    end
  end

  @doc "Skips optional integration guidance without changing credentials, accounts, or grants."
  def skip(step, opts \\ [])
      when step in [:project, :authentication, :audience, :client, :connect, :calendar] do
    with {:ok, state} <- start(opts),
         :ok <- require_workspace(state.workspace_id) do
      next = if step == :connect, do: :calendar, else: :complete
      Ash.update(state, %{step: next}, Keyword.put(opts, :action, :advance))
    end
  end

  def finish(opts \\ []) do
    with {:ok, state} <- start(opts),
         :ok <- require_workspace(state.workspace_id) do
      Ash.update(state, %{}, Keyword.put(opts, :action, :finish))
    end
  end

  # This is observed local connection/read state, not a new provider request or
  # a claim that console settings have been verified. One account is enough to
  # offer the first-read path; each account remains independently scoped.
  def connection(opts \\ []) do
    with {:ok, workspace} <- workspace(opts) do
      if workspace do
        workspace_connection(workspace.id, opts)
      else
        {:ok, nil}
      end
    end
  end

  defp workspace_connection(workspace_id, opts) do
    Monolith.Mail.WorkspaceAccount
    |> Ash.Query.for_read(:read, %{workspace_id: workspace_id})
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
           :generation,
           :email,
           :calendar_enabled,
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

  defp require_workspace(nil), do: {:error, :workspace_required}
  defp require_workspace(_), do: :ok

  defp next_step(:workspace, _), do: {:ok, :project}
  defp next_step(:project, _), do: {:ok, :authentication}
  defp next_step(:authentication, _), do: {:ok, :audience}
  defp next_step(:audience, _), do: {:ok, :client}
  defp next_step(:client, %{credentials_saved: true}), do: {:ok, :connect}
  defp next_step(:connect, _), do: {:ok, :calendar}
  defp next_step(:calendar, _), do: {:ok, :complete}
  defp next_step(_, _), do: {:error, :save_credentials_first}
end
