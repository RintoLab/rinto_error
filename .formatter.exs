# Used by "mix format"
locals_without_parens = [catalog: 1, entry: 1, entry: 2, entry_for: 2, entry_for: 3]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
