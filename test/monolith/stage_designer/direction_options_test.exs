defmodule Monolith.StageDesigner.DirectionOptionsTest do
  use ExUnit.Case, async: true

  alias Monolith.StageDesigner.DirectionOptions

  test "fields and defaults expose atom keys and allowlisted string values" do
    assert DirectionOptions.defaults() == %{
             subject: "architecture",
             setting: "mountains",
             light: "amber",
             palette: "charcoal"
           }

    assert Enum.map(DirectionOptions.fields(), & &1.key) == [:subject, :setting, :light, :palette]

    for field <- DirectionOptions.fields() do
      assert is_binary(field.label)

      assert Enum.all?(field.options, fn {label, value} ->
               is_binary(label) and is_binary(value)
             end)

      assert DirectionOptions.defaults()[field.key] in Enum.map(field.options, &elem(&1, 1))
    end
  end

  test "every combination composes deterministic generic scenery with a safe center" do
    [subject, setting, light, palette] = DirectionOptions.fields()

    for {_, subject} <- subject.options,
        {_, setting} <- setting.options,
        {_, light} <- light.options,
        {_, palette} <- palette.options do
      values = %{subject: subject, setting: setting, light: light, palette: palette}
      prompt = DirectionOptions.compose(values)
      assert prompt == DirectionOptions.compose(values)
      assert prompt =~ "calm low-detail center"
      assert prompt =~ "negative space"
      assert prompt =~ "No people, text, lettering, logos, UI, interface elements"
      assert byte_size(prompt) < 8000
      if subject != "architecture", do: refute(prompt =~ "architecture")
    end
  end

  test "composition refuses arbitrary text, non-string selections, and missing keys" do
    for invalid <- [nil, "architecture", %{}, %{subject: :architecture}] do
      assert_raise ArgumentError, fn -> DirectionOptions.compose(invalid) end
    end

    for field <- DirectionOptions.fields(),
        invalid <- ["unknown", "architecture\n", :architecture] do
      assert_raise ArgumentError, fn ->
        DirectionOptions.compose(Map.put(DirectionOptions.defaults(), field.key, invalid))
      end
    end
  end
end
