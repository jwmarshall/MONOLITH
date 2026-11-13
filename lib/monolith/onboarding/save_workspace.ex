defmodule Monolith.Onboarding.SaveWorkspace do
  @moduledoc false
  @behaviour Ash.Resource.Actions.Implementation

  alias Monolith.Onboarding
  alias Monolith.Onboarding.State
  alias Monolith.Workspaces
  alias Monolith.Workspaces.Workspace

  @impl true
  def run(input, _opts, context) do
    opts = [actor: context.actor]

    Ash.transact([State, Workspace], fn ->
      # The singleton upsert is deliberately the first database operation. It
      # acquires SQLite's write transaction before reading the association, so
      # simultaneous submissions cannot both create a first workspace.
      state = Onboarding.start_progress!(%{}, opts)

      workspace =
        if state.workspace_id do
          state.workspace_id
          |> Workspaces.get_workspace!(opts)
          |> Workspaces.rename_workspace!(input.arguments.name, opts)
        else
          Workspaces.create_workspace!(input.arguments.name, opts)
        end

      Ash.update!(
        state,
        %{workspace_id: workspace.id},
        Keyword.put(opts, :action, :save_workspace)
      )
    end)
  end
end
