defmodule Monolith.Security.RuntimeLease do
  @moduledoc false
  use GenServer

  # Retain the native exclusion handle until every later protected child has
  # stopped, including when the vault manager dies without running terminate/2.
  def start_link(handle), do: GenServer.start_link(__MODULE__, handle)

  @impl true
  def init(handle), do: {:ok, handle}

  @impl true
  def format_status(_), do: %{state: :redacted}
end
