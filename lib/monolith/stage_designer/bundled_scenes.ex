defmodule Monolith.StageDesigner.BundledScenes do
  @moduledoc "Bundled local scenery and the installation's durable default choice."

  require Logger

  alias Monolith.Security.Vault
  alias Monolith.StageDesigner

  @actor %{role: :stage_designer}
  @digests ~w(
    403a724ce7707014e384d7f07d0820df1c4b499e34c807076bcd3c87dd0ea133
    cfd5e70f02db61442b938654f3a95a001280d7a773f20bd56f8950fa9376ba03
    edf9e32a1aefae7fb0f7edf13634b7692e7f2c5558f5a2af8c9d4e9ef92d6fb9
  )

  def digests, do: @digests
  def random_digest, do: Enum.random(@digests)

  # A synchronous, local-only initializer after vault unlock, before protected
  # pages can use persisted scenery. Upsert preserves the winning choice.
  # Returning :ignore makes this a one-shot supervisor child, not a running task.
  def initialize do
    case StageDesigner.initialize_default_scene(%{}, actor: @actor) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        Logger.warning("MONOLITH default scenery choice unavailable; using bundled fallback")
    end

    :ignore
  end

  # Rendering only reads local state. A missing/unavailable preference still has
  # a known bundled fallback, without writing state or starting provider work.
  def default_url do
    if Vault.open?() do
      case StageDesigner.get_default_scene(1, actor: @actor) do
        {:ok, %{digest: digest}} when digest in @digests -> url(digest)
        _ -> url(hd(@digests))
      end
    else
      url(hd(@digests))
    end
  rescue
    _ -> url(hd(@digests))
  end

  defp url(digest), do: "/images/scenes/#{digest}.jpg"
end
