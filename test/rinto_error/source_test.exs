defmodule RintoError.SourceTest do
  use ExUnit.Case, async: true

  alias RintoError.Fixture.{PlainSource, DetailedSource, SourceError, OtherSourceError, NoCatalog}
  require SourceError
  require NoCatalog

  test "a wrapper customizes changeset handling without replacing the standard implementation" do
    mod = RintoError.Fixture.CustomChangesetError
    changeset = Ecto.Changeset.change({%{}, %{name: :string}})
    changeset = Ecto.Changeset.validate_required(changeset, [:name])
    error = mod.exception(%RintoError.Fixture.CheckoutChangeset{changeset: changeset})
    payload = mod.to_payload(error)

    assert error.kind == :validation_error
    assert error.__source__ == RintoError.Fixture.CheckoutChangeset
    assert error.raw == :custom_ecto
    assert error.message == "custom build"
    assert error.data == %{}
    assert error.errors == []
    assert mod.http_status(error) == 422
    assert payload.kind == :invalid_input
    assert payload.data == %{custom: true, context: mod}
    assert payload.errors == [%{kind: :required, data: %{path: ["name"]}, errors: []}]
    assert Jason.encode!(error) == Jason.encode!(payload)

    manual =
      mod.exception(
        __source__: RintoError.Fixture.CheckoutChangeset,
        raw: :manual,
        metadata: %{changeset: changeset},
        data: %{custom: :explicit}
      )

    assert mod.to_payload(manual) == %{
             payload
             | data: %{custom: :explicit, context: mod}
           }

    default = RintoError.Fixture.Error
    default_payload = default.to_payload(default.exception(changeset))
    assert default_payload.data == %{}
    assert default_payload.errors == payload.errors
  end

  test "Changeset is a standard protocol implementation" do
    changeset = Ecto.Changeset.change({%{}, %{name: :string}})
    assert RintoError.Source.impl_for!(changeset) == RintoError.Source.Ecto.Changeset
    assert RintoError.Source.build(changeset) == %{raw: changeset}

    for mod <- [RintoError.Fixture.Error, RintoError.Fixture.ChangesetOutput] do
      error = mod.exception(changeset)
      assert error.raw == changeset
      assert error.__source__ == Ecto.Changeset
      assert mod.to_payload(error).errors == []
    end
  end

  test "generated calls use the protocol rather than concrete implementation modules" do
    for error_module <- [
          RintoError.Fixture.Error,
          RintoError.Fixture.CustomChangesetError,
          SourceError
        ] do
      {:ok, {^error_module, [imports: imports]}} =
        :beam_lib.chunks(:code.which(error_module), [:imports])

      assert {RintoError.Source, :build, 1} in imports
      assert {RintoError.Source, :to_payload, 2} in imports

      for {module, function, _arity} <- imports, function in [:build, :to_payload] do
        refute String.starts_with?(Atom.to_string(module), "Elixir.RintoError.Source.")
        refute module == RintoError.Changeset
      end
    end
  end

  test "custom implementations return final details independently of catalog mappings" do
    details = [
      %{kind: :timeout, field: "service", issue: "timeout"},
      %{code: :unavailable, retry_after: 30}
    ]

    source = %DetailedSource{
      reason: :timeout,
      details: details
    }

    error = SourceError.new(source)
    assert error.kind == :detailed
    assert error.__source__ == DetailedSource
    assert error.data == %{}
    assert error.errors == []
    assert SourceError.http_status(error) == 502

    payload = %{
      kind: :public_source,
      data: %{reason: :timeout, context: SourceError},
      errors: details
    }

    assert SourceError.to_payload(error) == payload
    assert Jason.encode!(error) == Jason.encode!(payload)

    if Code.ensure_loaded?(JSON) do
      assert apply(JSON, :encode!, [error]) == apply(JSON, :encode!, [payload])
    end

    other = OtherSourceError.exception(source)
    assert OtherSourceError.http_status(other) == 400

    assert OtherSourceError.to_payload(other) == %{
             kind: :different,
             data: %{reason: :timeout, context: OtherSourceError},
             errors: details
           }
  end

  test "build stores the source and conversion runs only at output time without caching" do
    error = SourceError.new(%DetailedSource{reason: :raise})
    assert_raise RuntimeError, "expanded at output time", fn -> SourceError.to_payload(error) end
    updated = %{error | raw: %DetailedSource{reason: :updated}}
    assert SourceError.to_payload(updated).data.reason == :updated
    assert SourceError.to_payload(updated).data.reason == :updated
    assert updated.data == %{}
  end

  test "explicit data overrides source data and source details replace stored errors" do
    details = [%{kind: :timeout, field: "service", issue: "timeout"}]
    error = SourceError.new(%DetailedSource{reason: :original, details: details})
    error = %{error | data: %{reason: :override, extra: 1}, errors: [%{issue: :stored}]}
    payload = SourceError.to_payload(error)
    assert payload.data == %{reason: :override, extra: 1, context: SourceError}
    assert payload.errors == details
  end

  test "a handler implementation does not authorize unregistered structs" do
    for source <- [%DetailedSource{}, %PlainSource{}, %URI{}, %Ecto.Changeset{}] do
      assert_raise ArgumentError, ~r/is not registered; declare entry_for/, fn ->
        NoCatalog.new(source)
      end
    end

    assert_raise ArgumentError, ~r/PlainSource is not registered/, fn ->
      OtherSourceError.exception(%PlainSource{})
    end
  end

  test "unregistered raw structs in explicit error attributes are not expanded" do
    source = %DetailedSource{reason: :raise}
    error = RintoError.Fixture.CatalogOptions.exception(raw: source, kind: :local, data: %{x: 1})

    assert RintoError.Fixture.CatalogOptions.to_payload(error) == %{
             kind: :local,
             data: %{x: 1},
             errors: []
           }
  end

  test "source registrations share catalog ordering, details, and normal construction" do
    assert SourceError.kinds() == [:ordinary, :plain, :timeout, :detailed, :public_timeout]
    assert SourceError.source_kinds() == %{PlainSource => :plain, DetailedSource => :detailed}
    assert SourceError.new(:detailed).kind == :detailed
    detail = %{kind: :detailed, as: :public_source, http_status: 502, doc: "Source detail"}
    assert Enum.at(SourceError.kinds(:full), 3) == detail
    assert SourceError.kinds(:public)[:public_source] == [detail]
    assert SourceError.payload_kinds().detailed == :public_source
    assert SourceError.statuses() == %{detailed: 502}
  end

  test "custom build can store information outside raw and conversion receives the whole error" do
    alias RintoError.Fixture.{StoredSource, StoredSourceError}
    require StoredSourceError

    error = StoredSourceError.new(%StoredSource{value: 42}, "overridden")
    assert error.__source__ == StoredSource
    assert error.raw == :opaque
    assert error.metadata.source_value == 42
    assert error.metadata.origin.module == __MODULE__
    assert error.message == "overridden"

    expected = %{kind: :public_stored, data: %{value: 42, description: "overridden"}, errors: []}
    assert StoredSourceError.to_payload(error) == expected
    # A different registered raw type must not change the selected converter.
    assert StoredSourceError.to_payload(%{error | raw: %Ecto.Changeset{}}) == expected
    assert Jason.decode!(Jason.encode!(error)) == Jason.decode!(Jason.encode!(expected))
    refute Exception.message(error) =~ "__source__"

    raised = assert_raise StoredSourceError, fn -> raise error end
    assert raised == error
  end

  test "manual source attributes bypass build, infer kind, and allow explicit kind" do
    alias RintoError.Fixture.{StoredSource, StoredSourceError}

    assert_raise RuntimeError, "build failed", fn ->
      StoredSourceError.exception(%StoredSource{value: :fail_build})
    end

    attrs = [__source__: StoredSource, raw: :anything, metadata: %{source_value: :fail_build}]

    for input <- [attrs, Map.new(attrs)] do
      error = StoredSourceError.exception(input)
      assert error.kind == :stored
      assert error.__source__ == StoredSource
      assert StoredSourceError.to_payload(error).data.value == :fail_build
      assert error.metadata == %{source_value: :fail_build}
    end

    error = StoredSourceError.exception(Keyword.put(attrs, :kind, :ordinary))
    assert StoredSourceError.to_payload(error).kind == :ordinary
  end

  test "raw never opts into conversion without a source marker" do
    source = %DetailedSource{reason: :raise}
    details = [%{kind: :timeout, path: ["name"], issue: "required"}]

    error =
      SourceError.exception(raw: source, kind: :detailed, errors: details)

    assert error.__source__ == nil

    assert SourceError.to_payload(error) == %{
             kind: :public_source,
             data: %{},
             errors: details
           }
  end

  test "source markers must be registered in the receiving error module" do
    for source <- [URI, :invalid, false, "Ecto.Changeset", %DetailedSource{}] do
      assert_raise ArgumentError, ~r/is not registered/, fn ->
        SourceError.exception(__source__: source, raw: nil, kind: :ordinary)
      end
    end

    assert_raise ArgumentError, ~r/is not registered/, fn ->
      NoCatalog.exception(__source__: DetailedSource, raw: nil)
    end

    error = %{SourceError.exception(:ordinary) | __source__: URI}

    assert_raise ArgumentError, ~r/is not registered/, fn ->
      apply(SourceError, :to_payload, [error])
    end
  end

  test "default changeset conversion tolerates manually supplied raw values" do
    alias RintoError.Fixture.Error

    for raw <- [nil, :custom, %{}, %DetailedSource{reason: :raise}] do
      error = Error.exception(__source__: Ecto.Changeset, raw: raw, data: %{extra: true})
      assert error.kind == :changeset_error

      assert Error.to_payload(error) == %{
               kind: :changeset_error,
               data: %{extra: true},
               errors: []
             }

      assert RintoError.Changeset.to_errors(raw) == []
    end

    changeset = Ecto.Changeset.change({%{}, %{name: :string}})
    changeset = Ecto.Changeset.validate_required(changeset, [:name])
    automatic = Error.exception(changeset)
    manual = Error.exception(__source__: Ecto.Changeset, raw: changeset)
    assert automatic == manual

    assert Error.to_payload(manual).errors == [
             %{kind: :required, data: %{path: ["name"]}, errors: []}
           ]
  end

  test "custom conversion failures propagate instead of becoming empty errors" do
    alias RintoError.Fixture.{StoredSource, StoredSourceError}
    error = StoredSourceError.exception(__source__: StoredSource, raw: :custom)
    assert_raise FunctionClauseError, fn -> StoredSourceError.to_payload(error) end
  end

  test "conversion resolves the source protocol implementation and passes the complete error" do
    alias RintoError.Fixture.{StoredSource, StoredSourceError}
    implementation = RintoError.Source.impl_for!(struct(StoredSource))

    error =
      StoredSourceError.exception(
        __source__: StoredSource,
        raw: %Ecto.Changeset{},
        metadata: %{source_value: 9}
      )

    assert Code.ensure_loaded?(implementation)
    assert function_exported?(implementation, :to_payload, 2)
    refute function_exported?(implementation, :to_payload, 1)
    assert RintoError.Source.__protocol__(:functions) == [build: 1, to_payload: 2]

    assert StoredSourceError.to_payload(error).data ==
             RintoError.Source.to_payload(struct(StoredSource), error).data

    assert StoredSourceError.to_payload(error).data.value == 9
    refute function_exported?(StoredSourceError, :source_handlers, 0)
  end

  test "build accepts map and keyword attributes and preserves a declared kind override" do
    alias RintoError.Fixture.{StoredSource, StoredSourceError}
    details = [%{field: "value", issue: :invalid}]

    attrs = %{
      raw: :chosen_raw,
      kind: :ordinary,
      message: "chosen message",
      data: %{extra: 1},
      errors: details,
      metadata: %{source_value: 42, extra: :kept}
    }

    for returned <- [attrs, Map.to_list(attrs)] do
      error = StoredSourceError.exception(%StoredSource{value: {:attrs, returned}})
      assert Map.take(error, Map.keys(attrs)) == attrs
      assert error.__source__ == StoredSource

      assert StoredSourceError.to_payload(error) == %{
               kind: :ordinary,
               data: %{extra: 1, value: 42, description: "chosen message"},
               errors: []
             }

      assert_raise StoredSourceError, fn -> raise error end
    end

    assert StoredSourceError.exception(attrs).kind == :ordinary
  end

  test "build rejects kinds outside the catalog for both map and keyword attributes" do
    alias RintoError.Fixture.{StoredSource, StoredSourceError}
    require StoredSourceError

    for kind <- [:not_in_catalog, :public_stored],
        attrs <- [%{kind: kind}, [kind: kind]] do
      source = %StoredSource{value: {:attrs, attrs}}

      assert_raise ArgumentError, ~r/expected kind/, fn ->
        StoredSourceError.exception(source)
      end

      assert_raise ArgumentError, ~r/expected kind/, fn ->
        StoredSourceError.new(source)
      end

      assert_raise ArgumentError, ~r/expected kind/, fn ->
        StoredSourceError.exception(attrs)
      end
    end
  end

  test "source kind fields belong to the builder for literals, updates, and variables" do
    alias RintoError.Fixture.{StoredSource, StoredSourceError}
    require StoredSourceError

    source = %StoredSource{value: 42}
    updated = %{source | kind: :source_business_kind}

    errors = [
      StoredSourceError.new(%StoredSource{value: 42, kind: :source_business_kind}),
      StoredSourceError.new(%{source | kind: :source_business_kind}),
      StoredSourceError.new(updated),
      StoredSourceError.new(%{%StoredSource{value: 42} | kind: :source_business_kind}),
      StoredSourceError.new(%{
        __struct__: StoredSource,
        value: 42,
        kind: :source_business_kind
      })
    ]

    for error <- errors do
      assert error.kind == :stored
      assert error.__source__ == StoredSource
      assert error.metadata.source_value == 42

      assert StoredSourceError.to_payload(error) == %{
               kind: :public_stored,
               data: %{value: 42, description: "built"},
               errors: []
             }
    end
  end

  test "build fills only absent defaults and preserves an explicit source selector" do
    alias RintoError.Fixture.{StoredSource, StoredSourceError}
    defaults = StoredSourceError.exception(%StoredSource{value: :defaults})
    assert defaults.raw == nil
    assert defaults.kind == :stored
    assert defaults.__source__ == StoredSource

    details = [%{field: "value", issue: :invalid}]
    attrs = %{kind: :ordinary, __source__: nil, data: %{kept: true}, errors: details}
    ordinary = StoredSourceError.exception(%StoredSource{value: {:attrs, attrs}})
    assert ordinary.__source__ == nil

    assert StoredSourceError.to_payload(ordinary) == %{
             kind: :ordinary,
             data: %{kept: true},
             errors: details
           }

    redirected =
      StoredSourceError.exception(%StoredSource{
        value: {:attrs, %{__source__: Ecto.Changeset, raw: :custom}}
      })

    assert redirected.kind == :stored
    assert redirected.__source__ == Ecto.Changeset

    assert StoredSourceError.to_payload(redirected) == %{
             kind: :public_stored,
             data: %{},
             errors: []
           }
  end
end
