defmodule Lovelace.StageDesigner.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Lovelace.StageDesigner.Diagnostics

  test "explains HTTP codes, configuration problems, and connection failures" do
    assert Diagnostics.describe(:provider, {:http_error, 429, :resource_exhausted}) =~
             "HTTP 429 (resource_exhausted)"

    assert Diagnostics.describe(:provider, {:http_error, 403, :billing_disabled}) =~
             "billing is disabled"

    assert Diagnostics.describe(:provider, {:http_error, 404, nil}) =~ "configured model"
    assert Diagnostics.describe(:provider, {:http_error, 400, nil}) =~ "request configuration"
    assert Diagnostics.describe(:provider, :missing_api_key) =~ "dotenvx injection"
    assert Diagnostics.describe(:provider, {:transport_error, :nxdomain}) =~ "DNS lookup failed"
    assert Diagnostics.describe(:provider, {:transport_error, :tls_error}) =~ "TLS negotiation"
    assert Diagnostics.describe(:storage, :storage_error) =~ "storage: storage_error"

    assert Diagnostics.describe(:publication, :publication_error) =~
             "manifest could not be committed"
  end

  test "never interpolates untrusted reasons, provider text, stages, or exceptions" do
    private = "fake-private-credential-or-prompt"

    for reason <- [
          private,
          %{message: private, headers: [{"x-goog-api-key", private}]},
          RuntimeError.exception(private),
          {:http_error, 400, private},
          {:http_error, private, private},
          {:transport_error, private},
          {:unknown, private}
        ] do
      message = Diagnostics.describe(private, reason)
      refute message =~ private
      assert message =~ "startup:"
    end
  end
end
