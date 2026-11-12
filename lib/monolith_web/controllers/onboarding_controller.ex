defmodule MonolithWeb.OnboardingController do
  use MonolithWeb, :controller

  alias Monolith.Onboarding
  alias Monolith.Onboarding.CalendarSetup

  plug :private_page

  def index(conn, _params) do
    case Onboarding.progress(actor: conn.assigns.current_actor) do
      {:ok, nil} -> redirect(conn, to: Onboarding.path(:workspace))
      {:ok, state} -> redirect(conn, to: Onboarding.path(state.step))
      _ -> render_step(conn, :workspace, 503, :unavailable)
    end
  end

  def show(conn, %{"step" => value} = params) do
    case Onboarding.parse_step(value) do
      nil ->
        send_resp(conn, 404, "Setup page not found")

      step ->
        render_step(conn, step, 200, notice(params["notice"]), %{
          calendar_status_only?: params["status"] == "1"
        })
    end
  end

  def update(conn, %{"step" => value} = params) do
    update_step(conn, Onboarding.parse_step(value), params)
  end

  defp update_step(conn, :workspace, %{"operation" => "save_workspace", "name" => name})
       when is_binary(name) do
    case Onboarding.save_workspace(name, actor: conn.assigns.current_actor) do
      {:ok, state} -> redirect(conn, to: Onboarding.path(state.step))
      _ -> render_step(conn, :workspace, 422, :workspace, %{name: name})
    end
  end

  defp update_step(conn, :calendar, %{"operation" => operation} = params)
       when operation in ["load_calendars", "refresh_calendars"] do
    result =
      CalendarSetup.prepare(
        params["account_id"],
        params["generation"],
        Map.take(params, ["from", "to", "date", "timezone"]),
        actor: conn.assigns.current_actor,
        workspace_id: params["workspace_id"],
        refresh?: operation == "refresh_calendars"
      )

    calendar_result(conn, result, nil, :calendar_load)
  end

  defp update_step(conn, :calendar, %{"operation" => "select_calendars"} = params) do
    ids = Map.get(params, "calendar_ids", [])
    ids = if is_list(ids), do: Enum.reject(ids, &(&1 == "")), else: ids

    result =
      CalendarSetup.select(params["account_id"], params["generation"], ids,
        actor: conn.assigns.current_actor,
        workspace_id: params["workspace_id"]
      )

    calendar_result(conn, result, "calendars_saved", :calendar_selection)
  end

  defp update_step(conn, :complete, %{"operation" => "finish"}) do
    case Onboarding.finish(actor: conn.assigns.current_actor) do
      {:ok, _} -> redirect(conn, to: "/")
      {:error, :workspace_required} -> redirect(conn, to: Onboarding.path(:workspace))
      _ -> render_step(conn, :complete, 503, :unavailable)
    end
  end

  defp update_step(conn, step, %{"operation" => "skip"})
       when step in [:project, :authentication, :audience, :client, :connect, :calendar] do
    case Onboarding.skip(step, actor: conn.assigns.current_actor) do
      {:ok, state} -> redirect(conn, to: Onboarding.path(state.step))
      {:error, :workspace_required} -> redirect(conn, to: Onboarding.path(:workspace))
      _ -> render_step(conn, step, 503, :unavailable)
    end
  end

  defp update_step(conn, step, %{"operation" => "continue"})
       when step in [:project, :authentication, :audience, :client, :connect, :calendar] do
    case Onboarding.continue(step, actor: conn.assigns.current_actor) do
      {:ok, state} -> redirect(conn, to: Onboarding.path(state.step))
      {:error, :workspace_required} -> redirect(conn, to: Onboarding.path(:workspace))
      {:error, :save_credentials_first} -> render_step(conn, step, 422, :credentials)
      _ -> render_step(conn, step, 503, :unavailable)
    end
  end

  defp update_step(conn, _, _), do: send_resp(conn, 400, "Unable to update setup progress")

  defp calendar_result(conn, {:ok, _}, notice, _) do
    path = Onboarding.path(:calendar)
    redirect(conn, to: if(notice, do: path <> "?notice=" <> notice, else: path))
  end

  defp calendar_result(conn, _, _, error), do: render_step(conn, :calendar, 422, error)

  defp render_step(conn, step, status, error, values \\ %{}) do
    actor = conn.assigns.current_actor

    case {Onboarding.progress(actor: actor), Onboarding.workspace(actor: actor)} do
      {{:ok, _}, {:ok, nil}} when step != :workspace ->
        redirect(conn, to: Onboarding.path(:workspace))

      {{:ok, progress}, {:ok, workspace}} ->
        connection =
          if step in [:connect, :calendar, :complete],
            do: Onboarding.connection(actor: actor),
            else: {:ok, nil}

        calendar = calendar_context(step, connection, workspace, actor)

        conn
        |> put_status(status)
        |> put_layout(false)
        |> render(:show,
          step: step,
          progress: progress,
          connection: connection,
          workspace: workspace,
          workspace_name: Map.get(values, :name, workspace && workspace.name),
          calendar: calendar,
          calendar_status_only?: Map.get(values, :calendar_status_only?, false),
          error: error,
          first_run_entrance?: conn.method == "GET" && is_nil(error),
          csrf_token: get_csrf_token(),
          background: background()
        )

      _ ->
        conn
        |> put_status(503)
        |> text("Local setup progress is unavailable. Please unlock again.")
    end
  end

  defp calendar_context(
         :calendar,
         {:ok, %{id: account_id, generation: generation}},
         %{id: workspace_id},
         actor
       ) do
    case CalendarSetup.read(actor: actor) do
      {:ok, %{workspace_id: ^workspace_id, account_id: ^account_id, generation: ^generation}} =
          result ->
        result

      {:ok, _} ->
        {:error, :stale_connection}

      error ->
        error
    end
  end

  defp calendar_context(:calendar, _connection, _workspace, _actor),
    do: {:error, :stale_connection}

  defp calendar_context(_step, _connection, _workspace, _actor), do: {:ok, nil}

  defp background do
    case Monolith.StageDesigner.background() do
      {:ok, background} -> background
      _ -> %{url: nil, status: :unavailable}
    end
  end

  defp notice("save_failed"), do: :credentials
  defp notice("connection_failed"), do: :connection
  defp notice("calendar_failed"), do: :calendar
  defp notice("calendars_saved"), do: :calendars_saved
  defp notice(_), do: nil

  defp private_page(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
