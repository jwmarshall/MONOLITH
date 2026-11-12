defmodule Monolith.ConnectionDiagnostics do
  @moduledoc "Bounded, job-owned local keychain diagnostics for Google, Gemini and GitHub."
  use Ash.Domain

  resources do
    resource Monolith.ConnectionDiagnostics.Operation do
      define :request, action: :request, args: [:provider]
      define :observe, action: :observe, args: [:provider, :id]
    end

    resource Monolith.ConnectionDiagnostics.State
  end

  @doc false
  def serial(provider, fun) when provider in [:google, :gemini, :github] do
    :global.trans({{__MODULE__, provider}, self()}, fun, [node()])
  end

  @doc "Invalidates old diagnostics before credential changes; caller holds serial/2."
  defdelegate invalidate(provider), to: Monolith.ConnectionDiagnostics.Operations
end
