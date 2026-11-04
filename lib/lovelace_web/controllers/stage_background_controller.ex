defmodule LovelaceWeb.StageBackgroundController do
  use LovelaceWeb, :controller

  alias Lovelace.Security.Vault
  alias Lovelace.StageDesigner.Image
  alias LovelaceWeb.Plugs.OwnerRequest

  def show(conn, %{"filename" => filename}) do
    with {:ok, lease} <- Vault.track(),
         :ok <- OwnerRequest.retain(lease),
         [_, digest, extension] <- Regex.run(~r/\A([0-9a-f]{64})\.(png|jpg)\z/, filename),
         {:ok, bytes} <- Lovelace.StageDesigner.image(digest),
         format = Image.format(bytes),
         true <- Image.extension(format) == extension do
      conn
      |> put_resp_header("cache-control", "private, max-age=86400, immutable")
      |> put_resp_header(
        "content-disposition",
        ~s(inline; filename="lovelace-background.#{extension}")
      )
      |> send_image(bytes, format)
    else
      _ ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(404, "Background unavailable")
    end
  end

  # Literal allowlisted content types keep untrusted bytes out of executable contexts.
  defp send_image(conn, bytes, :png) do
    conn |> put_resp_content_type("image/png", nil) |> send_resp(200, bytes)
  end

  defp send_image(conn, bytes, :jpeg) do
    conn |> put_resp_content_type("image/jpeg", nil) |> send_resp(200, bytes)
  end
end
