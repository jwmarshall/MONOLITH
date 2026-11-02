defmodule Lovelace.TestSupport.AshDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Lovelace.TestSupport.AshProbe
  end
end
