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
    end

    resource Lovelace.StageDesigner.Designer do
      define :background, action: :background
      define :image, action: :image, args: [:digest]
      define :generate_on_startup, action: :startup
      define :retry_failed_startup, action: :retry_failed
    end
  end
end
