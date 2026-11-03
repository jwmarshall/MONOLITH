defmodule Lovelace.StageDesigner do
  @moduledoc "Application-wide scenery, independent of connected mailbox accounts."
  use Ash.Domain

  resources do
    resource Lovelace.StageDesigner.State do
      define :initialize_state, action: :initialize
      define :get_state, action: :read, get_by: [:id], not_found_error?: false
      define :reserve_state, action: :reserve
      define :publish_state, action: :publish
      define :fail_state, action: :fail
      define :select_state_scene, action: :select_scene
    end

    resource Lovelace.StageDesigner.Attempt
    resource Lovelace.StageDesigner.Scene

    resource Lovelace.StageDesigner.Direction do
      define :scene_direction, action: :scene_direction
      define :save_scene_direction, action: :save_scene_direction
      define :get_direction, action: :read, get_by: [:id], not_found_error?: false
      define :persist_direction, action: :save
    end

    resource Lovelace.StageDesigner.DefaultScene do
      define :initialize_default_scene, action: :initialize
      define :get_default_scene, action: :read, get_by: [:id], not_found_error?: false
    end

    resource Lovelace.StageDesigner.Designer do
      define :background, action: :background
      define :image, action: :image, args: [:digest]
      define :list_scenes, action: :list_scenes
      define :select_scene, action: :select_scene, args: [:digest]
      define :prepare_scene_generation, action: :prepare_scene_generation
      define :acknowledge_scene_attempt, action: :acknowledge_scene_attempt
      define :check_scene_attempt, action: :check_scene_attempt
      define :request_scene_generation, action: :request_scene_generation
      define :generate_on_startup, action: :startup
      define :retry_failed_startup, action: :retry_failed
      define :gemini_connection_status, action: :gemini_connection_status
      define :save_gemini_key, action: :save_gemini_key, args: [:api_key]
      define :remove_gemini_key, action: :remove_gemini_key
    end
  end
end
