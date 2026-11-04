defmodule Lovelace.Mail.ConnectionDiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Lovelace.Mail.ConnectionDiagnostics

  test "only allowlisted stage and category reach logs and redirects" do
    sentinel = "synthetic-private-provider-payload"

    log =
      capture_log(fn ->
        assert {:error, {:token_exchange, :unavailable}} =
                 ConnectionDiagnostics.step(:token_exchange, fn ->
                   {:error, %{body: sentinel, code: sentinel, token: sentinel}}
                 end)
      end)

    assert log =~ "token_exchange: unavailable"
    refute log =~ sentinel

    uri = URI.parse(ConnectionDiagnostics.failure_path({:token_exchange, :invalid_response}))
    assert uri.path == "/connections/gmail"

    assert URI.decode_query(uri.query) == %{
             "gmail" => "failed",
             "stage" => "token_exchange",
             "reason" => "invalid_response"
           }

    assert ConnectionDiagnostics.failure_path({:token_exchange, sentinel}) ==
             "/connections/gmail?gmail=failed"

    refute ConnectionDiagnostics.failure_path({:token_exchange, sentinel}) =~ sentinel
    refute ConnectionDiagnostics.message(sentinel, sentinel) =~ sentinel
  end

  test "exception details are discarded and Keychain failure is distinguished from Google" do
    sentinel = "synthetic-private-exception"

    log =
      capture_log(fn ->
        assert {:error, {:identity, :unexpected}} =
                 ConnectionDiagnostics.step(:identity, fn -> raise sentinel end)

        assert {:error, {:keychain, :keychain}} =
                 ConnectionDiagnostics.step(:connection, fn -> {:error, :keychain} end)
      end)

    refute log =~ sentinel
    assert log =~ "keychain"
  end
end
