defmodule LovelaceWeb.HomeScenes do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [start_async: 3]
  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.DirectionOptions

  @owner %{role: :local_owner}

  def init(socket) do
    assign(socket,
      scenes: false,
      scene_data: nil,
      scene_page: 1,
      scene_loading: false,
      scene_error: false,
      scene_confirmation: false,
      scene_confirmation_prompt: nil,
      scene_direction: %{status: :loading},
      scene_request_pending: false,
      scene_notice: ""
    )
  end

  def open(socket) do
    socket
    |> assign(scenes: true, scene_page: 1, scene_notice: "", scene_direction: %{status: :loading})
    |> load_direction()
    |> refresh()
  end

  def leave(socket),
    do: assign(socket, scenes: false, scene_confirmation: false, scene_confirmation_prompt: nil)

  defp load_direction(socket) do
    start_async(socket, :scene_direction, fn -> StageDesigner.scene_direction(actor: @owner) end)
  end

  def refresh(socket) do
    page = socket.assigns.scene_page

    socket
    |> assign(scene_loading: true, scene_error: false)
    |> start_async(:scene_gallery, fn ->
      StageDesigner.list_scenes(%{page: page}, actor: @owner)
    end)
  end

  def handle_event("scenes:refresh", _params, socket) do
    socket =
      if socket.assigns.scene_direction.status == :error, do: load_direction(socket), else: socket

    {:noreply, refresh(socket)}
  end

  def handle_event("scenes:direction-change", %{"direction" => params}, socket)
      when is_map(params) do
    {:noreply, change_direction(socket, params)}
  end

  def handle_event("scenes:direction-save", %{"direction" => params}, socket)
      when is_map(params) do
    socket = change_direction(socket, params)
    direction = socket.assigns.scene_direction

    if direction.status == :ready && direction.error == "" do
      case StageDesigner.save_scene_direction(direction.values, actor: @owner) do
        {:ok, saved} ->
          {:noreply,
           assign(
             socket,
             :scene_direction,
             direction_state(saved, "Direction saved. No generation requested.")
           )}

        _ ->
          {:noreply,
           assign(socket, :scene_direction, %{
             direction
             | error:
                 "Direction couldn’t be saved. Your previous default is unchanged. Try again."
           })}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("scenes:direction-discard", _params, socket) do
    case socket.assigns.scene_direction do
      %{status: :ready, saved: saved} ->
        {:noreply, assign(socket, :scene_direction, direction_state(saved))}

      _ ->
        {:noreply, socket}
    end
  end

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
        !socket.assigns.scene_loading && !socket.assigns.scene_error &&
        direction_ready?(socket.assigns.scene_direction)

    confirmation = !!eligible && !socket.assigns.scene_request_pending

    {:noreply,
     assign(socket,
       scene_confirmation: confirmation,
       scene_confirmation_prompt: if(confirmation, do: socket.assigns.scene_direction.prompt)
     )}
  end

  def handle_event("scenes:cancel", _params, socket),
    do: {:noreply, assign(socket, scene_confirmation: false, scene_confirmation_prompt: nil)}

  def handle_event("scenes:confirm", _params, %{assigns: %{scene_confirmation: true}} = socket) do
    prompt = socket.assigns.scene_confirmation_prompt

    {:noreply,
     socket
     |> assign(
       scene_confirmation: false,
       scene_confirmation_prompt: nil,
       scene_request_pending: true,
       scene_notice: "Requesting generation…"
     )
     |> start_async(:scene_request, fn ->
       StageDesigner.request_scene_generation(%{expected_prompt: prompt}, actor: @owner)
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

  def handle_async(:scene_direction, {:ok, {:ok, data}}, %{assigns: %{scenes: true}} = socket) do
    {:noreply, assign(socket, :scene_direction, direction_state(data))}
  end

  def handle_async(:scene_direction, _result, %{assigns: %{scenes: true}} = socket) do
    {:noreply, assign(socket, :scene_direction, %{status: :error})}
  end

  def handle_async(:scene_direction, _result, socket), do: {:noreply, socket}

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

        {:ok, {:ok, :direction_changed}} ->
          "The saved direction changed in another view. Review your direction before generating. No request was made."

        {:ok, {:ok, status}} when status in [:cached, :busy] ->
          "Another attempt is already reserved or unconfirmed. No new request was made."

        _ ->
          "Generation could not be started. Check Gemini in Connections and refresh the scene status."
      end

    socket = assign(socket, scene_request_pending: false, scene_notice: notice)

    socket =
      if result == {:ok, {:ok, :direction_changed}} && socket.assigns.scenes &&
           direction_ready?(socket.assigns.scene_direction) do
        socket |> assign(:scene_direction, %{status: :loading}) |> load_direction()
      else
        socket
      end

    {:noreply, if(socket.assigns.scenes, do: refresh(socket), else: socket)}
  end

  defp direction_ready?(%{status: :ready, dirty: false, error: ""}), do: true
  defp direction_ready?(_), do: false

  defp direction_state(saved, notice \\ "") do
    %{
      status: :ready,
      saved: saved,
      values: saved.values,
      form: direction_form(saved.values),
      prompt: saved.prompt,
      dirty: false,
      error: "",
      notice: notice
    }
  end

  defp direction_form(values) do
    values
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> to_form(as: :direction)
  end

  defp change_direction(
         %{assigns: %{scene_direction: %{status: :ready} = direction}} = socket,
         params
       ) do
    values =
      Map.new(DirectionOptions.fields(), fn field ->
        {field.key, params[Atom.to_string(field.key)]}
      end)

    valid? =
      Enum.all?(DirectionOptions.fields(), fn field ->
        Enum.any?(field.options, fn {_label, value} -> values[field.key] == value end)
      end)

    if valid? do
      dirty = values != direction.saved.values || !direction.saved.saved?
      prompt = if dirty, do: DirectionOptions.compose(values), else: direction.saved.prompt

      assign(socket,
        scene_direction: %{
          direction
          | values: values,
            form: direction_form(values),
            prompt: prompt,
            dirty: dirty,
            error: "",
            notice: ""
        },
        scene_confirmation: false,
        scene_confirmation_prompt: nil
      )
    else
      assign(socket, :scene_direction, %{
        direction
        | error: "Choose one of the available options for each field.",
          notice: ""
      })
    end
  end

  defp change_direction(socket, _params), do: socket
end
