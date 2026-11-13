defmodule Monolith.Calendar do
  @moduledoc "Account-scoped, read-only browser-day agendas with bounded on-demand retention."
  use Ash.Domain

  resources do
    resource Monolith.Calendar.State

    resource Monolith.Calendar.Operation do
      define :catalog, action: :catalog, args: [:account_id]
      define :snapshot, action: :snapshot, args: [:account_id, :from_iso, :to_iso, :local_date]

      define :prepare,
        action: :prepare,
        args: [:account_id, :from_iso, :to_iso, :local_date, :timezone]

      define :select_calendars, action: :select_calendars, args: [:account_id, :generation, :ids]
      define :refresh, action: :refresh, args: [:account_id]
      define :poll, action: :poll, args: [:account_id, :generation, :revision]
      define :sweep, action: :sweep
    end
  end

  @doc "Internal lifecycle reset; caller must already hold Google.Access.serial(account_id)."
  defdelegate clear(account_id), to: Monolith.Calendar.Operations
end
