defmodule Monolith.Onboarding.Credentials do
  @moduledoc false
  @behaviour Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    # Validate here, not through length/format constraints that can retain raw
    # submitted values in an Ash error. Nothing from the adapter is returned.
    with {:ok, workspace} when not is_nil(workspace) <-
           Monolith.Onboarding.workspace(actor: context.actor),
         {:ok, true} <-
           Monolith.Google.save_client_credentials(
             input.arguments.client_id,
             input.arguments.client_secret,
             actor: context.actor
           ),
         {:ok, state} <- Monolith.Onboarding.start(actor: context.actor),
         {:ok, _} <-
           Ash.update(state, %{}, action: :credentials_saved, actor: context.actor) do
      {:ok, true}
    else
      _ -> {:error, "Unable to save Google client settings. Please try again."}
    end
  rescue
    _ -> {:error, "Unable to save Google client settings. Please try again."}
  catch
    _, _ -> {:error, "Unable to save Google client settings. Please try again."}
  end
end
