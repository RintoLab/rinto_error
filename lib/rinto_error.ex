defmodule RintoError do
  @moduledoc """
  Defines an application Error with validated kinds, public payloads, and exception text.

  Use the guides for [design](guides/01_design_en.md),
  [application usage](guides/02_application_errors_en.md),
  [Ecto](guides/03_ecto_en.md), [custom sources](guides/04_custom_structs_en.md),
  and [output and logging](guides/05_output_and_logging_en.md).

  ## Catalog

      defmodule MyApp.Error do
        use RintoError

        catalog do
          entry :local
          entry :missing, http_status: 404
          entry :broken, as: :unavailable, http_status: 503
        end
      end

  `entry` declares a constructable internal kind. `entry_for Source, :kind`
  also registers an exact struct type; its module must be available at compile
  time. Both accept these optional literal values:

  * `as:` — public name, defaulting to the internal kind. Mapping happens once;
    output-only names are not constructable unless separately declared.
  * `http_status:` — integer from `100` to `599`, looked up by internal kind.
    Missing statuses raise `ArgumentError` only when `http_status/1` is called.
  * `doc:` — string included in catalog details, without affecting error behavior.

  Kinds and output names must be atom literals other than `nil`, `true`, and
  `false`. Variables, module attributes, and computed expressions are rejected,
  as are duplicate kinds, source registrations, options, and unknown options.
  A module may have one catalog; an empty or omitted catalog accepts no inputs.

  `kinds()` lists declared kinds; `kinds(:full)` includes names, statuses, and
  docs; `kinds(:public)` groups those details by output name. All preserve declaration
  order. `source_kinds()`, `payload_kinds()`, and `statuses()` expose source
  registrations, changed output names, and explicitly configured statuses.

  ## Construction

      require MyApp.Error, as: Error
      Error.new(:missing)
      Error.new(kind: :broken, raw: :db_down, data: %{attempt: 2})

  `new/2` constructs an Error and records the call site in `metadata.origin`.
  It evaluates input and message once; a non-nil message, including `""`, replaces
  the existing message. `exception/1` and `raise Error, opts` do not record origin.

  Atom input sets both `kind` and `raw`. Map/keyword input defaults raw to `nil`
  and requires kind unless a registered `__source__` supplies it. Unknown fields
  raise `KeyError`; missing required fields raise `ArgumentError`. Registered
  structs use `RintoError.Source`; unregistered structs raise `ArgumentError`.

  Undeclared literal kinds passed directly to `new` fail compilation. Dynamic
  inputs and builder results are validated at construction, raising `ArgumentError`
  for undeclared kinds. Direct struct construction requires kind and raw but,
  like direct map updates, bypasses catalog validation.

  ## Output

  `to_payload/1` returns `%{kind: atom(), data: map(), errors: [term()]}` with the
  mapped kind, excluding raw, message, metadata, and the source selector.
  Without a source, data and details are emitted as stored. Source conversion
  uses `RintoError.Source.to_payload/2`; details are never recursively converted or mapped.

  If `JSON.Encoder` or `Jason.Encoder` is loaded when the Error module compiles,
  the corresponding implementation is generated and encodes through `to_payload/1`.
  The library does not send responses or emit logs.

  ## Options

  * `inspect_opts:` — options for field values in exception text. They merge over
    `config :rinto_error, inspect_opts: [...]`, which merges over defaults
    `[pretty: true, width: 80, limit: :infinity, printable_limit: :infinity]`.
    Application configuration is read per call; module options are captured at
    compile time. Empty lists inherit prior options. This does not affect
    `inspect(error)` or payloads.

  Override `message/1` in the Error module to customize exception/log text;
  `super(error)` reuses the default formatter. Default text contains kind, message,
  data, errors, and metadata, excluding raw and the source selector.

  Ecto registration is always explicit. Its standard `RintoError.Source`
  implementation follows the same protocol contract as custom sources.
  See `RintoError.Source` for implementation and build validation details.

  ## Generated types

  Reference types on your application module, such as `MyApp.Error.t()`:

  * `t()` / `t(raw_type)` — Error with arbitrary / specified raw data. The parameter
    constrains raw, not kind; the kind field remains `atom()`.
  * `known_kind()` — union of declared internal kinds; `none()` for an empty catalog.
  * `payload()` — public output; `kind_detail()` — one catalog declaration.
  * `origin()` / `metadata()` — construction location / diagnostic context.

  Typespecs do not add runtime checks; construction enforces catalog membership.

  ## Migrating earlier APIs

  Replace positional declarations and `public:`, `expose_as:`, `construct:`, or
  `status:` with `entry :kind, as: :name, http_status: 422`. Replace `changeset:` /
  `changeset_kind:` with `entry_for Ecto.Changeset, :kind`.
  The `use RintoError` options `exclude_default_sources` and `override_sources`
  are no longer supported.
  To replace the supplied Changeset implementation, configure
  `config :rinto_error, exclude_default_sources: [Ecto.Changeset]` before compiling
  the dependency, then define your own `defimpl`. Protocol implementations apply
  globally per source type; use a wrapper struct for coexisting behaviors.

  Replace `expand/2` or two-argument builders with `build/1` returning attributes.
  Replace `@behaviour RintoError.Payload` and `to_payload(error)` with the protocol
  function `to_payload(_source, error)` in the same `defimpl`. Both protocol
  functions are required; the first output argument only selects the source type.
  Manual attributes must set `__source__` explicitly
  instead of relying on raw's type. Ecto type descriptions now use `t` objects
  instead of scalar names or composite `name` keys; see `RintoError.Changeset`.
  """

  @doc false
  defmacro __using__(opts) do
    RintoError.Catalog.validate_use_options!(opts, __CALLER__)

    quote do
      Module.register_attribute(__MODULE__, :rinto_error_entries, [])
      @rinto_error_inspect_opts Keyword.get(unquote(opts), :inspect_opts, [])
      import RintoError, only: [catalog: 1]
      @before_compile RintoError

      @enforce_keys [:raw, :kind]
      defexception [
        :raw,
        :kind,
        :message,
        :__source__,
        data: %{},
        errors: [],
        metadata: %{}
      ]

      @doc """
      Formats an error for exceptions and logs. Override in this module to
      customize the text; `super(error)` calls the default formatter.
      The default omits `raw` and `__source__` and inspects error details as-is.
      """
      @impl true
      @spec message(t()) :: String.t()
      def message(error) do
        RintoError.Message.format(error, @rinto_error_inspect_opts)
      end

      defoverridable message: 1

      @doc """
      Builds an error without recording an origin. Registered structs call
      their source's `build/1` for attributes; explicit returned fields are
      preserved and the final Error kind is checked against the catalog. Missing kind,
      source and raw default to the registration, input type and nil respectively.
      Direct maps/keywords bypass build and retain catalog validation. They
      default omitted raw to nil; a registered `__source__` supplies kind if it is omitted.
      Source construction calls only build/1; to_payload/2 runs only for output.
      """
      @impl true
      @spec exception(atom() | map() | keyword()) :: t()
      def exception(input), do: build_exception(input)
    end
  end

  @doc """
  Declares this module's error table. A module may have only one `catalog`.
  The block may contain only `entry` and `entry_for` calls.
  """
  defmacro catalog(do: block) do
    caller = __CALLER__

    # Attributes written with `@` become visible only after the module body
    # expands, so a later catalog cannot see an earlier one. Write the
    # attribute here so a second declaration fails while the macro expands.
    if Module.get_attribute(caller.module, :rinto_error_entries) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "catalog can only be declared once"
    end

    entries = RintoError.Catalog.parse!(block, caller)
    Module.put_attribute(caller.module, :rinto_error_entries, entries)

    quote do
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    entries = Module.get_attribute(env.module, :rinto_error_entries) || []
    generate(env.module, entries)
  end

  @doc false
  @spec fetch_status(atom(), map()) :: pos_integer()
  def fetch_status(kind, statuses) when is_atom(kind) and is_map(statuses) do
    case statuses do
      %{^kind => status} when is_integer(status) ->
        status

      %{^kind => status} ->
        raise ArgumentError,
              "expected #{inspect(kind)} to define an HTTP status, got: #{inspect(status)}"

      %{} ->
        raise ArgumentError, "expected #{inspect(kind)} to define an HTTP status"
    end
  end

  @doc false
  @spec fetch_source_kind!(module(), map(), module()) :: atom()
  def fetch_source_kind!(source, sources, error_module) do
    case sources do
      %{^source => kind} ->
        kind

      _ ->
        raise ArgumentError,
              "struct #{inspect(source)} is not registered; declare entry_for in #{inspect(error_module)}"
    end
  end

  @doc false
  def check_literal_kind!(input, kinds, caller) do
    case literal_kind(input) do
      {:literal, kind} ->
        unless kind in kinds do
          raise CompileError,
            file: caller.file,
            line: caller.line,
            description: "expected kind to be one of #{inspect(kinds)}, got: #{inspect(kind)}"
        end

      :dynamic ->
        :ok
    end
  end

  defp generate(module, entries) do
    recompile_hook =
      if Module.defines?(module, {:__mix_recompile__?, 0}) do
        quote generated: true do
          defoverridable __mix_recompile__?: 0

          @doc false
          def __mix_recompile__? do
            RintoError.Source.Validator.register(__MODULE__)
            super()
          end
        end
      else
        quote generated: true do
          @doc false
          def __mix_recompile__? do
            RintoError.Source.Validator.register(__MODULE__)
            false
          end
        end
      end

    source_kinds =
      Map.new(for %{source: source, kind: kind} <- entries, do: {source, kind})

    source_contracts =
      for %{source: source, file: file, line: line} <- entries do
        %{
          source: source,
          implementation: Module.concat(RintoError.Source, source),
          file: file,
          line: line
        }
      end

    payload_clauses =
      quote generated: true do
        nil -> {error.data, error.errors}
      end

    source_payload_clause =
      if map_size(source_kinds) > 0 do
        quote generated: true do
          source ->
            RintoError.fetch_source_kind!(source, source_kinds(), unquote(module))
            %{data: data, errors: errors} = RintoError.Source.to_payload(struct(source), error)
            {Map.merge(data, error.data), errors}
        end
      else
        quote generated: true do
          source -> RintoError.fetch_source_kind!(source, source_kinds(), unquote(module))
        end
      end

    payload_clauses = payload_clauses ++ source_payload_clause

    kinds = Enum.map(entries, & &1.kind)
    full_kinds = Enum.map(entries, &Map.take(&1, [:kind, :as, :http_status, :doc]))
    grouped_kinds = Enum.group_by(full_kinds, & &1.as)

    public_kinds =
      full_kinds
      |> Enum.uniq_by(& &1.as)
      |> Enum.map(&{&1.as, Map.fetch!(grouped_kinds, &1.as)})

    payload_kinds =
      entries
      |> Enum.filter(&(&1.as != &1.kind))
      |> Map.new(&{&1.kind, &1.as})

    payload_kind =
      if map_size(payload_kinds) == 0 do
        quote generated: true, do: error.kind
      else
        quote generated: true, do: Map.get(payload_kinds(), error.kind, error.kind)
      end

    statuses =
      entries
      |> Enum.filter(&(&1.http_status != nil))
      |> Map.new(&{&1.kind, &1.http_status})

    # Protocol implementations may compile after the Error module. Mark generated
    # code so transient protocol type warnings are not cached on failed builds;
    # the after-compiler validator checks the final implementations instead.
    quote generated: true do
      # Keep registrations available when Mix re-verifies unchanged Error modules.
      Module.register_attribute(__MODULE__, :rinto_error_source_contracts, persist: true)
      @rinto_error_source_contracts unquote(Macro.escape(source_contracts))
      @after_verify RintoError.Source.Validator
      unquote(recompile_hook)

      @dialyzer {:no_unknown, build_exception: 1, to_payload: 1}

      @typedoc """
      Call location that `new/2` writes into metadata. Outside a module or
      function, the matching value is `nil`.
      """
      @type origin :: %{
              module: module() | nil,
              function: {atom(), arity()} | nil,
              line: non_neg_integer()
            }

      @type metadata :: %{optional(:origin) => origin(), optional(atom()) => term()}

      @typedoc """
      The type parameter constrains `raw` on this node. `kind` is `atom()`
      on the struct because directly built nodes are not part of the closed table.
      """
      @type t(raw) :: %unquote(module){
              __exception__: true,
              __source__: module() | nil,
              raw: raw,
              kind: atom(),
              message: String.t() | nil,
              data: map(),
              errors: [term()],
              metadata: metadata()
            }

      @type t() :: t(term())

      @typedoc "Public result with details defined by the caller or source."
      @type payload :: %{kind: atom(), data: map(), errors: [term()]}

      @typedoc "A declared internal kind. `none()` when the catalog is empty."
      @type known_kind :: unquote(known_kind_type(kinds))

      @typedoc "A catalog entry with its output name, optional HTTP status, and doc."
      @type kind_detail :: %{
              kind: atom(),
              as: atom(),
              http_status: 100..599 | nil,
              doc: String.t() | nil
            }

      @doc """
      Internal kinds from `entry` and `entry_for`, in declaration order.
      Use `kinds(:full)` for details or `kinds(:public)` to group by output name.
      """
      @spec kinds() :: [atom()]
      def kinds, do: unquote(kinds)

      @doc """
      With `:full`, returns each declared kind with its output name, HTTP status, and doc,
      in declaration order across `entry` and `entry_for`.
      For explicit catalog entries, an omitted `as` defaults to the internal kind;
      omitted `http_status` and `doc` values are returned as `nil`. Output
      names are not followed recursively. Only `kind`, `as`, `http_status`,
      and `doc` are included. The doc is descriptive and does not affect
      error handling or become an exception message.

      With `:public`, returns a keyword list of public output names, each
      paired with a list of the same full kind details. Groups follow the
      first occurrence of each output name; entries within each group keep
      declaration order. Includes unchanged names. Returns `[]` only when
      there are no catalog entries.
      """
      @spec kinds(:full) :: [kind_detail()]
      @spec kinds(:public) :: [{atom(), [kind_detail()]}]
      def kinds(:full), do: unquote(Macro.escape(full_kinds))
      def kinds(:public), do: unquote(Macro.escape(public_kinds))

      @doc "Struct modules registered by `entry_for`, mapped to their internal kinds."
      @spec source_kinds() :: %{optional(module()) => atom()}
      def source_kinds, do: unquote(Macro.escape(source_kinds))

      @doc "Internal kind to public kind. Includes only rows where they differ."
      @spec payload_kinds() :: %{optional(atom()) => atom()}
      def payload_kinds, do: unquote(Macro.escape(payload_kinds))

      @doc "Declared HTTP statuses. Kinds that omit status are absent."
      @spec statuses() :: %{optional(atom()) => pos_integer()}
      def statuses, do: unquote(Macro.escape(statuses))

      @doc """
      Builds an error and records the call site. `require` this module first.

      An atom is used as both `raw` and `kind`. A map or keyword defaults omitted
      `raw` to nil; `kind` is required unless inferred from an explicit, registered
      `__source__`. Missing kind raises `ArgumentError`; unknown fields raise
      `KeyError`. A registered struct invokes its source's `build/1` for
      attributes. Missing kind/source/raw default to the registered kind,
      source module and nil; explicit fields are preserved, and the final Error
      kind is checked against the catalog. Maps/keywords bypass the builder.
      Payload conversion uses `__source__`, never raw's type.
      Both source protocol functions must be implemented. A source may explicitly
      reject public output in `to_payload/2` while still supporting exceptions and logs.

      A non-`nil` message replaces the previous value, including `""`. `nil`
      keeps the previous message. The call site replaces `metadata.origin`.
      Other metadata and error details are kept unchanged.
      """
      defmacro new(input, message \\ nil) do
        RintoError.check_literal_kind!(input, unquote(kinds), __CALLER__)
        origin = Map.take(__CALLER__, [:module, :function, :line])
        error_mod = unquote(module)

        quote generated: true,
              bind_quoted: [
                input: input,
                message: message,
                origin: Macro.escape(origin),
                error_mod: error_mod
              ] do
          error = error_mod.exception(input)

          %{
            error
            | message: message || error.message,
              metadata: Map.put(error.metadata, :origin, origin)
          }
        end
      end

      defp build_exception(kind) when is_atom(kind) do
        validate_kind!(%unquote(module){raw: kind, kind: kind})
      end

      unquote(
        if map_size(source_kinds) > 0 do
          quote generated: true do
            defp build_exception(%{__struct__: source} = input) when is_atom(source) do
              kind = RintoError.fetch_source_kind!(source, source_kinds(), unquote(module))

              attrs =
                input
                |> RintoError.Source.build()
                |> Map.new()
                |> Map.put_new(:raw, nil)
                |> Map.put_new(:kind, kind)
                |> Map.put_new(:__source__, source)

              unquote(module) |> struct!(attrs) |> validate_kind!()
            end
          end
        else
          quote generated: true do
            defp build_exception(%{__struct__: source}) when is_atom(source) do
              RintoError.fetch_source_kind!(source, source_kinds(), unquote(module))
            end
          end
        end
      )

      defp build_exception(attrs) when is_map(attrs) or is_list(attrs) do
        attrs = attrs |> Map.new() |> Map.put_new(:raw, nil)

        attrs =
          case Map.get(attrs, :__source__) do
            nil ->
              attrs

            source ->
              kind = RintoError.fetch_source_kind!(source, source_kinds(), unquote(module))
              Map.put_new(attrs, :kind, kind)
          end

        unquote(module) |> struct!(attrs) |> validate_kind!()
      end

      @doc """
      Builds the public payload. Does not modify the original error or cache
      the expansion.

      A registered `__source__` selects the protocol implementation, whose
      `to_payload/2` receives an empty source struct for dispatch and the complete
      error. Explicit data keys take precedence; returned details replace stored `errors`. With
      `__source__: nil`, stored data and details are returned as-is.
      Details have no prescribed Error shape and are never recursively
      converted or mapped through the catalog. `__source__` never appears
      in the outer payload.

      Missing implementations raise `Protocol.UndefinedError`; exceptions from
      conversion propagate unchanged.
      """
      @spec to_payload(t()) :: payload()
      def to_payload(%unquote(module){} = error) do
        {data, errors} =
          case error.__source__ do
            unquote(payload_clauses)
          end

        %{
          kind: unquote(payload_kind),
          data: data,
          errors: errors
        }
      end

      @doc """
      Returns the HTTP status for the kind stored on the struct.

      Returns the integer when the status is an integer. Raises
      `ArgumentError` when the status is omitted or the kind is not in the
      table. This helper does not affect construction or payload output.
      """
      @spec http_status(t()) :: pos_integer()
      def http_status(%unquote(module){kind: kind}) do
        RintoError.fetch_status(kind, statuses())
      end

      defp validate_kind!(%unquote(module){kind: kind} = error) do
        if kind in kinds() do
          error
        else
          raise ArgumentError,
                "expected kind to be one of #{inspect(kinds())}, got: #{inspect(kind)}"
        end
      end

      unquote_splicing(encoder_asts(module))
    end
  end

  defp known_kind_type([]), do: quote(do: none())
  defp known_kind_type([kind]), do: kind

  defp known_kind_type([kind | kinds]) do
    Enum.reduce(kinds, kind, fn next, acc -> {:|, [], [acc, next]} end)
  end

  defp encoder_asts(module) do
    Enum.reject([json_encoder(module), jason_encoder(module)], &is_nil/1)
  end

  defp json_encoder(module) do
    if Code.ensure_loaded?(JSON.Encoder) do
      quote do
        defimpl JSON.Encoder, for: unquote(module) do
          def encode(error, encoder) do
            encoder.(unquote(module).to_payload(error), encoder)
          end
        end
      end
    end
  end

  defp jason_encoder(module) do
    if Code.ensure_loaded?(Jason.Encoder) do
      quote do
        defimpl Jason.Encoder, for: unquote(module) do
          def encode(error, opts) do
            Jason.Encode.map(unquote(module).to_payload(error), opts)
          end
        end
      end
    end
  end

  defp literal_kind(kind) when is_atom(kind), do: {:literal, kind}

  defp literal_kind({:%{}, _meta, pairs} = input) when is_list(pairs) do
    if plain_map_literal?(input), do: literal_kind_from_pairs(pairs), else: :dynamic
  end

  defp literal_kind(pairs) when is_list(pairs) do
    if Keyword.keyword?(pairs) do
      literal_kind_from_pairs(pairs)
    else
      :dynamic
    end
  end

  defp literal_kind(_input), do: :dynamic

  defp plain_map_literal?({:%{}, _meta, [{:|, _, [base, _updates]}]}) do
    plain_map_literal?(base)
  end

  defp plain_map_literal?({:%{}, _meta, pairs}) when is_list(pairs) do
    Enum.all?(pairs, fn
      {key, _value} -> Macro.quoted_literal?(key) and key != :__struct__
      _other -> false
    end)
  end

  defp plain_map_literal?(_input), do: false

  defp literal_kind_from_pairs(pairs) do
    Enum.find_value(pairs, :dynamic, fn
      {:kind, kind} when is_atom(kind) ->
        {:literal, kind}

      {:kind, {:__block__, _, [kind]}} when is_atom(kind) ->
        {:literal, kind}

      {:|, _, [_left, right]} when is_list(right) ->
        case literal_kind_from_pairs(right) do
          :dynamic -> nil
          found -> found
        end

      _other ->
        nil
    end)
  end
end
