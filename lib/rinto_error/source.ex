defprotocol RintoError.Source do
  @moduledoc """
  Construction and public-output protocol for registered source structs.

  Implement both `build/1` and `to_payload/2` in a `defimpl`, and register each
  accepted type with `entry_for` in the application Error module. Registration
  is required even when an implementation exists. See the
  [custom struct guide](guides/04_custom_structs_en.md).

  ## Construction

  `build/1` receives the original input and returns Error attributes as a map or
  keyword list. Missing kind, source selector, and raw default to the registered
  kind, input module, and `nil`. Explicit fields are preserved; the final kind
  must be declared, and unknown fields fail struct construction. Retaining the
  original input in raw is optional.

  Maps and keywords bypass the builder. An explicit registered `__source__`
  supplies a default kind and selects output conversion; raw's type never selects it.

  ## Public output

  `to_payload/2` dispatches on an empty struct of the final `__source__` type.
  Its first argument is only a type selector, NOT the original input. The second
  argument is the complete Error, including current raw, data, errors, and metadata.
  Read conversion data from the Error; the builder decides what to retain there.
  This also supports manually constructed Errors and builders that replace raw.

  Return `%{data: map(), errors: [term()]}`. Explicit Error data overrides returned
  keys, and returned details replace stored errors without recursive conversion or
  catalog mapping. The Error module adds the mapped public kind. Conversion runs
  on every output request and JSON encoding, without caching.

  Both functions are required by the protocol. A source used only for exceptions
  or logs can explicitly raise in `to_payload/2` to reject public output.
  Construction calls only `build/1`; implementation exceptions propagate unchanged.

  ## Implementations and compilation

  Both construction and output call this protocol through normal dispatch,
  including protocol consolidation. `Ecto.Changeset` uses the same path as any
  custom struct. The library supplies its implementation when Ecto is available
  at library compilation.

  To supply your own Changeset implementation, configure this before compiling
  the dependency:

      config :rinto_error, exclude_default_sources: [Ecto.Changeset]

  Then define your `defimpl` in the application's `lib/` directory. Recompile
  the dependency after changing this configuration. Helpers in
  `RintoError.Changeset` remain available. Implementations apply globally per type;
  per-Error overrides are not supported. Use a wrapper struct when different
  behaviors must coexist. Each Error module still needs `entry_for`.

  Error and implementation modules may compile in either order, before protocol
  consolidation. Ordinary Mix builds verify implementation metadata and both
  public callbacks after Elixir compilation, including unchanged Error modules
  in incremental builds. Failures point to `entry_for`. Validation reads compiled
  metadata and exports without loading implementations or running callbacks;
  it does not check return values or behavior. Standalone compilation outside Mix
  skips this project-wide check; missing implementations raise native protocol errors.
  """

  @doc "Returns Error construction attributes from the original input struct."
  @spec build(t()) :: map() | keyword()
  def build(source)

  @doc "Returns public data and details from the complete Error; source selects the implementation."
  @spec to_payload(t(), struct()) :: %{data: map(), errors: [term()]}
  def to_payload(source, error)
end
