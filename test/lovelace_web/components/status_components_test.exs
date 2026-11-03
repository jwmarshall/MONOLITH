defmodule LovelaceWeb.StatusComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias LovelaceWeb.StatusComponents

  test "quiet signals have accessible names, custom decorative SVGs and focus details" do
    for state <- [:active, :ready, :unknown, :waiting, :warning, :offline] do
      document =
        render_component(&StatusComponents.status_signal/1,
          id: "signal",
          state: state,
          label: "Last-known state, not a live check"
        )
        |> LazyHTML.from_fragment()

      assert Enum.any?(LazyHTML.query(document, "#signal[role=img][tabindex='0'][aria-label]"))

      assert Enum.any?(LazyHTML.query(document, "svg[aria-hidden=true][focusable=false]"))
      assert Enum.any?(LazyHTML.query(document, ".status-tooltip[aria-hidden=true]"))
      assert Enum.empty?(LazyHTML.query(document, "[role=progressbar], .status-label"))

      assert Enum.count(LazyHTML.query(document, ".status-orbit")) ==
               if(state == :active, do: 1, else: 0)
    end
  end

  test "embedded signals do not add a tab stop inside native links" do
    html =
      render_component(&StatusComponents.status_signal/1,
        id: "signal",
        state: :unknown,
        label: "Connection not checked",
        embedded: true
      )

    assert html =~ ~s(data-embedded="true")
    refute html =~ "tabindex="
  end

  test "actionable warnings keep visible text without a redundant tooltip or tab stop" do
    document =
      render_component(&StatusComponents.status_signal/1,
        id: "signal",
        state: :warning,
        label: "Reconnect this account in Connections",
        text: true
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, ".status-label") |> LazyHTML.text() =~
             "Reconnect this account"

    assert Enum.empty?(LazyHTML.query(document, "[tabindex], [role=img], .status-tooltip"))
  end
end
