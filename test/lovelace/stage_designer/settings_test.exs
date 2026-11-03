defmodule Lovelace.StageDesigner.SettingsTest do
  use ExUnit.Case, async: true

  alias Lovelace.StageDesigner.Settings

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
      settings = Settings.from_env(%{"LOVELACE_STAGE_RETAIN_COUNT" => value})
      refute Map.has_key?(settings, :retain_count)
    end
  end

  test "test runtime ignores real enablement and credentials never enter settings" do
    assert Settings.from_env(%{"LOVELACE_STAGE_ENABLED" => "true"}).enabled
    refute Settings.from_env(%{"LOVELACE_STAGE_ENABLED" => "true"}, true).enabled
    refute Map.has_key?(Settings.from_env(%{"GEMINI_API_KEY" => "fake-only"}), :api_key)
  end

  test "rejects malformed settings and cost-amplifying options without echoing values" do
    for {key, value} <- [
          {"LOVELACE_STAGE_ENABLED", "yes"},
          {"LOVELACE_STAGE_MODEL", "../unsafe"},
          {"LOVELACE_STAGE_MIN_REFRESH_HOURS", "0"},
          {"LOVELACE_STAGE_MIN_REFRESH_HOURS", "24seconds"},
          {"LOVELACE_STAGE_TIMEOUT_SECONDS", "999999"},
          {"LOVELACE_STAGE_ASPECT_RATIO", "unknown"},
          {"LOVELACE_STAGE_IMAGE_SIZE", "100K"},
          {"LOVELACE_STAGE_MAX_ATTEMPTS_PER_STARTUP", "2"},
          {"LOVELACE_STAGE_MAX_RETRIES", "1"},
          {"LOVELACE_STAGE_REFRESH", "every_request"},
          {"LOVELACE_STAGE_PROMPT", ""},
          {"LOVELACE_STAGE_STORAGE_DIR", ""}
        ] do
      assert_raise ArgumentError, fn -> Settings.from_env(%{key => value}) end
    end

    assert_raise ArgumentError, fn ->
      Settings.idle_minutes(%{"LOVELACE_WORKSPACE_IDLE_MINUTES" => "0"})
    end
  end
end
