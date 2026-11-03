defmodule Lovelace.StageDesigner.DirectionOptions do
  @moduledoc "Allowlisted, generic guided scenery choices and deterministic prompt composition."

  @fields [
    %{
      key: :subject,
      label: "Subject",
      options: [
        {"Architecture", "architecture"},
        {"Landscape", "landscape"},
        {"Abstract", "abstract"}
      ]
    },
    %{
      key: :setting,
      label: "Setting",
      options: [
        {"Coast", "coast"},
        {"Mountains", "mountains"},
        {"Desert", "desert"},
        {"Forest", "forest"}
      ]
    },
    %{
      key: :light,
      label: "Light",
      options: [
        {"Amber", "amber"},
        {"Overcast", "overcast"},
        {"Dawn", "dawn"},
        {"Moonlight", "moonlight"}
      ]
    },
    %{
      key: :palette,
      label: "Palette",
      options: [
        {"Charcoal", "charcoal"},
        {"Sea glass", "sea_glass"},
        {"Earth", "earth"},
        {"Mist", "mist"}
      ]
    }
  ]

  def fields, do: @fields

  def defaults,
    do: %{subject: "architecture", setting: "mountains", light: "amber", palette: "charcoal"}

  def compose(values) do
    unless valid?(values) do
      raise ArgumentError, "Invalid guided scenery choices"
    end

    subject = %{
      "architecture" => "original minimalist brutalist architecture",
      "landscape" => "an expansive natural landscape",
      "abstract" => "abstract sculptural forms and atmospheric shapes"
    }

    setting = %{
      "coast" => "a quiet coastal setting",
      "mountains" => "a distant mountain setting",
      "desert" => "an open desert setting",
      "forest" => "a tranquil forest setting"
    }

    light = %{
      "amber" => "restrained warm amber light",
      "overcast" => "soft diffuse overcast light",
      "dawn" => "gentle dawn light",
      "moonlight" => "subtle cool moonlight"
    }

    palette = %{
      "charcoal" => "a muted charcoal palette",
      "sea_glass" => "a muted sea-glass palette",
      "earth" => "a muted earth-tone palette",
      "mist" => "a muted mist-gray palette"
    }

    "Create quiet cinematic scenery for a personal desktop workspace featuring " <>
      subject[values.subject] <>
      " in " <>
      setting[values.setting] <>
      ", " <>
      light[values.light] <>
      ", and " <>
      palette[values.palette] <>
      ". " <>
      "Use subtle atmospheric depth, deliberate negative space, and a calm low-detail center. " <>
      "No people, text, lettering, logos, UI, interface elements, or busy foregrounds."
  end

  defp valid?(values) when is_map(values), do: Enum.all?(@fields, &valid_field?(&1, values))
  defp valid?(_), do: false

  defp valid_field?(field, values) do
    value = Map.get(values, field.key)
    is_binary(value) and Enum.any?(field.options, fn {_, option} -> option == value end)
  end
end
