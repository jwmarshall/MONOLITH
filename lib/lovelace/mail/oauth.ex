defmodule Lovelace.Mail.OAuth do
  @moduledoc "Bounded, one-use, ten-minute OAuth attempts bound to an unlocked owner session."
  use GenServer
  @ttl 600_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def begin(
        workspace_id,
        session,
        expected_account_id \\ nil,
        capability \\ :gmail,
        expected_generation \\ nil
      ) do
    if capability in [:gmail, :calendar] and
         (capability == :gmail or
            (is_binary(expected_account_id) and expected_account_id != "" and
               is_binary(expected_generation) and expected_generation != "")) do
      GenServer.call(
        __MODULE__,
        {:begin, workspace_id, digest(session), expected_account_id, capability,
         expected_generation}
      )
    else
      {:error, :invalid_request}
    end
  end

  def take(state, session),
    do: GenServer.call(__MODULE__, {:take, digest(state), digest(session)})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:begin, workspace, session, expected, capability, generation}, _from, attempts) do
    attempts = live(attempts)

    if map_size(attempts) >= 100 do
      {:reply, {:error, :busy}, attempts}
    else
      state = random()

      attempt = %{
        workspace_id: workspace,
        session: session,
        expected_account_id: expected,
        capability: capability,
        expected_generation: generation,
        verifier: random(),
        expires: System.monotonic_time(:millisecond) + @ttl
      }

      {:reply, {:ok, state, attempt.verifier}, Map.put(attempts, digest(state), attempt)}
    end
  end

  def handle_call({:take, state, session}, _from, attempts) do
    {attempt, attempts} = Map.pop(live(attempts), state)

    reply =
      if attempt && Plug.Crypto.secure_compare(attempt.session, session),
        do: {:ok, attempt},
        else: {:error, :invalid_state}

    {:reply, reply, attempts}
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}

  defp live(attempts),
    do: Map.filter(attempts, fn {_, a} -> a.expires > System.monotonic_time(:millisecond) end)

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(value) when is_binary(value), do: :crypto.hash(:sha256, value)
  defp digest(_), do: :crypto.hash(:sha256, "invalid")
end
