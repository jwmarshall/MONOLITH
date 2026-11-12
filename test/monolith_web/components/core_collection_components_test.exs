defmodule MonolithWeb.CoreCollectionComponentsTest do
  use ExUnit.Case, async: true
  use Phoenix.Component
  import Phoenix.LiveViewTest

  alias MonolithWeb.CoreComponents

  @endpoint MonolithWeb.Endpoint

  defmodule StreamTableLive do
    use Phoenix.LiveView
    alias MonolithWeb.CoreComponents

    def mount(_, _, socket) do
      records = [%{id: "a", title: "<script>untrusted</script>"}, %{id: "b", title: "Other"}]
      {:ok, stream(socket, :records, records)}
    end

    def handle_event("rename", _, socket),
      do: {:noreply, stream_insert(socket, :records, %{id: "a", title: "Updated"})}

    def render(assigns) do
      ~H"""
      <CoreComponents.table
        id="records"
        rows={@streams.records}
        row_item={fn {_id, record} -> record end}
      >
        <:col :let={record} label="Title">{record.title}</:col>
        <:action :let={record}>
          <a href={"/workspaces/" <> record.id} aria-label={"Open " <> record.title}>Open</a>
        </:action>
      </CoreComponents.table>
      """
    end
  end

  test "navigation controls remain links while form actions preserve submission and disabled semantics" do
    assigns = %{}

    document =
      rendered_to_string(~H"""
      <CoreComponents.button navigate="/workspaces" id="navigation">Workspaces</CoreComponents.button>
      <CoreComponents.button id="save" name="operation" value="save" disabled>
        Save
      </CoreComponents.button>
      """)
      |> LazyHTML.from_fragment()

    assert exists?(document, "a#navigation[href='/workspaces'][data-phx-link=redirect]")
    refute exists?(document, "button#navigation")
    assert exists?(document, "button#save[name=operation][value=save][disabled]")
    refute exists?(document, "a#save")
  end

  test "stream tables keep stable record DOM identities, mapped cells and accessible row actions" do
    {:ok, view, html} = live_isolated(Phoenix.ConnTest.build_conn(), StreamTableLive)
    document = LazyHTML.from_fragment(html)

    assert exists?(document, "tbody#records[phx-update=stream] > tr#records-a")
    assert exists?(document, "tbody#records > tr#records-b")

    assert LazyHTML.query(document, "#records-a td:first-child")
           |> LazyHTML.text()
           |> String.trim() ==
             "<script>untrusted</script>"

    refute exists?(document, "script")
    assert exists?(document, "#records-a a[href='/workspaces/a'][aria-label]")
    assert exists?(document, "thead th .sr-only")

    updated = view |> render_click("rename") |> LazyHTML.from_fragment()
    assert Enum.count(LazyHTML.query(updated, "#records-a")) == 1

    assert LazyHTML.query(updated, "#records-a td:first-child")
           |> LazyHTML.text()
           |> String.trim() == "Updated"

    assert exists?(updated, "#records-b a[href='/workspaces/b']")
  end

  test "ordinary table rows retain configured identity and activation without stream updates" do
    assigns = %{
      rows: [%{record: %{id: "a", title: "First"}}, %{record: %{id: "b", title: "Second"}}]
    }

    document =
      rendered_to_string(~H"""
      <CoreComponents.table
        id="ordinary-records"
        rows={@rows}
        row_id={fn %{record: record} -> "row-" <> record.id end}
        row_item={fn %{record: record} -> record end}
        row_click={fn %{record: record} -> "open:" <> record.id end}
      >
        <:col :let={record} label="Title">{record.title}</:col>
      </CoreComponents.table>
      """)
      |> LazyHTML.from_fragment()

    refute exists?(document, "tbody[phx-update=stream]")
    assert exists?(document, "#row-a td[phx-click='open:a']")
    assert exists?(document, "#row-b td[phx-click='open:b']")
    assert LazyHTML.query(document, "#row-a td") |> LazyHTML.text() |> String.trim() == "First"
    assert LazyHTML.query(document, "#row-b td") |> LazyHTML.text() |> String.trim() == "Second"
    refute exists?(document, "thead .sr-only")
  end

  test "header and detail slots escape untrusted labels and keep actions keyboard reachable" do
    assigns = %{title: "<script>untrusted title</script>", detail: "<img src=x onerror=alert(1)>"}

    document =
      rendered_to_string(~H"""
      <CoreComponents.header>
        {@title}
        <:subtitle>{@detail}</:subtitle>
        <:actions><a href="/workspaces">Back</a></:actions>
      </CoreComponents.header>
      <CoreComponents.list>
        <:item title={@title}>{@detail}</:item>
      </CoreComponents.list>
      """)
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, "h1") |> LazyHTML.text() |> String.trim() == assigns.title
    assert LazyHTML.query(document, "li") |> LazyHTML.text() =~ assigns.detail
    assert exists?(document, "header a[href='/workspaces']")
    refute exists?(document, "script, img")
  end

  defp exists?(document, selector), do: Enum.any?(LazyHTML.query(document, selector))
end
