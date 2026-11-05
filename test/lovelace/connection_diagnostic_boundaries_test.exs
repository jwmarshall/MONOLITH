defmodule Lovelace.Mail.ConnectionDiagnosticBoundariesTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Lovelace.Mail.ConnectionDiagnostics

  test "thrown, exited and malformed stage results become safe failure categories" do
    private = "synthetic-private-oauth-code"

    log =
      capture_log(fn ->
        for operation <- [
              fn -> throw({:private, private}) end,
              fn -> exit({:private, private}) end,
              fn -> {:unexpected, private} end
            ] do
          assert {:error, {:callback, :unexpected}} =
                   ConnectionDiagnostics.step(:callback, operation)
        end
      end)

    refute log =~ private
    assert log =~ "callback: unexpected"
    assert log =~ "Start a new connection"
  end

  test "credential rollback failures redirect to local recovery rather than provider troubleshooting" do
    log =
      capture_log(fn ->
        assert {:error, {:keychain, :rollback_failed}} =
                 ConnectionDiagnostics.step(:connection, fn ->
                   {:error, {:keychain, :rollback_failed}}
                 end)
      end)

    assert log =~ "keychain: rollback_failed"
    assert log =~ "dedicated keychain"

    path = ConnectionDiagnostics.failure_path({:keychain, :rollback_failed})
    params = path |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params == %{"gmail" => "failed", "stage" => "keychain", "reason" => "rollback_failed"}

    assert ConnectionDiagnostics.message(params["stage"], params["reason"]) =~
             "dedicated keychain"
  end

  test "missing code, offline grant and unknown callback failures offer distinct safe recovery" do
    assert capture_log(fn ->
             assert {:error, {:code, :invalid_callback}} =
                      ConnectionDiagnostics.failure(:code, :invalid_callback)
           end) =~ "do not reuse a callback URL"

    assert capture_log(fn ->
             assert {:error, {:refresh_token, :reconnect}} =
                      ConnectionDiagnostics.failure(:refresh_token, :reconnect)
           end) =~ "reusable offline access"

    assert capture_log(fn ->
             assert {:error, {:callback, :unavailable}} =
                      ConnectionDiagnostics.failure("private-provider-stage", %{
                        "secret" => "private"
                      })
           end) =~ "Start a new connection"

    assert ConnectionDiagnostics.message("code", "invalid_callback") =~ "do not reuse"
    assert ConnectionDiagnostics.message("refresh_token", "reconnect") =~ "offline access"

    generic = "Google connection was not completed. Check setup and try again."
    assert ConnectionDiagnostics.message(nil, "private") == generic
    assert ConnectionDiagnostics.message("callback", %{}) == generic

    assert ConnectionDiagnostics.failure_path(%{"secret" => "private"}) ==
             "/connections/gmail?gmail=failed"
  end
end
