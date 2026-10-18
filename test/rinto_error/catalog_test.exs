defmodule RintoError.CatalogTest do
  use ExUnit.Case, async: true

  alias RintoError.Fixture.{
    CatalogOptions,
    ChangesetOutput,
    EmptyCatalog,
    Error,
    NoCatalog,
    OutputMapping,
    StatusBounds
  }

  require Error
  require CatalogOptions

  describe "entry_for" do
    test "rejects duplicate struct registrations and kinds at the later declaration" do
      for {entries, expected} <- [
            {"entry_for URI, :first\nentry_for URI, :second", "struct URI is already registered"},
            {"entry :same\nentry_for URI, :same", "kind :same is already defined"},
            {"entry_for URI, :same\nentry :same", "kind :same is already defined"},
            {"entry_for URI, :same\nentry_for Ecto.Changeset, :same",
             "kind :same is already defined"}
          ] do
        error = compile_error!(source(entries))
        assert error.line == 5
        assert error.description =~ expected
      end
    end

    test "requires an available struct module and valid entry arguments" do
      for {entry, expected} <- [
            {"entry_for String, :invalid", "expects an available struct module"},
            {"entry_for MissingSourceModule, :invalid", "expects an available struct module"},
            {"entry_for nil, :invalid", "expects an available struct module"},
            {"entry_for false, :invalid", "expects an available struct module"},
            {"entry_for true, :invalid", "expects an available struct module"},
            {~s(entry_for "URI", :invalid), "expects an available struct module"},
            {"entry_for %URI{}, :invalid", "expects an available struct module"},
            {"entry_for module, :invalid", "expects an available struct module"},
            {"entry_for URI", "expects a struct module, kind"},
            {"entry_for URI, :invalid, [], :extra", "expects a struct module, kind"},
            {"entry_for URI, nil", "kind must be an atom literal"},
            {"entry_for URI, :invalid, as: false", "as must be an atom literal"},
            {"entry_for URI, :invalid, as: :a, as: :b", "option :as is duplicated"},
            {"entry_for URI, :invalid, http_status: 99", "100 to 599"},
            {"entry_for URI, :invalid, http_status: 600", "100 to 599"},
            {"entry_for URI, :invalid, http_status: nil", "100 to 599"},
            {"entry_for URI, :invalid, doc: false", "doc must be a string literal"},
            {"entry_for URI, :invalid, adapter: Foo", "unknown entry option :adapter"},
            {"entry_for URI, :invalid, with: Foo", "unknown entry option :with"},
            {"entry :invalid, with: Foo", "unknown entry option :with"},
            {"entry_for URI, :invalid, [:as]", "literal keyword list"},
            {"entry_for URI, :invalid, opts", "optional literal keyword options"}
          ] do
        error = compile_error!(source(entry))
        assert error.line == 4, entry
        assert error.description =~ expected, entry
      end
    end

    test "rejects removed use options" do
      for options <- [
            "changeset: [kind: :validation_error, as: :invalid]",
            "changeset_kind: :invalid",
            "exclude_default_sources: [Ecto.Changeset]",
            "override_sources: [Ecto.Changeset]",
            "override_sources: []"
          ] do
        error = compile_error!("defmodule #{mod()} do\n  use RintoError, #{options}\nend")
        assert error.line == 2
        assert error.description =~ "unknown use RintoError option"
      end
    end

    test "custom structs work in a fresh VM without Ecto" do
      script = """
      if Code.ensure_loaded?(Ecto.Changeset), do: raise("Ecto unexpectedly available")
      defmodule WithoutEcto do
        use RintoError
      end
      unless WithoutEcto.kinds() == [], do: raise("unexpected kinds")
      if Code.ensure_loaded?(WithoutEcto.Changeset), do: raise("unexpected Changeset module")
      defmodule CustomSource do
        defstruct [:value]
      end
      defimpl RintoError.Source, for: CustomSource do
        def build(source), do: %{raw: source}
        def to_payload(_source, error), do: %{data: %{value: error.raw.value}, errors: []}
      end
      defmodule CustomError do
        use RintoError
        catalog do
          entry_for CustomSource, :custom, as: :public_custom
        end
      end
      source = struct!(CustomSource, value: 1)
      expected = %{kind: :public_custom, data: %{value: 1}, errors: []}
      unless CustomError.to_payload(CustomError.exception(source)) == expected, do: raise("bad custom expansion")
      """

      files =
        ~w(lib/rinto_error/source.ex lib/rinto_error/source/validator.ex lib/rinto_error/catalog.ex lib/rinto_error/message.ex lib/rinto_error.ex)

      args = Enum.flat_map(files, &["-r", Path.expand(&1)]) ++ ["-e", script]

      {output, status} =
        System.cmd(System.find_executable("elixir"), args, stderr_to_stdout: true)

      assert status == 0, output
    end
  end

  describe "catalog/1" do
    test "declares kinds with independent optional output names and statuses" do
      mod = CatalogOptions

      assert mod.kinds() == [:local, :missing, :broken, :timeout]
      assert mod.payload_kinds() == %{broken: :unavailable, timeout: :unavailable}
      assert mod.statuses() == %{missing: 404, timeout: 503}
      assert mod.to_payload(mod.exception(:local)).kind == :local
      assert mod.to_payload(mod.exception(:broken)).kind == :unavailable
      assert mod.http_status(mod.exception(:timeout)) == 503
      assert_raise ArgumentError, fn -> mod.exception(:unavailable) end
      assert_raise ArgumentError, fn -> mod.http_status(mod.exception(:broken)) end
    end

    test "lists full kind details in declaration order with defaults" do
      assert CatalogOptions.kinds(:full) == [
               %{kind: :local, as: :local, http_status: nil, doc: nil},
               %{kind: :missing, as: :missing, http_status: 404, doc: "Record not found"},
               %{kind: :broken, as: :unavailable, http_status: nil, doc: "上游不可用\n供排查参考"},
               %{kind: :timeout, as: :unavailable, http_status: 503, doc: ""}
             ]

      assert Enum.map(CatalogOptions.kinds(:full), & &1.kind) == CatalogOptions.kinds()
    end

    test "groups full kind details by public output name in declaration order" do
      assert CatalogOptions.kinds(:public) == [
               local: [%{kind: :local, as: :local, http_status: nil, doc: nil}],
               missing: [
                 %{kind: :missing, as: :missing, http_status: 404, doc: "Record not found"}
               ],
               unavailable: [
                 %{kind: :broken, as: :unavailable, http_status: nil, doc: "上游不可用\n供排查参考"},
                 %{kind: :timeout, as: :unavailable, http_status: 503, doc: ""}
               ]
             ]
    end

    test "public groups merge nonadjacent entries without following output mappings" do
      assert OutputMapping.kinds(:public) == [
               beta: [
                 %{kind: :alpha, as: :beta, http_status: 500, doc: nil},
                 %{kind: :local, as: :beta, http_status: nil, doc: nil}
               ],
               gamma: [%{kind: :beta, as: :gamma, http_status: 503, doc: nil}],
               self: [%{kind: :self, as: :self, http_status: nil, doc: nil}]
             ]
    end

    test "docs do not become messages or enter payloads" do
      error = CatalogOptions.new(:missing)
      assert error.message == nil
      assert CatalogOptions.http_status(error) == 404
      assert CatalogOptions.to_payload(error) == %{kind: :missing, data: %{}, errors: []}
      refute Exception.message(error) =~ "Record not found"
      refute Jason.encode!(error) =~ "Record not found"
      assert CatalogOptions.new(:missing, "request failed").message == "request failed"

      error = CatalogOptions.new(:broken)
      assert CatalogOptions.to_payload(error) == %{kind: :unavailable, data: %{}, errors: []}
      assert_raise ArgumentError, fn -> CatalogOptions.http_status(error) end
    end

    test "output names are not followed recursively or used for status lookup" do
      mod = OutputMapping

      assert hd(mod.kinds(:full)) == %{kind: :alpha, as: :beta, http_status: 500, doc: nil}
      assert mod.to_payload(mod.exception(:alpha)).kind == :beta
      assert mod.to_payload(mod.exception(:beta)).kind == :gamma
      assert mod.http_status(mod.exception(:alpha)) == 500
      assert mod.http_status(mod.exception(:beta)) == 503
      assert_raise ArgumentError, fn -> mod.http_status(mod.exception(:local)) end
      refute Map.has_key?(mod.payload_kinds(), :self)
    end

    test "rejects duplicate kinds at the later entry" do
      error = compile_error!(source("entry :alpha\nentry :alpha, http_status: 404"))
      assert error.line == 5
      assert error.description =~ "kind :alpha is already defined"
    end

    test "rejects invalid declarations at the matching entry" do
      for {entry, expected} <- [
            {"entry :alpha, http_status: 99", "100 to 599"},
            {"entry :alpha, http_status: 600", "100 to 599"},
            {"entry :alpha, http_status: 404.0", "100 to 599"},
            {"entry :alpha, http_status: :none", "100 to 599"},
            {"entry :alpha, http_status: nil", "100 to 599"},
            {"entry :alpha, http_status: true", "100 to 599"},
            {"entry :alpha, http_status: status", "100 to 599"},
            {"entry :alpha, http_status: 200 + 200", "100 to 599"},
            {"entry kind", "kind must be an atom literal"},
            {"entry @kind", "kind must be an atom literal"},
            {"entry nil", "kind must be an atom literal"},
            {"entry true", "kind must be an atom literal"},
            {"entry false", "kind must be an atom literal"},
            {~s(entry "alpha"), "kind must be an atom literal"},
            {"entry :alpha, as: name", "as must be an atom literal"},
            {"entry :alpha, as: @name", "as must be an atom literal"},
            {"entry :alpha, as: nil", "as must be an atom literal"},
            {"entry :alpha, as: true", "as must be an atom literal"},
            {"entry :alpha, as: false", "as must be an atom literal"},
            {~s(entry :alpha, as: "name"), "as must be an atom literal"},
            {"entry :alpha, stats: 404", "unknown entry option :stats"},
            {"entry :alpha, status: 404", "unknown entry option :status"},
            {"entry :alpha, public: :name", "unknown entry option :public"},
            {"entry :alpha, expose_as: :name", "unknown entry option :expose_as"},
            {"entry :alpha, construct: false", "unknown entry option :construct"},
            {"entry :alpha, http_status: 404, http_status: 500",
             "option :http_status is duplicated"},
            {"entry :alpha, as: :x, as: :y", "option :as is duplicated"},
            {"entry :alpha, doc: :text", "doc must be a string literal"},
            {"entry :alpha, doc: nil", "doc must be a string literal"},
            {"entry :alpha, doc: false", "doc must be a string literal"},
            {"entry :alpha, doc: 123", "doc must be a string literal"},
            {"entry :alpha, doc: text", "doc must be a string literal"},
            {"entry :alpha, doc: @text", "doc must be a string literal"},
            {~s(entry :alpha, doc: "a" <> "b"), "doc must be a string literal"},
            {~s(entry :alpha, doc: "a", doc: "b"), "option :doc is duplicated"},
            {"entry :alpha, opts", "optional literal keyword options"},
            {"entry :alpha, [:http_status]", "literal keyword list"},
            {"entry :alpha, :alpha, true", "optional literal keyword options"},
            {"entry :alpha, :alpha, 404, true", "optional literal keyword options"}
          ] do
        error = compile_error!(source(entry))
        assert error.line == 4, entry
        assert error.file == "catalog_fixture.ex"
        assert error.description =~ expected, entry
      end
    end

    test "rejects a second catalog, including an empty first catalog" do
      for first <- ["", "entry :alpha"] do
        error =
          compile_error!("""
          defmodule #{mod()} do
            use RintoError
            catalog do
              #{first}
            end
            catalog do
              entry :beta
            end
          end
          """)

        assert error.description =~ "only be declared once"
      end
    end

    test "rejects expressions other than entries" do
      error = compile_error!(source(":alpha"))
      assert error.description =~ "only accepts entry"
    end

    test "supports an empty or omitted catalog" do
      for mod <- [EmptyCatalog, NoCatalog] do
        assert mod.kinds() == []
        assert mod.kinds(:full) == []
        assert mod.kinds(:public) == []
        assert mod.source_kinds() == %{}
        assert mod.payload_kinds() == %{}
        assert mod.statuses() == %{}
        assert_raise ArgumentError, fn -> mod.exception(:unknown) end

        assert_raise ArgumentError, fn ->
          mod.http_status(struct!(mod, raw: :x, kind: :unknown))
        end
      end
    end

    test "accepts status boundaries and output names shared without registration" do
      mod = StatusBounds

      assert mod.kinds() == [:low, :high]
      assert mod.http_status(mod.exception(:low)) == 100
      assert mod.http_status(mod.exception(:high)) == 599
    end

    test "does not accept an unregistered changeset even when Ecto is available" do
      changeset = Ecto.Changeset.change({%{}, %{name: :string}})

      for mod <- [EmptyCatalog, NoCatalog, CatalogOptions] do
        assert_raise ArgumentError, ~r/struct Ecto.Changeset is not registered/, fn ->
          mod.exception(changeset)
        end

        refute Code.ensure_loaded?(Module.concat(mod, Changeset))
      end
    end

    test "a declared changeset kind is constructable like every other kind" do
      mod = ChangesetOutput
      refute Code.ensure_loaded?(Module.concat(mod, Changeset))
      assert mod.kinds() == [:changeset_error]
      assert mod.exception(:changeset_error).kind == :changeset_error
      assert mod.to_payload(mod.exception(:changeset_error)).kind == :rejected
      assert mod.http_status(mod.exception(:changeset_error)) == 422
    end
  end

  describe "new/2" do
    test "rejects unknown and output-only literal kinds at the call site" do
      for input <- [
            ":typo",
            ":unavailable",
            "%{raw: :x, kind: :typo}",
            "raw: :x, kind: :unavailable",
            "%{%{raw: :x, kind: :missing} | kind: :unavailable}"
          ] do
        error =
          compile_error!("""
          defmodule #{mod()} do
            require RintoError.Fixture.Error

            def bad do
              RintoError.Fixture.Error.new(#{input})
            end
          end
          """)

        assert error.line == 5
        assert error.file == "catalog_fixture.ex"
        assert error.description =~ "expected kind to be one of"
        assert error.description =~ ":missing"
      end
    end

    test "accepts declared literal kinds in atoms, maps, keywords and map updates" do
      for error <- [
            Error.new(:silent),
            Error.new(%{raw: :x, kind: :silent}),
            Error.new(raw: :x, kind: :silent),
            Error.new(%{%{raw: :x, kind: :missing} | kind: :silent})
          ] do
        assert error.kind == :silent
      end
    end

    test "validates dynamic atoms, maps and keywords at runtime" do
      for kind <- [:typo, :unavailable],
          input <- [kind, %{raw: :x, kind: kind}, [raw: :x, kind: kind]] do
        error = assert_raise ArgumentError, fn -> Error.new(input) end
        assert error.message =~ "expected kind to be one of"
        assert error.message =~ inspect(kind)
      end

      for input <- [:silent, %{raw: :x, kind: :silent}, [raw: :x, kind: :silent]] do
        assert Error.new(input).kind == :silent
      end
    end

    test "validates kinds at runtime when a map update has an unknown base type" do
      attrs = %{kind: :missing, data: %{id: 1}}

      assert_raise ArgumentError, ~r/expected kind/, fn ->
        Error.new(%{attrs | kind: :typo})
      end

      assert Error.new(%{attrs | kind: :silent}).kind == :silent
    end
  end

  defp source(entries) do
    "defmodule #{mod()} do\n  use RintoError\n  catalog do\n#{entries}\n  end\nend"
  end

  # Invalid definitions must compile inside the assertion, not while loading this test file.
  defp compile_error!(source) do
    assert_raise CompileError, fn -> Code.compile_string(source, "catalog_fixture.ex") end
  end

  defp mod, do: "RintoErrorCatalogFixture#{System.unique_integer([:positive])}"
end
