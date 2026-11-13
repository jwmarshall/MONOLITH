defmodule Monolith.StageDesigner.SettingsTest do
  use ExUnit.Case, async: true

  alias Monolith.StageDesigner.Settings

  test "defaults are disabled and economical, with a three-minute idle timer" do
    assert %Settings{
             enabled: false,
             min_refresh_hours: 24,
             model: "gemini-nano-banana-2.1",
             image_size: "1K"
           } = Settings.from_env(%{})

    assert Settings.idle_minutes(%{}) == 3
  end

  test "legacy retention configuration is ignored and cannot cap the catalog" do
    for value <- ["1", "7", "8", "unlimited", "invalid"] do
      settings = Settings.from_env(%{"MONOLITH_STAGE_RETAIN_COUNT" => value})
      refute Map.has_key?(settings, :retain_count)
    end
  end

  test "test runtime ignores real enablement and credentials never enter settings" do
    assert Settings.from_env(%{"MONOLITH_STAGE_ENABLED" => "true"}).enabled
    refute Settings.from_env(%{"MONOLITH_STAGE_ENABLED" => "true"}, true).enabled
    refute Map.has_key?(Settings.from_env(%{"GEMINI_API_KEY" => "fake-only"}), :api_key)
  end

  test "rejects malformed settings and cost-amplifying options without echoing values" do
    for {key, value} <- [
          {"MONOLITH_STAGE_ENABLED", "yes"},
          {"MONOLITH_STAGE_MODEL", "../unsafe"},
          {"MONOLITH_STAGE_MIN_REFRESH_HOURS", "0"},
          {"MONOLITH_STAGE_MIN_REFRESH_HOURS", "24seconds"},
          {"MONOLITH_STAGE_TIMEOUT_SECONDS", "999999"},
          {"MONOLITH_STAGE_ASPECT_RATIO", "unknown"},
          {"MONOLITH_STAGE_IMAGE_SIZE", "100K"},
          {"MONOLITH_STAGE_MAX_ATTEMPTS_PER_STARTUP", "2"},
          {"MONOLITH_STAGE_MAX_RETRIES", "1"},
          {"MONOLITH_STAGE_REFRESH", "every_request"},
          {"MONOLITH_STAGE_PROMPT", ""},
          {"MONOLITH_STAGE_STORAGE_DIR", ""}
        ] do
      assert_raise ArgumentError, fn -> Settings.from_env(%{key => value}) end
    end

    assert_raise ArgumentError, fn ->
      Settings.idle_minutes(%{"MONOLITH_WORKSPACE_IDLE_MINUTES" => "0"})
    end
  end
end
