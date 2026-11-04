defmodule LovelaceWeb.OnboardingController do
  use LovelaceWeb, :controller

  alias Lovelace.Onboarding

  plug :private_page

  def index(conn, _params) do
    case Onboarding.progress(actor: conn.assigns.current_actor) do
      {:ok, nil} -> redirect(conn, to: Onboarding.path(:project))
      {:ok, state} -> redirect(conn, to: Onboarding.path(state.step))
      _ -> render_step(conn, :project, 503, :unavailable)
    end
  end

  def show(conn, %{"step" => value} = params) do
    case Onboarding.parse_step(value) do
      nil -> send_resp(conn, 404, "Setup page not found")
      step -> render_step(conn, step, 200, notice(params["notice"]))
    end
  end

  def update(conn, %{"step" => value} = params) do
    actor = conn.assigns.current_actor

    case {Onboarding.parse_step(value), params["operation"]} do
      {:complete, "finish"} ->
        case Onboarding.finish(actor: actor) do
          {:ok, _} -> redirect(conn, to: "/")
          _ -> render_step(conn, :complete, 503, :unavailable)
        end

      {step, "continue"} when step in [:project, :authentication, :audience, :client, :connect] ->
        case Onboarding.continue(step, actor: actor) do
          {:ok, state} -> redirect(conn, to: Onboarding.path(state.step))
          {:error, :save_credentials_first} -> render_step(conn, step, 422, :credentials)
          _ -> render_step(conn, step, 503, :unavailable)
        end

      _ ->
        send_resp(conn, 400, "Unable to update setup progress")
    end
  end

  defp render_step(conn, step, status, error) do
    actor = conn.assigns.current_actor

    case Onboarding.progress(actor: actor) do
      {:ok, nil} when step in [:connect, :complete] ->
        redirect(conn, to: Onboarding.path(:project))

      {:ok, progress} ->
        connection =
          if step in [:connect, :complete],
            do: Onboarding.connection(actor: actor),
            else: {:ok, nil}

        workspace = workspace(step, actor)

        conn
        |> put_status(status)
        |> put_layout(false)
        |> render(:show,
          step: step,
          progress: progress,
          connection: connection,
          workspace: workspace,
          error: error,
          csrf_token: get_csrf_token(),
          background: background()
        )

      _ ->
        conn
        |> put_status(503)
        |> text("Local setup progress is unavailable. Please unlock again.")
    end
  end

  defp workspace(step, actor) when step in [:connect, :complete] do
    case Lovelace.Workspaces.get_workspace(Onboarding.personal_workspace_id(), actor: actor) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  defp workspace(_, _), do: nil

  defp background do
    case Lovelace.StageDesigner.background() do
      {:ok, background} -> background
      _ -> %{url: nil, status: :unavailable}
    end
  end

  defp notice("save_failed"), do: :credentials
  defp notice(_), do: nil

  defp private_page(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
