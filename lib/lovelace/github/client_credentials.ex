defmodule Lovelace.GitHub.ClientCredentials do
  @moduledoc "GitHub App client configuration stored only in the dedicated unlocked vault."
  alias Lovelace.GitHub.Operations
  alias Lovelace.Security.Vault
  @account "2fc350e8-33e5-4fd8-9c90-adbb609c742b"

  def current do
    access(fn ->
      with {:ok, json} when is_binary(json) and byte_size(json) <= 16_384 <-
             keychain().get(@account),
           {:ok,
            %{
              "client_id" => id,
              "client_secret" => secret,
              "app_slug" => slug,
              "generation" => generation
            }} <- Jason.decode(json),
           :ok <- validate(id, secret, slug),
           {:ok, _} <- Ecto.UUID.cast(generation) do
        {:ok, %{client_id: id, client_secret: secret, app_slug: slug, generation: generation}}
      else
        {:error, :locked} -> {:error, :locked}
        {:error, :not_found} -> {:error, :configuration}
        _ -> {:error, :keychain}
      end
    end)
  end

  def status do
    case current() do
      {:ok, client} ->
        {:ok, %{configured?: true, client_id: client.client_id, app_slug: client.app_slug}}

      {:error, :configuration} ->
        {:ok, %{configured?: false, client_id: nil, app_slug: nil}}

      error ->
        error
    end
  end

  def save(id, secret, slug) do
    with :ok <- validate(id, secret, slug) do
      access(fn -> save_locked(id, secret, slug) end)
    end
  end

  defp save_locked(id, secret, slug) do
    :global.trans(
      {{Operations, :state}, self()},
      fn -> store_if_changed(id, secret, slug) end,
      [node()]
    )
  end

  defp store_if_changed(id, secret, slug) do
    case current() do
      {:ok, %{client_id: ^id, client_secret: ^secret, app_slug: ^slug}} -> :ok
      _ -> store(id, secret, slug)
    end
  end

  defp store(id, secret, slug) do
    json =
      Jason.encode!(%{
        client_id: id,
        client_secret: secret,
        app_slug: slug,
        generation: Ash.UUID.generate()
      })

    case keychain().put(@account, json) do
      :ok -> Operations.client_changed()
      _ -> {:error, :keychain}
    end
  end

  defp validate(id, secret, slug) do
    if is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_.-]{1,128}\z/, id) and
         is_binary(secret) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,1024}\z/, secret) and
         is_binary(slug) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,99}\z/, slug),
       do: :ok,
       else: {:error, :configuration}
  end

  defp keychain,
    do: Application.get_env(:lovelace, :github_keychain, Lovelace.Integrations.GitHub.Keychain)

  defp access(fun) do
    Vault.with_access(fun)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
