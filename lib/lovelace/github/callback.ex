defmodule Lovelace.GitHub.Callback do
  @moduledoc "Approved OAuth callback supplied by the runtime composition root."

  def url, do: approved_url(Application.get_env(:lovelace, :github_callback_url))

  defp approved_url(value) when is_binary(value) do
    with {:ok, uri} <- URI.new(value),
         true <- approved?(uri) do
      value
    else
      _ -> nil
    end
  end

  defp approved_url(_), do: nil

  defp approved?(%URI{
         scheme: "http",
         host: "localhost",
         path: "/auth/github/callback",
         userinfo: nil,
         query: nil,
         fragment: nil,
         port: port
       }),
       do: port in 1..65_535

  defp approved?(_), do: false
end
