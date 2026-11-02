defmodule Lovelace.Owner.PasswordTest do
  use ExUnit.Case, async: true
  alias Lovelace.Owner.Password

  test "PBKDF2 has random salts, fixed strong cost, and preserves whitespace" do
    {:ok, first} = Password.hash(" password with spaces ")
    {:ok, second} = Password.hash(" password with spaces ")
    assert first != second
    assert String.starts_with?(first, "pbkdf2-sha256$600000$")
    assert Password.valid?(" password with spaces ", first)
    refute Password.valid?("password with spaces", first)
    refute Password.valid?("wrong", first)
  end

  test "malformed hashes and oversized input fail safely" do
    refute Password.valid?("password", "pbkdf2-sha256$1$bad$bad")
    refute Password.valid?(nil, nil)
    assert :error = Password.hash(String.duplicate("x", 1025))
  end
end
