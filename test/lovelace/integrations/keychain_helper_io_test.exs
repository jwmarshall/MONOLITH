defmodule Lovelace.Integrations.Google.KeychainHelperIOTest do
  use ExUnit.Case, async: false

  @moduletag skip:
               not match?({:unix, :darwin}, :os.type()) or is_nil(System.find_executable("xcrun"))
  @moduletag timeout: 30_000

  test "short newline frames are processed with stdin still open, before any credential operation" do
    directory = Path.join(System.tmp_dir!(), "lovelace-helper-io-#{Ash.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    executable = Path.join(directory, "keychain-io-probe")
    source = Path.expand("../../../priv/native/keychain.swift", __DIR__)

    {_output, status} =
      System.cmd("xcrun", ["swiftc", "-O", "-framework", "Security", source, "-o", executable],
        stderr_to_stdout: true
      )

    assert status == 0

    for input <- ["{\"operation\":\"invalid\",\"account\":\"not-a-uuid\"}\n", "not-json\n"] do
      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: []
        ])

      try do
        # Deliberately do not close stdin or pad to 4096 bytes. Invalid operation/
        # UUID or JSON guarantees the helper cannot call any SecItem function.
        true = Port.command(port, input)
        data = collect(port, "", System.monotonic_time(:millisecond) + 2000)
        assert Jason.decode!(data) == %{"error" => "unavailable"}
      after
        if Port.info(port), do: Port.close(port)
      end
    end
  end

  defp collect(port, data, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, chunk}} when byte_size(data) + byte_size(chunk) <= 4096 ->
        collect(port, data <> chunk, deadline)

      {^port, {:exit_status, 0}} ->
        data

      {^port, _} ->
        flunk("invalid helper framing or exit status")
    after
      remaining -> flunk("helper did not process a short frame before the deadline")
    end
  end
end
