defmodule MonolithWeb.ModalComponents do
  @moduledoc "Native modal dialogs with server-owned content and client-owned focus."
  use MonolithWeb, :html

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_cancel, :string, default: nil
  attr :open_on_mount, :boolean, default: true
  attr :return_focus, :string, required: true
  attr :initial_focus, :string, required: true
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class="monolith-modal"
      aria-labelledby={"#{@id}-title"}
      phx-hook="NativeModal"
      data-modal={if @open_on_mount, do: "", else: nil}
      data-cancel-event={@on_cancel}
      data-open-on-mount={to_string(@open_on_mount)}
      data-return-focus={@return_focus}
      data-initial-focus={@initial_focus}
    >
      <h3 id={"#{@id}-title"} class="monolith-modal-title">{@title}</h3>
      {render_slot(@inner_block)}
    </dialog>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :trigger, :string, required: true
  attr :action, :string, required: true
  attr :form_id, :string, required: true
  attr :initial_focus, :string, required: true
  attr :save, :string, required: true
  attr :primary, :boolean, default: false
  slot :inner_block, required: true

  def credential_modal(assigns) do
    ~H"""
    <button
      id={"#{@id}-trigger"}
      type="button"
      class={["workspace-action", @primary && "workspace-action-primary"]}
      aria-haspopup="dialog"
      aria-controls={@id}
      phx-click={JS.dispatch("monolith:modal-open", to: "##{@id}")}
    >{@trigger}</button>
    <.modal
      id={@id}
      title={@title}
      open_on_mount={false}
      return_focus={"##{@id}-trigger"}
      initial_focus={@initial_focus}
    >
      <.form
        for={%{}}
        id={@form_id}
        action={@action}
        method="post"
        autocomplete="off"
        class="credential-form"
        phx-update="ignore"
      >
        {render_slot(@inner_block)}
        <div class="workspace-editor-actions">
          <button type="submit" class="workspace-action workspace-action-primary">{@save}</button>
          <button
            type="button"
            class="workspace-action"
            phx-click={JS.dispatch("monolith:modal-close", to: "##{@id}")}
          >Cancel</button>
        </div>
      </.form>
    </.modal>
    """
  end
end
