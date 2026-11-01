%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "mix.exs", "config/"],
        excluded: []
      },
      plugins: [{AshCredo, []}],
      checks: %{
        extra: [
          # AshCredo enables only four checks by default. Opt into account/security guards.
          {AshCredo.Check.Warning.ActorOnCallOptions, []},
          {AshCredo.Check.Warning.AuthorizeFalse, []},
          {AshCredo.Check.Warning.AuthorizerWithoutPolicies, []},
          {AshCredo.Check.Warning.MissingDomain, []},
          {AshCredo.Check.Warning.OverlyPermissivePolicy, []},
          {AshCredo.Check.Warning.RepoCallInResource, []},
          {AshCredo.Check.Warning.SensitiveAttributeExposed,
           [
             sensitive_names: [~r/password/, ~r/token/, ~r/secret/, :api_key, :private_key]
           ]},
          {AshCredo.Check.Warning.SensitiveFieldInAccept, []},
          {AshCredo.Check.Warning.UnknownAction, []},
          {AshCredo.Check.Warning.WildcardAcceptOnAction, []}
        ]
      }
    }
  ]
}
