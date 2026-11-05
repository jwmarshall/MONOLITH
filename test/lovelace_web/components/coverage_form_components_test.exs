defmodule LovelaceWeb.CoverageFormComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias LovelaceWeb.{CalendarComponents, CoreComponents}

  test "checkboxes keep the false fallback in the same disabled and external-form boundary" do
    for {value, checked} <- [{"true", true}, {"false", false}] do
      document =
        render_component(&CoreComponents.input/1,
          type: "checkbox",
          id: "automatic-scenes",
          name: "preferences[automatic]",
          value: value,
          label: "Allow automatic scenery",
          disabled: true,
          form: "preferences"
        )
        |> LazyHTML.from_fragment()

      assert exists?(document, "label[for=automatic-scenes] input#automatic-scenes")
      assert LazyHTML.query(document, "label") |> LazyHTML.text() =~ "Allow automatic scenery"

      assert exists?(
               document,
               "input[type=hidden][name='preferences[automatic]'][value=false][disabled][form=preferences]"
             )

      assert exists?(
               document,
               "input[type=checkbox][name='preferences[automatic]'][value=true][disabled][form=preferences]"
             )

      assert exists?(document, "#automatic-scenes[checked]") == checked
    end
  end

  test "untouched fields with validation errors stay quiet until the field is used" do
    for {params, error_visible} <- [
          {%{"name" => "", "_unused_name" => ""}, false},
          {%{"name" => ""}, true}
        ] do
      form =
        {%{}, %{name: :string}}
        |> Ecto.Changeset.cast(params, [:name])
        |> Ecto.Changeset.validate_required([:name])
        |> Phoenix.Component.to_form(as: :profile, action: :validate)

      document =
        render_component(&CoreComponents.input/1,
          field: form[:name],
          label: "Workspace name",
          required: true
        )
        |> LazyHTML.from_fragment()

      assert exists?(document, "label[for=profile_name] input#profile_name[required]")
      assert exists?(document, "input[name='profile[name]'][value='']")
      assert exists?(document, ".text-error") == error_visible
      assert exists?(document, "input.input-error") == error_visible
    end
  end

  test "multiple selects preserve all selected values and submit an array under the form field name" do
    form = Phoenix.Component.to_form(%{"calendars" => ["primary", "shared"]}, as: :preferences)

    document =
      render_component(&CoreComponents.input/1,
        field: form[:calendars],
        type: "select",
        label: "Calendars",
        multiple: true,
        options: [{"Personal", "primary"}, {"Studio", "shared"}, {"Holidays", "holiday"}]
      )
      |> LazyHTML.from_fragment()

    assert exists?(document, "label[for=preferences_calendars] select[multiple]")
    assert exists?(document, "select[name='preferences[calendars][]']")
    assert exists?(document, "option[value=primary][selected]")
    assert exists?(document, "option[value=shared][selected]")
    refute exists?(document, "option[value=holiday][selected]")
  end

  test "textarea validation retains the user's draft as text and interpolates the field constraint" do
    draft = "<script>alert('draft')</script>\nKeep this direction"

    form =
      {%{}, %{direction: :string}}
      |> Ecto.Changeset.cast(%{"direction" => draft}, [:direction])
      |> Ecto.Changeset.validate_length(:direction, max: 10)
      |> Phoenix.Component.to_form(as: :scene, action: :validate)

    document =
      render_component(&CoreComponents.input/1,
        field: form[:direction],
        type: "textarea",
        label: "Scene direction",
        rows: 4
      )
      |> LazyHTML.from_fragment()

    assert exists?(
             document,
             "label[for=scene_direction] textarea#scene_direction.textarea-error[rows='4']"
           )

    assert LazyHTML.query(document, "textarea") |> LazyHTML.text() == draft
    refute exists?(document, "script")
    assert LazyHTML.query(document, ".text-error") |> LazyHTML.text() =~ "10"
    refute LazyHTML.query(document, ".text-error") |> LazyHTML.text() =~ "%{count}"
  end

  test "Calendar's empty connection action is unavailable with an accessible explanation until client setup" do
    unavailable =
      render_component(&CalendarComponents.connections/1,
        accounts: [],
        workspace_options: [],
        google_status: :locked
      )
      |> LazyHTML.from_fragment()

    assert exists?(
             unavailable,
             "section[aria-labelledby=calendar-connections-heading] #calendar-connections-heading"
           )

    assert exists?(
             unavailable,
             "button[disabled][aria-describedby=calendar-connections-google-prerequisite]"
           )

    assert exists?(
             unavailable,
             "#calendar-connections-google-prerequisite[role=status] a[href='/connections/google'][data-phx-link=patch]"
           )

    refute exists?(unavailable, "a[href='/connections/gmail']")
    refute exists?(unavailable, "form[action='/oauth/google/start']")

    available =
      render_component(&CalendarComponents.connections/1,
        accounts: [],
        workspace_options: [],
        google_status: :stored
      )
      |> LazyHTML.from_fragment()

    assert exists?(available, "a[href='/connections/gmail'][data-phx-link=patch]")
    refute exists?(available, "button[disabled], #calendar-connections-google-prerequisite")
    refute exists?(available, "form[action='/oauth/google/start']")
  end

  test "an account without Calendar consent links to setup rather than presenting an empty agenda" do
    document =
      render_component(&CalendarComponents.agenda/1,
        accounts: [
          %{id: "synthetic-account", email: "studio@example.test", calendar_enabled: false}
        ]
      )
      |> LazyHTML.from_fragment()

    assert exists?(
             document,
             "#calendar-agenda-account-synthetic-account[aria-labelledby=calendar-agenda-identity-synthetic-account]"
           )

    assert LazyHTML.query(document, "#calendar-agenda-identity-synthetic-account")
           |> LazyHTML.text() == "studio@example.test"

    assert exists?(
             document,
             "#calendar-agenda-account-synthetic-account a[href='/connections/calendar'][data-phx-link=patch]"
           )

    refute exists?(
             document,
             ".calendar-events, .calendar-message, button[phx-click='calendar:refresh']"
           )
  end

  defp exists?(document, selector), do: Enum.any?(LazyHTML.query(document, selector))
end
