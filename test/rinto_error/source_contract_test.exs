defmodule RintoError.SourceContractTest do
  use ExUnit.Case, async: true

  alias RintoError.Fixture.InternalSource
  alias RintoError.Fixture.InternalSourceError, as: Error
  alias RintoError.Fixture.{AttributeSource, ExtendedPayloadSource}
  alias RintoError.Fixture.AttributeSourceError, as: PayloadError
  require Error
  require PayloadError

  test "an internal-only source supports construction, raising, and exception messages" do
    source = %InternalSource{reason: :internal_failure}
    error = Error.exception(source)
    assert error.raw == source
    assert error.kind == :internal_source
    assert error.__source__ == InternalSource
    assert Exception.message(error) =~ "internal diagnostics"

    located = Error.new(source, "call-site message")
    assert located.metadata.origin.module == __MODULE__
    assert located.message == "call-site message"
    assert Exception.message(located) =~ "call-site message"
    assert assert_raise(Error, fn -> raise located end) == located
    assert assert_raise(Error, fn -> raise Error, source end) == error
  end

  test "an internal-only source explicitly rejects public output" do
    built = Error.exception(%InternalSource{reason: :internal_failure})
    manual = Error.exception(__source__: InternalSource)

    for error <- [built, manual] do
      assert_raise ArgumentError, "public output is not supported", fn ->
        Error.to_payload(error)
      end

      assert_raise ArgumentError, "public output is not supported", fn -> Jason.encode!(error) end

      if Code.ensure_loaded?(JSON) do
        assert_raise ArgumentError, "public output is not supported", fn ->
          apply(JSON, :encode!, [error])
        end
      end
    end
  end

  test "an explicit converter supports construction, raising, messages, and public output" do
    source = %AttributeSource{data: %{attempt: 2}}
    error = PayloadError.exception(source)
    located = PayloadError.new(source, "call-site message")

    assert error.kind == :attribute_source
    assert error.__source__ == AttributeSource
    assert located.metadata.origin.module == __MODULE__
    assert Exception.message(located) =~ "call-site message"
    assert assert_raise(PayloadError, fn -> raise located end) == located
    assert assert_raise(PayloadError, fn -> raise PayloadError, source end) == error

    expected = %{kind: :public_source, data: %{attempt: 2}, errors: []}
    assert_public_output(PayloadError, error, expected)
    assert_public_output(PayloadError, located, expected)
  end

  test "source details keep their own shape and classification without exposing source diagnostics" do
    details = [
      %{kind: :timeout, path: ["name"], message: "required"},
      %{code: :out_of_range, field: "quantity", bounds: %{minimum: 1}},
      %{kind: :public_timeout, data: %{reason: :unsupported}}
    ]

    source = %AttributeSource{
      raw: "private source raw",
      message: "private source message",
      metadata: %{diagnostic: "private source metadata"},
      data: %{attempt: 1},
      errors: details
    }

    error = PayloadError.new(source)
    original = error

    expected = %{
      kind: :public_source,
      data: %{attempt: 1},
      errors: details
    }

    assert_public_output(PayloadError, error, expected)
    refute Jason.encode!(error) =~ "private"
    assert PayloadError.to_payload(error) == expected
    assert error == original
    assert error.errors == details
    assert error.data == source.data
    assert error.raw == source.raw

    assert PayloadError.to_payload(PayloadError.exception(:public_source)).kind ==
             :remapped_source

    assert PayloadError.to_payload(PayloadError.exception(:public_timeout)).kind ==
             :remapped_timeout
  end

  test "manually tagged and ordinary errors preserve the same stored details" do
    details = [%{field: "name", kind: :timeout, issue: "blank"}]

    manual =
      PayloadError.exception(
        __source__: AttributeSource,
        raw: "private manual raw",
        data: %{manual: true},
        errors: details
      )

    expected = %{
      kind: :public_source,
      data: %{manual: true},
      errors: details
    }

    assert_public_output(PayloadError, manual, expected)
    ordinary = PayloadError.exception(kind: :ordinary, errors: details)

    assert_public_output(PayloadError, ordinary, %{
      kind: :public_ordinary,
      data: %{},
      errors: details
    })
  end

  test "a custom converter supplies final details while preserving explicit data precedence" do
    details = [%{kind: :timeout, field: "value", expected: "positive"}]

    error =
      PayloadError.exception(%ExtendedPayloadSource{
        value: 42,
        data: %{kept: true},
        errors: details
      })

    expected = %{
      kind: :public_extended,
      data: %{kept: true, derived: 42},
      errors: details
    }

    assert_public_output(PayloadError, error, expected)
    assert error.errors == details
    assert error.data == %{kept: true}

    overridden = %{error | data: %{kept: true, derived: :explicit}}
    assert PayloadError.to_payload(overridden).data == %{kept: true, derived: :explicit}
  end

  test "exceptions from a custom converter propagate unchanged" do
    exception = ArgumentError.exception("custom conversion failed")
    error = PayloadError.exception(%ExtendedPayloadSource{value: {:raise, exception}})

    assert assert_raise(ArgumentError, fn -> PayloadError.to_payload(error) end) == exception
    assert assert_raise(ArgumentError, fn -> Jason.encode!(error) end) == exception

    if Code.ensure_loaded?(JSON) do
      assert assert_raise(ArgumentError, fn -> apply(JSON, :encode!, [error]) end) == exception
    end
  end

  test "both callbacks are protocol functions and support impl annotations" do
    script = ~S"""
    defmodule Payload do
      defstruct []
    end

    defimpl RintoError.Source, for: Payload do
      @impl true
      def build(source), do: %{raw: source}

      @impl true
      def to_payload(_source, error), do: %{data: %{marker: error.metadata.marker}, errors: []}
    end

    defmodule Error do
      use RintoError
      catalog do
        entry_for Payload, :source, as: :public_source
      end
    end

    unless RintoError.Source.__protocol__(:functions) == [build: 1, to_payload: 2],
      do: raise("converter is not a protocol dispatch function")

    source = struct!(Payload)
    unless RintoError.Source.build(source) == %{raw: source},
      do: raise("build protocol dispatch changed")

    error = Error.exception(__source__: Payload, metadata: %{marker: :whole_error})
    result = Error.to_payload(error)
    unless result == %{kind: :public_source, data: %{marker: :whole_error}, errors: []},
      do: raise("converter did not receive the complete error")

    unless RintoError.Source.to_payload(source, error) == %{data: %{marker: :whole_error}, errors: []},
      do: raise("output protocol dispatch changed")
    """

    refute assert_script!(script) =~ "warning:"
  end

  test "an Error can compile before its source implementation without warnings" do
    script = ~S"""
    defmodule LaterSource do
      defstruct [:value]
    end

    Code.compile_string(~S'''
    defmodule EarlyError do
      use RintoError
      catalog do
        entry_for LaterSource, :internal, as: :public
      end
    end
    ''')

    defimpl RintoError.Source, for: LaterSource do
      @impl true
      def build(source), do: %{raw: source}

      @impl true
      def to_payload(_source, error) do
        %{data: %{value: error.raw.value}, errors: [%{field: "value", issue: "invalid"}]}
      end
    end

    source = struct!(LaterSource, value: 42)
    built = EarlyError.exception(source)
    manual = EarlyError.exception(__source__: LaterSource, raw: source)
    expected = %{
      kind: :public,
      data: %{value: 42},
      errors: [%{field: "value", issue: "invalid"}]
    }

    unless built == manual and EarlyError.to_payload(built) == expected and
             EarlyError.to_payload(manual) == expected,
      do: raise("later source implementation was not used")
    """

    refute assert_script!(script) =~ "warning:"
  end

  @tag :tmp_dir
  test "compiling an Error does not load an available source implementation", %{tmp_dir: tmp_dir} do
    script = ~S"""
    defmodule LazySource do
      defstruct [:value]
    end

    [{implementation, binary}] = Code.compile_string(~S'''
    defimpl RintoError.Source, for: LazySource do
      @on_load :track_load

      def track_load do
        :persistent_term.put(__MODULE__, :persistent_term.get(__MODULE__, 0) + 1)
        :ok
      end

      @impl true
      def build(source), do: %{raw: source}

      @impl true
      def to_payload(_source, error), do: %{data: %{value: error.raw.value}, errors: []}
    end
    ''')

    [path] = System.argv()
    File.write!(Path.join(path, Atom.to_string(implementation) <> ".beam"), binary)
    Code.prepend_path(path)
    true = :code.delete(implementation)
    :code.purge(implementation)
    false = :code.is_loaded(implementation)
    1 = :persistent_term.get(implementation)

    Code.compile_string(~S'''
    defmodule LazyError do
      use RintoError
      catalog do
        entry_for LazySource, :internal, as: :public
      end
    end
    ''')

    false = :code.is_loaded(implementation)
    1 = :persistent_term.get(implementation)

    source = struct!(LazySource, value: 42)
    error = LazyError.exception(source)
    2 = :persistent_term.get(implementation)
    expected = %{kind: :public, data: %{value: 42}, errors: []}
    ^expected = LazyError.to_payload(error)

    true = :code.delete(implementation)
    :code.purge(implementation)
    false = :code.is_loaded(implementation)
    ^expected = LazyError.to_payload(error)
    3 = :persistent_term.get(implementation)
    """

    refute assert_script!(script, [tmp_dir]) =~ "warning:"
  end

  defp assert_public_output(error_module, error, expected) do
    assert error_module.to_payload(error) == expected
    assert Jason.encode!(error) == Jason.encode!(expected)

    if Code.ensure_loaded?(JSON) do
      assert apply(JSON, :encode!, [error]) == apply(JSON, :encode!, [expected])
    end
  end

  defp assert_script!(script, argv \\ []) do
    # Compile without consolidated protocols or the application's test handlers.
    files =
      ~w(lib/rinto_error/source.ex lib/rinto_error/source/validator.ex lib/rinto_error/catalog.ex lib/rinto_error/changeset.ex lib/rinto_error/message.ex lib/rinto_error.ex)

    args = Enum.flat_map(files, &["-r", Path.expand(&1)]) ++ ["-e", script, "--"] ++ argv
    {output, status} = System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
