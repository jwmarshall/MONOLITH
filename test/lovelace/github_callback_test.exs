defmodule Lovelace.GitHub.CallbackTest do
  use ExUnit.Case, async: false
  alias Lovelace.GitHub.Callback
  alias Lovelace.Integrations.GitHub.Transport

  setup do
    previous = Application.fetch_env(:lovelace, :github_callback_url)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lovelace, :github_callback_url, value)
        :error -> Application.delete_env(:lovelace, :github_callback_url)
      end
    end)
  end

  test "callback configuration is explicit and supports the composed localhost port" do
    Application.delete_env(:lovelace, :github_callback_url)
    assert Callback.url() == nil

    configured = "http://localhost:54321/auth/github/callback"
    Application.put_env(:lovelace, :github_callback_url, configured)
    assert Callback.url() == configured

    # Transport validates the supplied value, not application configuration or Auth state.
    Application.delete_env(:lovelace, :github_callback_url)
    assert Transport.valid_callback_uri?(configured)
  end

  test "configuration and wire reject noncanonical destinations before exchange" do
    for callback <- [
          nil,
          "https://localhost:4321/auth/github/callback",
          "http://127.0.0.1:4321/auth/github/callback",
          "http://example.invalid:4321/auth/github/callback",
          "http://localhost:4321/other",
          "http://owner@localhost:4321/auth/github/callback",
          "http://localhost:4321/auth/github/callback?code=private",
          "http://localhost:4321/auth/github/callback#private",
          "http://localhost:0/auth/github/callback",
          "http://localhost:65536/auth/github/callback"
        ] do
      Application.put_env(:lovelace, :github_callback_url, callback)
      assert Callback.url() == nil
      refute Transport.valid_callback_uri?(callback)
    end
  end
end
