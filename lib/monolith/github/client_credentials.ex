defmodule Monolith.GitHub.ClientCredentials do
  @moduledoc "GitHub App client configuration stored only in the dedicated unlocked vault."
  alias Monolith.GitHub.{Coordination, Credentials}
  alias Monolith.Security.Vault
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
    slug = normalize_slug(slug)

    with :ok <- validate(id, secret, slug) do
      access(fn -> save_locked(id, secret, slug) end)
    end
  end

  defp save_locked(id, secret, slug) do
    Coordination.state(fn -> save_diagnostic(id, secret, slug) end)
  end

  defp save_diagnostic(id, secret, slug) do
    Monolith.ConnectionDiagnostics.serial(:github, fn -> save_current(id, secret, slug) end)
  end

  defp save_current(id, secret, slug) do
    with :ok <- Monolith.ConnectionDiagnostics.invalidate(:github) do
      store_if_changed(id, secret, slug)
    end
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
      :ok -> Credentials.client_changed()
      _ -> {:error, :keychain}
    end
  end

  defp normalize_slug("https://github.com/apps/" <> _ = url) do
    case Regex.run(~r/\Ahttps:\/\/github\.com\/apps\/([a-z0-9][a-z0-9-]{0,99})\/?\z/, url,
           capture: :all_but_first
         ) do
      [slug] -> slug
      _ -> url
    end
  end

  defp normalize_slug(slug), do: slug

  defp validate(id, secret, slug) do
    cond do
      !is_binary(id) || !Regex.match?(~r/\A[A-Za-z0-9_.-]{1,128}\z/, id) ->
        {:error, :invalid_client_id}

      !is_binary(secret) || !Regex.match?(~r/\A[A-Za-z0-9_-]{1,1024}\z/, secret) ->
        {:error, :invalid_client_secret}

      !is_binary(slug) || !Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,99}\z/, slug) ->
        {:error, :invalid_app_slug}

      true ->
        :ok
    end
  end

  defp keychain,
    do: Application.get_env(:monolith, :github_keychain, Monolith.Integrations.GitHub.Keychain)

  defp access(fun) do
    Vault.with_access(fun)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
