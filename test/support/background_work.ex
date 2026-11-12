defmodule Monolith.TestSupport.BackgroundWork do
  @moduledoc false

  def complete(view) do
    # Test callers configure fake providers. Never drain :gemini here: waiting for
    # a readout must not execute a paid render. OAuth one-shot jobs remain explicit.
    Enum.each(1..3, fn _ ->
      Oban.drain_queue(queue: :diagnostics, with_scheduled: true)
      Oban.drain_queue(queue: :gmail, with_scheduled: true)
      assigns = :sys.get_state(view.pid).socket.assigns

      for {provider, key} <- [
            google: :google_diagnostic,
            gemini: :gemini_diagnostic,
            github: :github_diagnostic
          ],
          %{token: token} <- [assigns[key]] do
        send(view.pid, {:connection_diagnostic, provider, token})
      end

      for id <- mail_operations(assigns[:mail]), do: send(view.pid, {:mail_operation, id})
      Phoenix.LiveViewTest.render(view)
    end)

    Phoenix.LiveViewTest.render(view)
  end

  defp mail_operations(nil), do: []

  defp mail_operations(mail) do
    [mail[:task], command_id(mail[:command]), credential_id(mail[:credential_check])]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp command_id({_account, id}), do: id
  defp command_id(_), do: nil
  defp credential_id({_account, _generation, id}), do: id
  defp credential_id(_), do: nil
end
