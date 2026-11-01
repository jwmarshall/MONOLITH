defmodule Wallace.TestSupport.AshDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Wallace.TestSupport.AshProbe
  end
end
