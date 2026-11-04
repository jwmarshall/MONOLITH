defmodule Lovelace.Security.Bootstrap do
  @moduledoc "Single-use terminal pairing for browser owner creation; never a public signup."
  use GenServer

  alias Lovelace.Owner
  alias Lovelace.Security.{Keychain, Secret, Vault}

  @lifetime 15 * 60 * 1000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)
  def pair(code), do: call({:pair, code})
  def paired?(capability), do: call({:paired, capability}) == true

  def configure(capability, password, confirmation, acknowledged?) do
    call(
      {:configure, capability, %Secret{value: password}, %Secret{value: confirmation},
       acknowledged?}
    )
  end

  @impl true
  def init(options) do
    status = Keyword.get(options, :status, &configuration_status/0)
    clock = Keyword.get(options, :clock, fn -> System.monotonic_time(:millisecond) end)
    announce = Keyword.get(options, :announce, &announce/1)
    code = random_token()
    available? = status.() in [:new, :setup_incomplete]
    if available?, do: announce.(code)

    {:ok,
     %{
       code: if(available?, do: digest(code)),
       capability: nil,
       expires: clock.() + @lifetime,
       clock: clock,
       status: status,
       configure: Keyword.get(options, :configure, &configure_owner/1)
     }}
  end

  @impl true
  def handle_call({:pair, code}, _from, state) do
    if available?(state) and matches?(state.code, code) do
      capability = random_token()
      {:reply, {:ok, capability}, %{state | code: nil, capability: digest(capability)}}
    else
      {:reply, {:error, :pairing}, state}
    end
  end

  def handle_call({:paired, capability}, _from, state) do
    {:reply, authorized?(state, capability), state}
  end

  def handle_call({:configure, capability, password, confirmation, acknowledged?}, _from, state) do
    with true <- authorized?(state, capability),
         :ok <- validate(password.value, confirmation.value, acknowledged?),
         {:ok, token} <- state.configure.(password.value) do
      {:reply, {:ok, token}, %{state | code: nil, capability: nil}}
    else
      {:error, reason} when reason in [:password, :confirmation, :acknowledgement] ->
        {:reply, {:error, reason}, state}

      _ ->
        {:reply, {:error, :setup}, state}
    end
  end

  @impl true
  def format_status(_), do: %{state: :redacted, message: :redacted, reason: :redacted}

  defp authorized?(state, capability),
    do: available?(state) and matches?(state.capability, capability)

  defp available?(state),
    do: state.clock.() < state.expires and state.status.() in [:new, :setup_incomplete]

  defp matches?(expected, supplied) when is_binary(expected) and is_binary(supplied),
    do: byte_size(supplied) == 43 and Plug.Crypto.secure_compare(expected, digest(supplied))

  defp matches?(_, _), do: false

  defp validate(password, confirmation, acknowledged?) do
    cond do
      not is_binary(password) or not String.valid?(password) ->
        {:error, :password}

      byte_size(password) > 1024 or String.length(password) not in 12..1024 ->
        {:error, :password}

      not is_binary(confirmation) or not Plug.Crypto.secure_compare(password, confirmation) ->
        {:error, :confirmation}

      acknowledged? != true ->
        {:error, :acknowledgement}

      true ->
        :ok
    end
  end

  defp configure_owner(password) do
    with true <- Vault.configuration_status() in [:new, :setup_incomplete],
         :ok <- Keychain.begin_setup(),
         {:ok, _} <- Vault.setup(password, fn -> initialize_owner(password) end),
         {:ok, true} <- Vault.lock(),
         :ok <- Keychain.finish_setup(),
         {:ok, token} <- Owner.unlock(password, "browser-bootstrap") do
      {:ok, token}
    else
      _ ->
        Vault.lock()
        {:error, :setup}
    end
  rescue
    _ ->
      Vault.lock()
      {:error, :setup}
  end

  defp initialize_owner(password) do
    with {:ok, owner} <- Owner.Actions.configure_or_authenticate(password),
         {:ok, _} <- Lovelace.Onboarding.start(actor: %{role: :local_owner}) do
      {:ok, owner}
    end
  end

  if Mix.env() == :test do
    defp configuration_status do
      if Vault.enabled?(), do: Vault.configuration_status(), else: :disabled
    end
  else
    defp configuration_status, do: Vault.configuration_status()
  end

  defp announce(code) do
    # This deliberate terminal-only pairing secret must not go through Logger/telemetry.
    IO.puts("""

    LOVELACE first-run setup
    Open http://localhost:#{Application.fetch_env!(:lovelace, LovelaceWeb.Endpoint)[:http][:port]}/setup
    Enter this one-time pairing code in that browser (expires in 15 minutes):
    #{code}
    Keep this code private. Restart the server to issue a new code.
    """)
  end

  defp call(message) do
    GenServer.call(__MODULE__, message, :infinity)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value)
end
