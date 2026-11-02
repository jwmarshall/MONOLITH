defmodule Lovelace.StageDesigner.Settings do
  @moduledoc "Validated, nonsecret settings for the local stage designer."

  @prompt "Create a quiet cinematic architectural landscape for a personal desktop workspace. Original minimalist brutalist architecture, distant expansive scenery, charcoal planes, restrained warm amber light, subtle atmospheric depth, deliberate negative space, and a calm low-detail center. Vary the architecture, terrain, weather, and time of day within this visual language. No people, text, lettering, logos, busy foregrounds, neon cyberpunk, or interface elements."

  defstruct enabled: false,
            model: "gemini-nano-banana-2.1",
            aspect_ratio: "16:9",
            image_size: "1K",
            prompt: @prompt,
            min_refresh_hours: 24,
            timeout_seconds: 120,
            storage_dir: "./data/stage-designer",
            retain_count: 7

  def get, do: Application.get_env(:lovelace, :stage_designer, %__MODULE__{})

  def from_env(env, test? \\ false) do
    settings = %__MODULE__{
      enabled: not test? and Map.get(env, "LOVELACE_STAGE_ENABLED", "false") == "true",
      model: Map.get(env, "LOVELACE_STAGE_MODEL", "gemini-nano-banana-2.1"),
      aspect_ratio: Map.get(env, "LOVELACE_STAGE_ASPECT_RATIO", "16:9"),
      image_size: Map.get(env, "LOVELACE_STAGE_IMAGE_SIZE", "1K"),
      prompt: Map.get(env, "LOVELACE_STAGE_PROMPT", @prompt),
      min_refresh_hours: integer!(env, "LOVELACE_STAGE_MIN_REFRESH_HOURS", 24, 24..8760),
      timeout_seconds: integer!(env, "LOVELACE_STAGE_TIMEOUT_SECONDS", 120, 1..120),
      storage_dir: Map.get(env, "LOVELACE_STAGE_STORAGE_DIR", "./data/stage-designer"),
      retain_count: integer!(env, "LOVELACE_STAGE_RETAIN_COUNT", 7, 1..7)
    }

    if valid_art_settings?(settings) and valid_request_policy?(env),
      do: settings,
      else: raise(ArgumentError, "Invalid stage-designer configuration")
  end

  def idle_minutes(env) do
    integer!(env, "LOVELACE_WORKSPACE_IDLE_MINUTES", 3, 1..60)
  end

  defp valid_art_settings?(settings) do
    Regex.match?(~r/\A[a-z0-9][a-z0-9.-]{0,99}\z/, settings.model) and
      settings.aspect_ratio in ["16:9", "21:9", "4:3", "3:2", "1:1"] and
      settings.image_size in ["1K", "2K", "4K"] and
      byte_size(settings.prompt) in 1..8000 and settings.storage_dir != ""
  end

  defp valid_request_policy?(env) do
    Map.get(env, "LOVELACE_STAGE_REFRESH", "on_startup") == "on_startup" and
      Map.get(env, "LOVELACE_STAGE_MAX_ATTEMPTS_PER_STARTUP", "1") == "1" and
      Map.get(env, "LOVELACE_STAGE_MAX_RETRIES", "0") == "0" and
      Map.get(env, "LOVELACE_STAGE_ENABLED", "false") in ["true", "false"]
  end

  defp integer!(env, key, default, range) do
    case Integer.parse(Map.get(env, key, Integer.to_string(default))) do
      {number, ""} ->
        if number in range, do: number, else: raise(ArgumentError, "Invalid #{key} configuration")

      _ ->
        raise ArgumentError, "Invalid #{key} configuration"
    end
  end
end
