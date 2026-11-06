defmodule Lovelace.StageDesigner.Confirmation do
  @moduledoc """
  Confirmation capability for a complete paid-render request snapshot.

  Composition supplies `:scene_confirmation` as `{adapter, options}`. Adapters
  must authenticate the entire snapshot, use the scene-generation-v1 purpose,
  expire tokens after ten minutes and reject malformed/tampered tokens. The
  workflow retains idempotency, current-direction and reservation-version checks.
  Missing signing configuration fails closed; no core web dependency is needed.
  """

  @callback sign(map(), keyword()) :: {:ok, binary()} | {:error, :unavailable}
  @callback verify(binary(), keyword()) :: {:ok, map()} | {:error, :invalid_confirmation}

  def sign(snapshot), do: invoke(:sign, snapshot, :unavailable)
  def verify(token), do: invoke(:verify, token, :invalid_confirmation)

  defp invoke(operation, value, failure) do
    with {adapter, options} <- Application.get_env(:lovelace, :scene_confirmation),
         result <- apply(adapter, operation, [value, options]) do
      case {operation, result} do
        {:sign, {:ok, token}} when is_binary(token) -> {:ok, token}
        {:verify, {:ok, snapshot}} when is_map(snapshot) -> {:ok, snapshot}
        _ -> {:error, failure}
      end
    else
      _ -> {:error, failure}
    end
  rescue
    _ -> {:error, failure}
  catch
    _, _ -> {:error, failure}
  end
end
