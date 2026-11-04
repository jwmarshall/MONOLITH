defmodule LovelaceWeb.SetupController do
  use LovelaceWeb, :controller
  alias Lovelace.Security.{Bootstrap, Vault}

  def show(conn, params) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

    if configuration_status() in [:new, :setup_incomplete] do
      conn
      |> put_layout(false)
      |> render(:show,
        paired?: Bootstrap.paired?(get_session(conn, :bootstrap_capability)),
        interrupted?: configuration_status() == :setup_incomplete,
        error: error_message(params["error"]),
        csrf_token: get_csrf_token()
      )
    else
      redirect(conn, to: "/unlock")
    end
  end

  if Mix.env() == :test do
    defp configuration_status do
      if Vault.enabled?(),
        do: Vault.configuration_status(),
        else: if(match?({:ok, true}, Lovelace.Owner.configured()), do: :configured, else: :new)
    end
  else
    defp configuration_status, do: Vault.configuration_status()
  end

  defp error_message("pairing"),
    do:
      "That pairing code is invalid, expired or already used. Check the launching terminal; restart the server for a new code."

  defp error_message("password"), do: "Use 12–1024 characters and at most 1024 UTF-8 bytes."
  defp error_message("confirmation"), do: "Passwords did not match. Enter both again."

  defp error_message("acknowledgement"),
    do: "Confirm that you understand there is no password recovery."

  defp error_message("setup"),
    do:
      "Setup did not finish. Existing files are preserved. Retry with the same password; if pairing expired, restart the server. Do not delete or reset storage."

  defp error_message(_), do: nil
end
