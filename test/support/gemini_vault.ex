defmodule Monolith.TestSupport.GeminiVault do
  @moduledoc false
  use Agent
  @behaviour Monolith.Integrations.Google.Keychain

  def start_link(opts),
    do: Agent.start_link(fn -> %{value: nil, error: nil} end, name: opts[:name] || __MODULE__)

  def fail(reason), do: Agent.update(__MODULE__, &Map.put(&1, :error, reason))

  @impl true
  def get(_account) do
    Agent.get(__MODULE__, fn
      %{error: error} when not is_nil(error) -> {:error, error}
      %{value: nil} -> {:error, :not_found}
      %{value: value} -> {:ok, value}
    end)
  end

  @impl true
  def put(_account, value) do
    Agent.get_and_update(__MODULE__, fn
      %{error: error} = state when not is_nil(error) -> {{:error, error}, state}
      state -> {:ok, %{state | value: value}}
    end)
  end

  @impl true
  def delete(_account) do
    Agent.get_and_update(__MODULE__, fn
      %{error: error} = state when not is_nil(error) -> {{:error, error}, state}
      state -> {:ok, %{state | value: nil}}
    end)
  end
end
