defmodule LovelaceWeb.HomeScenes do
  @moduledoc false
  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [start_async: 3, cancel_async: 2]
  alias Lovelace.StageDesigner
  alias Lovelace.StageDesigner.{DirectionOptions, Models}

  @owner %{role: :local_owner}

  def init(socket) do
    assign(socket,
      scenes: false,
      scene_data: nil,
      scene_page: 1,
      scene_attempt_page: 1,
      scene_settings: settings_state(Models.defaults()),
      scene_preparing: false,
      scene_prepared: nil,
      scene_acknowledgement: nil,
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
    |> assign(
      scenes: true,
      scene_page: 1,
      scene_attempt_page: 1,
      scene_notice: "",
      scene_direction: %{status: :loading}
    )
    |> LovelaceWeb.HomeGemini.open()
    |> load_direction()
    |> refresh()
  end

  def leave(socket) do
    socket
    |> clear_confirmation()
    |> assign(scenes: false, scene_acknowledgement: nil)
  end

  defp load_direction(socket) do
    start_async(socket, :scene_direction, fn -> StageDesigner.scene_direction(actor: @owner) end)
  end

  def refresh(socket) do
    page = socket.assigns.scene_page
    attempt_page = socket.assigns.scene_attempt_page

    socket
    |> assign(scene_loading: true, scene_error: false)
    |> start_async(:scene_gallery, fn ->
      StageDesigner.list_scenes(%{page: page, attempt_page: attempt_page}, actor: @owner)
    end)
  end

  def handle_event("scenes:refresh", _params, %{assigns: %{scene_loading: true}} = socket),
    do: {:noreply, socket}

  def handle_event(
        "scenes:refresh",
        _params,
        %{assigns: %{gemini_status: :rechecking}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("scenes:refresh", _params, socket) do
    socket =
      if socket.assigns.scene_direction.status == :error, do: load_direction(socket), else: socket

    # Keep the editor mounted, but do not treat the last successful check as authorization.
    status = if socket.assigns.gemini_status == :stored, do: :rechecking, else: :loading

    {:noreply,
     socket
     |> clear_confirmation()
     |> LovelaceWeb.HomeGemini.open()
     |> assign(:gemini_status, status)
     |> refresh()}
  end

  def handle_event(event, _params, %{assigns: %{gemini_status: status}} = socket)
      when status != :stored and
             event in [
               "scenes:request",
               "scenes:confirm",
               "scenes:check",
               "scenes:acknowledge",
               "scenes:acknowledge-confirm"
             ],
      do: {:noreply, socket}

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
        {:noreply,
         socket |> clear_confirmation() |> assign(:scene_direction, direction_state(saved))}

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

  def handle_event("scenes:attempt-page", %{"direction" => direction}, socket) do
    data = socket.assigns.scene_data || %{}

    page =
      case direction do
        "older" ->
          if Map.get(data, :attempts_has_next, false),
            do: socket.assigns.scene_attempt_page + 1,
            else: socket.assigns.scene_attempt_page

        "newer" ->
          if Map.get(data, :attempts_has_previous, false),
            do: max(socket.assigns.scene_attempt_page - 1, 1),
            else: socket.assigns.scene_attempt_page

        _ ->
          socket.assigns.scene_attempt_page
      end

    {:noreply, socket |> assign(scene_attempt_page: page) |> refresh()}
  end

  def handle_event("scenes:settings-change", %{"generation" => params}, socket)
      when is_map(params) do
    {:noreply, change_settings(socket, params)}
  end

  def handle_event("scenes:request", params, socket) do
    socket =
      case params do
        %{"generation" => values} when is_map(values) -> change_settings(socket, values)
        %{"generation" => _invalid} -> change_settings(socket, %{})
        _ -> socket
      end

    if request_ready?(socket.assigns) do
      settings = socket.assigns.scene_settings.values

      {:noreply,
       socket
       |> clear_confirmation()
       |> assign(scene_preparing: true, scene_notice: "Preparing confirmation…")
       |> start_async(:scene_prepare, fn ->
         StageDesigner.prepare_scene_generation(settings, actor: @owner)
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("scenes:cancel", _params, socket),
    do: {:noreply, clear_confirmation(socket)}

  def handle_event(
        "scenes:confirm",
        _params,
        %{assigns: %{scene_confirmation: true, scene_prepared: %{confirmation: token}}} = socket
      ) do
    {:noreply,
     socket
     |> clear_confirmation()
     |> assign(scene_request_pending: true, scene_notice: "Requesting generation…")
     |> start_async(:scene_request, fn ->
       StageDesigner.request_scene_generation(%{confirmation: token}, actor: @owner)
     end)}
  end

  def handle_event("scenes:check", %{"id" => id}, socket) do
    case find_attempt(socket, id) do
      %{status: status} when status in [:tracking_paused, :rendering] ->
        {:noreply, check_attempt(socket, id, :tracking)}

      %{status: :completed, cleanup: :failed} ->
        {:noreply, check_attempt(socket, id, :cleanup)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("scenes:acknowledge", %{"id" => id} = params, socket) do
    case find_attempt(socket, id) do
      %{status: :unknown} ->
        origin = if params["origin"] == "current", do: "current", else: "history"

        {:noreply,
         assign(socket,
           scene_acknowledgement: %{
             id: id,
             return_focus: "#scene-#{origin}-acknowledge-#{id}"
           }
         )}

      %{status: :failed} ->
        {:noreply, acknowledge(socket, id)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("scenes:acknowledge-cancel", _params, socket),
    do: {:noreply, assign(socket, scene_acknowledgement: nil)}

  def handle_event("scenes:acknowledge-confirm", _params, socket) do
    if socket.assigns.scene_acknowledgement,
      do: {:noreply, acknowledge(socket, socket.assigns.scene_acknowledgement.id)},
      else: {:noreply, socket}
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

  def handle_async(
        :scene_prepare,
        {:ok, {:ok, %{confirmation: token, prompt: prompt} = prepared}},
        %{assigns: %{scenes: true, scene_preparing: true}} = socket
      )
      when is_binary(token) and is_binary(prompt) do
    {:noreply,
     assign(socket,
       scene_preparing: false,
       scene_prepared: prepared,
       scene_confirmation: true,
       scene_confirmation_prompt: prompt,
       scene_notice: ""
     )}
  end

  def handle_async(:scene_prepare, _result, %{assigns: %{scene_preparing: true}} = socket) do
    {:noreply,
     assign(socket,
       scene_preparing: false,
       scene_notice:
         "Confirmation couldn’t be prepared. Check the model, ratio and size, then try again. No generation was requested."
     )}
  end

  def handle_async(:scene_prepare, _result, socket), do: {:noreply, socket}

  def handle_async(:scene_request, result, socket) do
    notice =
      case result do
        {:ok, {:ok, :started}} ->
          "Generation requested. You can leave this view; no automatic retries."

        {:ok, {:ok, :direction_changed}} ->
          "The saved direction changed in another view. Review your direction before generating. No request was made."

        {:ok, {:ok, :invalid_confirmation}} ->
          "This confirmation is invalid or expired. Review your settings and confirm again. No new request was made."

        {:ok, {:ok, status}} when status in [:cached, :busy] ->
          "Another attempt is already reserved or unconfirmed. No new request was made."

        _ ->
          "Generation could not be started. Check Gemini in Connections and refresh the scene status."
      end

    socket = assign(socket, scene_request_pending: false, scene_notice: notice)

    socket = handle_direction_changed(socket, result)

    {:noreply, if(socket.assigns.scenes, do: refresh(socket), else: socket)}
  end

  defp request_ready?(%{
         scene_data: %{eligible: true},
         scene_loading: false,
         scene_error: false,
         scene_request_pending: false,
         scene_preparing: false,
         scene_settings: %{error: ""},
         scene_direction: direction
       }),
       do: direction_ready?(direction)

  defp request_ready?(_assigns), do: false

  defp handle_direction_changed(
         %{assigns: %{scenes: true}} = socket,
         {:ok, {:ok, :direction_changed}}
       ) do
    if direction_ready?(socket.assigns.scene_direction),
      do: socket |> assign(:scene_direction, %{status: :loading}) |> load_direction(),
      else: socket
  end

  defp handle_direction_changed(socket, _result), do: socket

  defp check_attempt(socket, id, operation) do
    notice =
      case {StageDesigner.check_scene_attempt(%{id: id}, actor: @owner), operation} do
        {{:ok, :scheduled}, :cleanup} ->
          "Google deletion retry scheduled. This does not generate another image."

        {{:ok, :scheduled}, :tracking} ->
          "Status check scheduled. This does not generate another image."

        _ ->
          "Recovery could not be scheduled. Refresh local status and try again. No generation was requested."
      end

    socket |> assign(scene_notice: notice) |> refresh()
  end

  defp clear_confirmation(socket) do
    socket
    |> cancel_async(:scene_prepare)
    |> assign(
      scene_preparing: false,
      scene_prepared: nil,
      scene_confirmation: false,
      scene_confirmation_prompt: nil
    )
  end

  defp settings_state(values) do
    valid? =
      values.model in Enum.map(Models.options(), &elem(&1, 1)) &&
        values.aspect_ratio in Models.ratios() && values.image_size in Models.sizes()

    %{
      values: values,
      form:
        to_form(Map.new(values, fn {key, value} -> {Atom.to_string(key), value} end),
          as: :generation
        ),
      error: if(valid?, do: "", else: "Choose an available model, aspect ratio and image size.")
    }
  end

  defp change_settings(socket, params) do
    values = Map.new([:model, :aspect_ratio, :image_size], &{&1, params[Atom.to_string(&1)]})
    socket |> clear_confirmation() |> assign(:scene_settings, settings_state(values))
  end

  defp find_attempt(%{assigns: %{scene_data: nil}}, _id), do: nil

  defp find_attempt(socket, id) do
    data = socket.assigns.scene_data
    attempts = [Map.get(data, :attempt) | Map.get(data, :attempts, [])]

    Enum.find(attempts, &(is_map(&1) && &1.id == id)) ||
      if(id == "legacy" && data.status == :uncertain && is_nil(Map.get(data, :attempt)),
        do: %{id: "legacy", status: :unknown}
      )
  end

  defp acknowledge(socket, id) do
    notice =
      case StageDesigner.acknowledge_scene_attempt(%{id: id}, actor: @owner) do
        {:ok, :acknowledged} ->
          "Attempt acknowledged. History is retained. No generation was requested."

        _ ->
          "This attempt could not be acknowledged. Refresh status and try again."
      end

    socket |> assign(scene_acknowledgement: nil, scene_notice: notice) |> refresh()
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

    socket = clear_confirmation(socket)

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
