defmodule Monolith.TestSupport.AshDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Monolith.TestSupport.AshProbe
  end
end
