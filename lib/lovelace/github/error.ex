defmodule Lovelace.GitHub.Error do
  @moduledoc "Allowlisted failure category preserved through Ash without provider or credential details."
  use Splode.Error, fields: [:reason], class: :invalid

  def message(_error), do: "GitHub operation failed"
end
