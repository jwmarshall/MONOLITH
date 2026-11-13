defmodule MonolithWeb.HomeConnectionDiagnosticTest do
  use Monolith.DataCase, async: false
  alias Monolith.ConnectionDiagnostics.State
  alias MonolithWeb.{HomeConnectionDiagnostic, HomeGemini, HomeScenes}
  @actor %{role: :connection_diagnostics}

  defp socket do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}, scenes: true, connections: false, connection_view: :index}
    }
    |> HomeGemini.init()
  end

  test "leaving and reopening fences A to B to A timer observations" do
    first = HomeGemini.open(socket())
    %{token: old_token, id: id} = first.assigns.gemini_diagnostic
    second = HomeGemini.open(first)
    assert second.assigns.gemini_diagnostic.id == id
    refute second.assigns.gemini_diagnostic.token == old_token

    assert {:noreply, ^second} =
             HomeConnectionDiagnostic.handle_info(
               {:connection_diagnostic, :gemini, old_token},
               second
             )
  end

  test "local observation recovers completion without a broadcast and stops away from provider" do
    initial = HomeGemini.open(socket())
    %{id: id, token: token} = initial.assigns.gemini_diagnostic
    state = Ash.get!(State, :gemini, actor: @actor)

    state
    |> Ash.Changeset.for_update(:record, %{expected_id: id, status: :stored}, actor: @actor)
    |> Ash.update!()

    assert {:noreply, observed} =
             HomeGemini.handle_info({:connection_diagnostic, :gemini, token}, initial)

    assert observed.assigns.gemini_status == :stored
    away = Phoenix.Component.assign(observed, :scenes, false)

    assert {:noreply, stopped} =
             HomeGemini.handle_info({:connection_diagnostic, :gemini, token}, away)

    assert stopped.assigns.gemini_diagnostic == nil
  end

  test "Scenes init and leave preserve the authoritative destination flag" do
    initial = socket() |> HomeScenes.init()
    assert initial.assigns.scenes
    assert HomeScenes.leave(initial).assigns.scenes
  end
end
