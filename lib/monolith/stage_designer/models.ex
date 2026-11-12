defmodule Monolith.StageDesigner.Models do
  @moduledoc "Curated image models and deliberately bounded local image settings; no provider probes."
  alias Monolith.StageDesigner.Settings

  @models [
    {"Nano Banana 2.1", "gemini-nano-banana-2.1"},
    {"Nano Banana 2", "gemini-3.1-flash-image"},
    {"Nano Banana Pro", "gemini-3-pro-image"}
  ]
  @ratios ["16:9", "21:9", "4:3", "3:2", "1:1"]
  # Some 4K outputs exceed our 16-million-pixel limit. Do not offer them in the UI.
  @sizes ["1K", "2K"]

  def options, do: @models
  def ratios, do: @ratios
  def sizes, do: @sizes

  def defaults do
    settings = Settings.get()
    %{model: settings.model, aspect_ratio: settings.aspect_ratio, image_size: settings.image_size}
  end

  def validate(%{model: model, aspect_ratio: ratio, image_size: size}) do
    if model in Enum.map(@models, &elem(&1, 1)) and ratio in @ratios and size in @sizes,
      do: :ok,
      else: {:error, :invalid_settings}
  end

  def validate(_), do: {:error, :invalid_settings}
end
