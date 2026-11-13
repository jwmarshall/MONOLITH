defmodule MonolithWeb.StatusComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias MonolithWeb.StatusComponents

  test "every observed state keeps its label visible without adding a keyboard stop" do
    for state <- [:active, :ready, :unknown, :waiting, :warning, :offline],
        embedded <- [false, true] do
      document =
        render_component(&StatusComponents.status_signal/1,
          id: "signal",
          state: state,
          label: "Last-known state, not a live check",
          embedded: embedded
        )
        |> LazyHTML.from_fragment()

      assert LazyHTML.query(document, "#signal .status-label") |> LazyHTML.text() ==
               "Last-known state, not a live check"

      assert Enum.any?(LazyHTML.query(document, "svg[aria-hidden=true][focusable=false]"))
      assert Enum.empty?(LazyHTML.query(document, "[tabindex], [role=img], [role=progressbar]"))
    end
  end
end
