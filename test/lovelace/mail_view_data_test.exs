defmodule Lovelace.MailViewDataTest do
  use ExUnit.Case, async: false
  alias Lovelace.Mail.ViewData

  setup do
    owner = self()
    ViewData.clear(owner)
    on_exit(fn -> ViewData.clear(owner) end)
    :ok
  end

  test "quiet render references expire on read without a later insert" do
    ref = ViewData.put(%{"text" => "synthetic ephemeral text"})
    assert ViewData.get(ref) == %{"text" => "synthetic ephemeral text"}
    timer = entry(ref).timer

    :sys.replace_state(ViewData, fn entries ->
      Enum.map(entries, fn entry ->
        if entry.ref == ref,
          do: %{entry | at: System.monotonic_time(:millisecond) - 600_001},
          else: entry
      end)
    end)

    assert ViewData.get(ref) == nil
    refute Enum.any?(:sys.get_state(ViewData), &(&1.ref == ref))
    assert Process.read_timer(timer) == false
  end

  test "the idle expiry callback drops payloads and cancels their exact timer without a read" do
    ref = ViewData.put(%{"text" => "synthetic idle private text"})
    timer = entry(ref).timer
    remaining = Process.read_timer(timer)
    assert is_integer(remaining) and remaining > 0 and remaining <= 600_000

    # Exercise the scheduled callback without advancing wall time or reading data.
    :sys.replace_state(ViewData, fn entries ->
      {:noreply, retained} = ViewData.handle_info({:expire, ref}, entries)
      retained
    end)

    refute Enum.any?(:sys.get_state(ViewData), &(&1.ref == ref))
    assert Process.read_timer(timer) == false
    assert ViewData.get(ref) == nil
  end

  test "bounded eviction and explicit clearing cancel retained expiry timers" do
    first = ViewData.put(%{"text" => "synthetic oldest payload"})
    first_timer = entry(first).timer
    for n <- 1..4, do: ViewData.put(%{"text" => "synthetic payload #{n}"})
    assert Process.read_timer(first_timer) == false
    assert ViewData.get(first) == nil

    timers =
      ViewData
      |> :sys.get_state()
      |> Enum.filter(&(&1.owner == self()))
      |> Enum.map(& &1.timer)

    assert length(timers) == 4
    assert :ok = ViewData.clear()
    assert Enum.all?(timers, &(Process.read_timer(&1) == false))
  end

  test "OTP diagnostics redact a retained private body without destroying its view-owned result" do
    body = %{"text" => "distinctive-private-body-not-for-process-diagnostics"}
    ref = ViewData.put(body)
    assert ViewData.get(ref) == body
    refute inspect(:sys.get_status(ViewData), limit: :infinity) =~ body["text"]
    assert ViewData.get(ref) == body
  end

  defp entry(ref), do: Enum.find(:sys.get_state(ViewData), &(&1.ref == ref))
end
