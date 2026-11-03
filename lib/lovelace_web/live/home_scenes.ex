defmodule LovelaceWeb.HomeScenes do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]
  alias Lovelace.StageDesigner

  @owner %{role: :local_owner}

  def init(socket) do
    assign(socket,
      scenes: false,
      scene_data: nil,
      scene_page: 1,
      scene_loading: false,
      scene_error: false,
      scene_confirmation: false,
      scene_request_pending: false,
      scene_notice: ""
    )
  end

  def open(socket),
    do: socket |> assign(scenes: true, scene_page: 1, scene_notice: "") |> refresh()

  def leave(socket), do: assign(socket, scenes: false, scene_confirmation: false)

  def refresh(socket) do
    page = socket.assigns.scene_page

    socket
    |> assign(scene_loading: true, scene_error: false)
    |> start_async(:scene_gallery, fn ->
      StageDesigner.list_scenes(%{page: page}, actor: @owner)
    end)
  end

  def handle_event("scenes:refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("scenes:page", %{"direction" => direction}, socket) do
    data = socket.assigns.scene_data

    page =
      case direction do
        "older" when not is_nil(data) and data.has_next ->
          socket.assigns.scene_page + 1

        "newer" when not is_nil(data) and data.has_previous ->
          max(socket.assigns.scene_page - 1, 1)

        _ ->
          socket.assigns.scene_page
      end

    {:noreply, socket |> assign(scene_page: page, scene_notice: "") |> refresh()}
  end

  def handle_event("scenes:request", _params, socket) do
    eligible =
      socket.assigns.scene_data && socket.assigns.scene_data.eligible &&
        !socket.assigns.scene_loading && !socket.assigns.scene_error

    {:noreply,
     assign(socket, :scene_confirmation, !!eligible && !socket.assigns.scene_request_pending)}
  end

  def handle_event("scenes:cancel", _params, socket),
    do: {:noreply, assign(socket, :scene_confirmation, false)}

  def handle_event("scenes:confirm", _params, %{assigns: %{scene_confirmation: true}} = socket) do
    {:noreply,
     socket
     |> assign(
       scene_confirmation: false,
       scene_request_pending: true,
       scene_notice: "Requesting generation…"
     )
     |> start_async(:scene_request, fn ->
       StageDesigner.request_scene_generation(actor: @owner)
     end)}
  end

  def handle_event("scenes:select", %{"digest" => digest}, socket) do
    socket =
      case StageDesigner.select_scene(digest, actor: @owner) do
        {:ok, _} ->
          assign(socket, :scene_notice, "Scene selected.")

        _ ->
          assign(
            socket,
            :scene_notice,
            "This scene could not be selected. Refresh and try again."
          )
      end

    {:noreply, refresh(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  def handle_async(:scene_gallery, {:ok, {:ok, data}}, socket) do
    {:noreply, assign(socket, scene_data: data, scene_loading: false, scene_error: false)}
  end

  def handle_async(:scene_gallery, _result, socket) do
    {:noreply, assign(socket, scene_loading: false, scene_error: true)}
  end

  def handle_async(:scene_request, result, socket) do
    notice =
      case result do
        {:ok, {:ok, :started}} ->
          "Generation requested. You can leave this view; no automatic retries."

        {:ok, {:ok, status}} when status in [:cached, :busy] ->
          "Another attempt is already reserved or unconfirmed. No new request was made."

        _ ->
          "Generation could not be started. Check Gemini in Connections and refresh the scene status."
      end

    socket = assign(socket, scene_request_pending: false, scene_notice: notice)
    {:noreply, if(socket.assigns.scenes, do: refresh(socket), else: socket)}
  end
end
