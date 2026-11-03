defmodule Lovelace.StageDesigner.Designer do
  @moduledoc false
  use Ash.Resource,
    domain: Lovelace.StageDesigner,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :gemini_connection_status, :atom do
      run {Lovelace.Integrations.Gemini.Credentials, operation: :status}
    end

    action :save_gemini_key, :boolean do
      argument :api_key, :string do
        allow_nil? false
        sensitive? true
        # Validate length inside Credentials: Ash constraint errors retain raw values
        # even for sensitive arguments, while our implementation returns safe atoms.
        constraints trim?: false
      end

      run {Lovelace.Integrations.Gemini.Credentials, operation: :save}
    end

    action :remove_gemini_key, :boolean do
      run {Lovelace.Integrations.Gemini.Credentials, operation: :delete}
    end

    action :background, :map do
      run Lovelace.StageDesigner.ReadBackground
    end

    action :image, :binary do
      argument :digest, :string do
        allow_nil? false
        constraints match: ~r/\A[0-9a-f]{64}\z/
      end

      run Lovelace.StageDesigner.ReadImage
    end

    action :startup, :atom do
      argument :now, :utc_datetime_usec do
        allow_nil? false
        default &DateTime.utc_now/0
      end

      run Lovelace.StageDesigner.Startup
    end

    # Operator-only opt-in for a single failed-attempt diagnostic retry. Not called
    # by application startup or the browser, and never retries a successful image.
    action :retry_failed, :atom do
      argument :now, :utc_datetime_usec do
        allow_nil? false
        default &DateTime.utc_now/0
      end

      run {Lovelace.StageDesigner.Startup, retry_failed?: true}
    end
  end

  policies do
    policy action([:gemini_connection_status, :save_gemini_key, :remove_gemini_key]) do
      access_type :strict
      authorize_if Lovelace.Workspaces.LocalOwner
    end

    policy action(:background) do
      authorize_if always()
    end

    policy action(:image) do
      authorize_if always()
    end

    policy action(:startup) do
      authorize_if actor_attribute_equals(:role, :stage_designer)
    end

    policy action(:retry_failed) do
      authorize_if actor_attribute_equals(:role, :stage_designer)
    end
  end
end
