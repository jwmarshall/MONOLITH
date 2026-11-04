defmodule LovelaceWeb.MailAttachmentController do
  use LovelaceWeb, :controller

  @max_attachment 5 * 1024 * 1024
  @preview_types %{
    "image/jpeg" => "image/jpeg",
    "image/png" => "image/png",
    "image/gif" => "image/gif",
    "image/webp" => "image/webp"
  }

  def show(conn, %{
        "account_id" => account_id,
        "thread_id" => thread_id,
        "message_id" => message_id,
        "attachment_id" => attachment_id
      }) do
    case Lovelace.Mail.attachment(
           account_id,
           thread_id,
           message_id,
           attachment_id,
           actor: %{role: :local_owner}
         ) do
      {:ok, %{bytes: bytes, filename: filename, mime_type: mime_type, size: size}}
      when is_binary(bytes) and byte_size(bytes) <= @max_attachment and size == byte_size(bytes) ->
        respond(conn, bytes, filename, mime_type, conn.params["download"] == "1")

      _ ->
        unavailable(conn)
    end
  rescue
    _ -> unavailable(conn)
  end

  defp respond(conn, bytes, filename, mime_type, download?) do
    preview_type = Map.get(@preview_types, String.downcase(mime_type))

    if not download? and preview_type do
      send_preview(conn, bytes, safe_filename(filename), preview_type)
    else
      send_attachment(conn, bytes, safe_filename(filename))
    end
  end

  defp send_preview(conn, bytes, filename, "image/jpeg") do
    conn
    |> response_headers("inline", filename)
    |> put_resp_content_type("image/jpeg", nil)
    |> send_attachment_bytes(bytes)
  end

  defp send_preview(conn, bytes, filename, "image/png") do
    conn
    |> response_headers("inline", filename)
    |> put_resp_content_type("image/png", nil)
    |> send_attachment_bytes(bytes)
  end

  defp send_preview(conn, bytes, filename, "image/gif") do
    conn
    |> response_headers("inline", filename)
    |> put_resp_content_type("image/gif", nil)
    |> send_attachment_bytes(bytes)
  end

  defp send_preview(conn, bytes, filename, "image/webp") do
    conn
    |> response_headers("inline", filename)
    |> put_resp_content_type("image/webp", nil)
    |> send_attachment_bytes(bytes)
  end

  defp send_attachment(conn, bytes, filename) do
    conn
    |> response_headers("attachment", filename)
    |> put_resp_content_type("application/octet-stream", nil)
    |> send_attachment_bytes(bytes)
  end

  defp response_headers(conn, disposition, filename) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; sandbox; frame-ancestors 'none'"
    )
    |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{filename}"))
  end

  # Reviewed Sobelow false positive: bytes are bounded and either forced to download
  # as octet-stream or served with an exact raster MIME allowlist, nosniff and sandbox CSP.
  # sobelow_skip ["XSS.SendResp"]
  defp send_attachment_bytes(conn, bytes), do: send_resp(conn, 200, bytes)

  defp safe_filename(filename) when is_binary(filename) do
    filename
    |> String.replace(~r/[^A-Za-z0-9._ -]/u, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "attachment"
      value -> value
    end
  end

  defp safe_filename(_), do: "attachment"

  defp unavailable(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(404, "Attachment unavailable")
  end
end
