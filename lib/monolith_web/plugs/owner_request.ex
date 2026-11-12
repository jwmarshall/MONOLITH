defmodule MonolithWeb.Plugs.OwnerRequest do
  @moduledoc "Keeps protected HTTP leases until routing and adapter transmission finish."
  @behaviour Plug

  alias Monolith.Security.Vault

  @leases {__MODULE__, :leases}

  @impl true
  def init(options), do: MonolithWeb.Router.init(options)

  @impl true
  def call(conn, options) do
    previous = Process.put(@leases, [])

    try do
      case MonolithWeb.Router.call(conn, options) do
        %Plug.Conn{state: :set} = response -> Plug.Conn.send_resp(response)
        response -> response
      end
    after
      leases = Process.delete(@leases)
      if previous != nil, do: Process.put(@leases, previous)
      Enum.each(leases, &Vault.release/1)
    end
  end

  def retain(nil), do: :ok

  def retain(lease) do
    case Process.get(@leases) do
      leases when is_list(leases) ->
        Process.put(@leases, [lease | leases])
        :ok

      nil ->
        Vault.release(lease)
        {:error, :request_not_scoped}
    end
  end
end
