defmodule Lovelace.MailViewDataTest do
  use ExUnit.Case, async: false
  alias Lovelace.Mail.ViewData

  test "quiet render references expire on read without a later insert" do
    ref = ViewData.put(%{"text" => "synthetic ephemeral text"})
    assert ViewData.get(ref) == %{"text" => "synthetic ephemeral text"}

    :sys.replace_state(ViewData, fn entries ->
      Enum.map(entries, fn entry ->
        if entry.ref == ref,
          do: %{entry | at: System.monotonic_time(:millisecond) - 600_001},
          else: entry
      end)
    end)

    assert ViewData.get(ref) == nil
    refute Enum.any?(:sys.get_state(ViewData), &(&1.ref == ref))
  end
end
