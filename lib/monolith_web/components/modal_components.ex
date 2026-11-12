defmodule MonolithWeb.ModalComponents do
  @moduledoc "Native modal dialogs with server-owned content and client-owned focus."
  use MonolithWeb, :html

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :on_cancel, :string, required: true
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
      data-modal
      data-cancel-event={@on_cancel}
      data-return-focus={@return_focus}
      data-initial-focus={@initial_focus}
    >
      <h3 id={"#{@id}-title"} class="monolith-modal-title">{@title}</h3>
      {render_slot(@inner_block)}
    </dialog>
    """
  end
end
