defmodule Lovelace.Home do
  @moduledoc "Owner-authorized, provider-free daily orientation and workspace read models."
  use Ash.Domain

  resources do
    resource Lovelace.Home.Summary do
      define :summary, action: :summary
    end
  end
end
