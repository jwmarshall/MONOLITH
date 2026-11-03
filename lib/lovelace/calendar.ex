defmodule Lovelace.Calendar do
  @moduledoc "Account-scoped, read-only browser-day agendas with bounded on-demand retention."
  use Ash.Domain

  resources do
    resource Lovelace.Calendar.State

    resource Lovelace.Calendar.Operation do
      define :snapshot, action: :snapshot, args: [:account_id, :from_iso, :to_iso, :local_date]

      define :prepare,
        action: :prepare,
        args: [:account_id, :from_iso, :to_iso, :local_date, :timezone]

      define :select_calendars, action: :select_calendars, args: [:account_id, :ids]
      define :refresh, action: :refresh, args: [:account_id]
      define :poll, action: :poll, args: [:account_id, :generation, :revision]
    end
  end

  @doc "Internal lifecycle reset; caller must already hold Connections.serial(account_id)."
  defdelegate clear(account_id), to: Lovelace.Calendar.Operations
  defdelegate sweep(), to: Lovelace.Calendar.Operations
end
