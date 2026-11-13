defmodule MonolithWeb.ErrorHTML do
  @moduledoc """
  Public HTML errors share MONOLITH's local typography and neutral working plane.
  Error details and request data are never included in the response.
  """
  use MonolithWeb, :html

  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)

    assigns = %{
      status: template |> String.split(".") |> hd(),
      title: title(template, message),
      description: description(template)
    }

    ~H"""
    <!DOCTYPE html>
    <html lang="en" data-theme="charcoal">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content="dark" />
        <title>{@title} · MONOLITH</title>
        <link rel="icon" type="image/svg+xml" href={~p"/favicon.svg"} />
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body class="public-error-page">
        <main id="main-content" class="public-error-content" aria-labelledby="error-heading">
          <p class="onboarding-eyebrow">MONOLITH / {@status}</p>
          <h1 id="error-heading">{@title}</h1>
          <p>{@description}</p>
          <a class="workspace-action workspace-action-primary" href="/">Return home</a>
        </main>
      </body>
    </html>
    """
  end

  defp title("404" <> _, _message), do: "This page is unavailable."
  defp title("500" <> _, _message), do: "This page couldn’t be opened."
  defp title(_template, message), do: message <> "."

  defp description("404" <> _),
    do: "This address doesn’t lead to an available page. Return home to choose a destination."

  defp description(_template),
    do: "The request couldn’t be completed. Return home or try again later."
end
