defmodule Lovelace.Owner.Password do
  @moduledoc "PBKDF2-SHA256 hash provider for AshAuthentication (600,000 iterations)."
  @behaviour AshAuthentication.HashProvider
  @iterations 600_000
  @max_bytes 1024

  @impl true
  def hash(password) when is_binary(password) and byte_size(password) <= @max_bytes do
    salt = :crypto.strong_rand_bytes(16)
    digest = derive(password, salt)
    {:ok, "pbkdf2-sha256$#{@iterations}$#{Base.encode64(salt)}$#{Base.encode64(digest)}"}
  end

  def hash(_), do: :error

  @impl true
  def valid?(password, encoded)
      when is_binary(password) and byte_size(password) <= @max_bytes and is_binary(encoded) do
    with ["pbkdf2-sha256", "600000", salt, expected] <- String.split(encoded, "$"),
         {:ok, salt} when byte_size(salt) == 16 <- Base.decode64(salt),
         {:ok, expected} when byte_size(expected) == 32 <- Base.decode64(expected) do
      Plug.Crypto.secure_compare(derive(password, salt), expected)
    else
      _ -> simulate()
    end
  end

  def valid?(_, _), do: simulate()

  @impl true
  def simulate do
    derive("invalid local unlock", <<0::128>>)
    false
  end

  defp derive(password, salt),
    do: :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, 32)
end
