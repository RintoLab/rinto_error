defmodule RintoErrorTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias RintoError.Fixture.Error

  require Error

  @kind :broken

  test "parameterized error contracts describe kind independently of raw" do
    error = RintoError.Fixture.ErrorContract.from_database()

    assert %Error{kind: :broken, raw: :db_down} = error
    assert RintoError.Fixture.ErrorContract.kind(error) == :broken
  end

  test "default error contracts accept catalog kinds and explicit types allow arbitrary kinds" do
    for kind <- Error.kinds() do
      assert RintoError.Fixture.ErrorContract.known_kind(Error.exception(kind)) == kind
    end

    error = %Error{kind: :outside_catalog, raw: nil}
    assert RintoError.Fixture.ErrorContract.arbitrary_kind(error) == :outside_catalog
  end

  describe "kinds/0" do
    test "lists all declared kinds in entry order" do
      assert Error.kinds() == [:missing, :broken, :local, :silent, :changeset_error]

      assert Error.payload_kinds() == %{broken: :unavailable}

      assert Error.statuses() == %{
               missing: 404,
               broken: 500,
               changeset_error: 422
             }
    end
  end

  describe "exception/1" do
    test "accepts constructable kinds from atoms, maps and keywords" do
      assert %Error{raw: @kind, kind: @kind} = Error.exception(@kind)
      assert %Error{raw: :db_down, kind: @kind} = Error.exception(%{raw: :db_down, kind: @kind})
      assert %Error{raw: :db_down, kind: @kind} = Error.exception(raw: :db_down, kind: @kind)
    end

    test "defaults omitted raw to nil in maps and keywords" do
      for attrs <- [%{kind: :missing, data: %{id: 1}}, [kind: :missing, data: %{id: 1}]] do
        assert %Error{raw: nil, kind: :missing, data: %{id: 1}} = Error.exception(attrs)
      end
    end

    test "preserves explicit raw values in maps and keywords" do
      for raw <- [nil, false, :db_down],
          attrs <- [%{raw: raw, kind: @kind}, [raw: raw, kind: @kind]] do
        assert Error.exception(attrs).raw === raw
      end
    end

    test "defaults raw while inferring kind from an explicit source" do
      for attrs <- [%{__source__: Changeset}, [__source__: Changeset]] do
        assert %Error{raw: nil, kind: :changeset_error, __source__: Changeset} =
                 Error.exception(attrs)
      end
    end

    test "every declared kind is constructable" do
      for kind <- Error.kinds() do
        assert Error.exception(kind).kind == kind
      end

      assert Error.new(:silent).kind == :silent
      assert Error.new(:changeset_error).kind == :changeset_error
    end

    test "rejects output-only names and unknown kinds" do
      for input <- [
            :unavailable,
            %{raw: :probe_raw, kind: :unavailable},
            [raw: :probe_raw, kind: :not_a_kind],
            %{kind: :unavailable},
            [kind: :not_a_kind]
          ] do
        error = assert_raise ArgumentError, fn -> Error.exception(input) end
        assert error.message =~ "expected kind to be one of"
      end
    end

    test "raises struct! errors when required keys are missing or unknown" do
      assert_raise ArgumentError, fn -> Error.exception(%{}) end
      assert_raise ArgumentError, fn -> Error.exception(raw: :probe_raw) end

      assert_raise KeyError, fn ->
        Error.exception(%{raw: :probe_raw, kind: :missing, extra: 1})
      end

      assert_raise KeyError, fn -> Error.exception(kind: :missing, extra: 1) end
    end

    test "direct struct construction still requires raw" do
      assert_raise ArgumentError, fn -> struct!(Error, kind: :missing) end
    end

    test "builds a registered changeset without expanding fields" do
      changeset =
        {%{}, %{name: :string}}
        |> Changeset.cast(%{}, [:name])
        |> Changeset.validate_required([:name])

      error = Error.exception(changeset)

      assert error.raw == changeset
      assert error.kind == :changeset_error
      assert error.errors == []
      assert error.metadata == %{}
    end
  end

  describe "new/2" do
    test "defaults raw to nil for literal maps and keywords and records origin" do
      for error <- [
            Error.new(%{kind: :missing, data: %{id: 1}}),
            Error.new(kind: :missing, data: %{id: 1})
          ] do
        assert error.raw == nil
        assert error.kind == :missing
        assert error.data == %{id: 1}
        assert error.metadata.origin.module == __MODULE__
      end
    end

    test "records the caller's module, function and exact line" do
      line = __ENV__.line + 1
      error = Error.new(raw: :db_down, kind: @kind)

      assert error.metadata.origin == %{
               module: __MODULE__,
               function: __ENV__.function,
               line: line
             }

      assert %Error{raw: :db_down, kind: @kind} = error
    end

    test "evaluates attributes once and preserves metadata except the reserved origin" do
      attrs = [
        raw: :probe_raw,
        kind: @kind,
        data: %{attempt: 2},
        metadata: %{operation: :probe, origin: %{module: :incorrect}}
      ]

      error =
        Error.new(
          (
            send(self(), :attributes_evaluated)
            attrs
          )
        )

      assert_received :attributes_evaluated
      refute_received :attributes_evaluated
      assert error.metadata.operation == :probe
      assert error.metadata.origin.module == __MODULE__
      assert error.data == %{attempt: 2}
    end

    test "preserves error details when recording the construction site" do
      details = [%{field: "name", message: "required", metadata: %{origin: :validation}}]
      line = __ENV__.line + 1
      error = Error.new(kind: @kind, errors: details)

      assert error.errors == details
      assert error.metadata.origin.line == line
    end

    test "uses atoms from literals and runtime values as both raw and kind" do
      assert %Error{raw: @kind, kind: @kind, message: nil} = Error.new(@kind)

      kind = @kind
      line = __ENV__.line + 1
      error = Error.new(kind)

      assert error.raw == kind
      assert error.kind == kind
      assert error.metadata.origin.line == line
    end

    test "accepts literal maps and maps returned at runtime" do
      assert %Error{raw: :probe_raw, kind: @kind} = Error.new(%{raw: :probe_raw, kind: @kind})

      error =
        Error.new(
          Map.new(
            raw: :probe_child,
            kind: @kind,
            metadata: %{operation: :probe}
          )
        )

      assert error.raw == :probe_child
      assert error.kind == @kind
      assert error.metadata.operation == :probe
      assert error.metadata.origin.module == __MODULE__
    end

    test "wraps a changeset without interpreting its field errors and still records origin" do
      changeset =
        {%{}, %{name: :string}}
        |> Changeset.cast(%{}, [:name])
        |> Changeset.validate_required([:name])

      error = Error.new(changeset)

      assert error.raw == changeset
      assert error.kind == :changeset_error
      assert error.errors == []
      assert error.metadata.origin.module == __MODULE__
    end

    test "accepts an explicit message for atoms and changeset expressions" do
      assert %Error{raw: @kind, kind: @kind, message: "storage is down"} =
               Error.new(@kind, "storage is down")

      error = Error.new(Changeset.change({%{}, %{name: :string}}), "invalid record")

      assert %Changeset{} = error.raw
      assert error.kind == :changeset_error
      assert error.message == "invalid record"
    end

    test "preserves attribute messages unless a non-nil override is supplied" do
      for attrs <- [
            %{raw: :missing_raw, kind: @kind, message: "Original"},
            [raw: :missing_raw, kind: @kind, message: "Original"]
          ] do
        assert Error.new(attrs).message == "Original"
        assert Error.new(attrs, nil).message == "Original"
        assert Error.new(attrs, "Override").message == "Override"
        assert Error.new(attrs, "").message == ""
      end
    end

    test "evaluates input and message expressions once" do
      error =
        Error.new(
          (
            send(self(), :input_evaluated)
            @kind
          ),
          (
            send(self(), :message_evaluated)
            "storage is down"
          )
        )

      assert error.raw == @kind
      assert error.message == "storage is down"
      assert_received :input_evaluated
      refute_received :input_evaluated
      assert_received :message_evaluated
      refute_received :message_evaluated
    end
  end

  describe "to_payload/1" do
    test "publishes the payload kind and hides implementation names" do
      payload = Error.to_payload(Error.new(@kind))

      assert payload == %{kind: :unavailable, data: %{}, errors: []}
      refute inspect(payload) =~ "broken"
      assert Jason.encode!(payload) =~ ~s("kind":"unavailable")

      assert Error.to_payload(Error.new(:missing)) == %{
               kind: :missing,
               data: %{},
               errors: []
             }
    end

    test "preserves detail shapes and kinds while exposing only the outer public fields" do
      details = [
        %{field: "name", message: "required"},
        %{kind: :broken, errors: [%{kind: :required, metadata: %{rule: "presence"}}]}
      ]

      error =
        Error.new(
          raw: :private_raw,
          kind: @kind,
          message: "private message",
          metadata: %{secret: "private metadata"},
          errors: details
        )

      assert Error.to_payload(error) == %{kind: :unavailable, data: %{}, errors: details}
      assert error.errors == details
      refute Jason.encode!(error) =~ "private"
    end

    test "expands only at output time and uses the current changeset without caching" do
      changeset = Changeset.change({%{}, %{name: :string}})
      error = Error.new(changeset)
      assert Error.to_payload(error).errors == []

      changeset = Changeset.add_error(error.raw, :name, "custom failure")
      updated = %{error | raw: changeset}
      expected = [%{kind: :invalid, data: %{path: ["name"]}, errors: []}]

      assert Error.to_payload(updated).errors == expected
      assert Error.to_payload(updated).errors == expected
      assert updated.errors == []
      assert updated.raw == changeset
      assert Error.to_payload(error).errors == []
    end

    test "changeset errors are the sole source even when Error.errors is populated" do
      changeset = Changeset.change({%{}, %{name: :string}})
      details = [%{field: "other", message: "unrelated detail"}]

      error = %Error{
        __source__: Ecto.Changeset,
        raw: changeset,
        kind: :changeset_error,
        errors: details
      }

      assert Error.to_payload(error).errors == []

      changeset = Changeset.validate_required(changeset, [:name])
      error = %{error | raw: changeset}

      assert Error.to_payload(error).errors == [
               %{kind: :required, data: %{path: ["name"]}, errors: []}
             ]

      assert error.errors == details
      assert error.raw == changeset
    end

    test "maps :changeset_error when the catalog gives it a public kind" do
      mod = RintoError.Fixture.ChangesetOutput

      changeset = Changeset.add_error(Changeset.change({%{}, %{name: :string}}), :name, "x")
      payload = mod.to_payload(mod.exception(changeset))

      assert payload.kind == :rejected
      assert payload.errors == [%{kind: :invalid, data: %{path: ["name"]}, errors: []}]
    end
  end

  describe "http_status/1" do
    test "reads the stored kind when it differs from the public kind" do
      error = Error.new(@kind)

      assert Error.to_payload(error).kind == :unavailable
      assert Error.http_status(error) == 500
      assert Error.http_status(Error.new(:missing)) == 404
    end

    test "raises for an omitted status, an output-only name, and an unknown kind" do
      for error <- [
            Error.new(:local),
            Error.new(:silent),
            %Error{raw: :x, kind: :unavailable},
            %Error{raw: :x, kind: :required}
          ] do
        raised = assert_raise ArgumentError, fn -> Error.http_status(error) end
        assert raised.message =~ "HTTP status"
        assert raised.message =~ inspect(error.kind)
      end
    end

    test "uses the changeset entry status when that entry declares one" do
      error = Error.exception(Changeset.change({%{}, %{}}))
      assert Error.http_status(error) == 422
    end
  end

  describe "message/1" do
    test "includes diagnostics except raw with or without an explicit message" do
      details = [%{field: "name", message: "required"}]

      for message <- [nil, "operation explanation"] do
        error =
          Error.new(
            raw: :probe_raw,
            kind: @kind,
            message: message,
            data: %{attempt: 3},
            errors: details,
            metadata: %{operation: :probe}
          )

        text = Error.message(error)

        assert String.starts_with?(text, "RintoError.Fixture.Error\n  kind:")
        refute text =~ "raw:"
        refute text =~ ":probe_raw"
        assert text =~ "kind: :broken"
        assert text =~ "message: #{inspect(message)}"
        assert text =~ "data: %{attempt: 3}"
        assert text =~ "\n  errors: ["
        assert text =~ ~s(field: "name")
        assert text =~ ~s(message: "required")
        assert text =~ "operation: :probe"
        assert text =~ "origin:"
        assert Exception.message(error) == text
      end
    end

    test "retains long diagnostic strings and collection tails" do
      details = String.duplicate("detail", 1_000) <> "diagnostic end"

      error =
        Error.new(
          raw: :probe_raw,
          kind: @kind,
          metadata: %{details: details, items: List.duplicate(:item, 60) ++ [:last_item]}
        )

      text = Error.message(error)

      assert text =~ details
      assert text =~ ":last_item"
      assert text =~ "message: nil"
    end
  end

  describe "raise" do
    test "raising an existing error preserves its construction site and records the raise site" do
      error = Error.new(raw: :db_down, kind: @kind)
      raise_line = __ENV__.line + 4

      {caught, stacktrace} =
        try do
          raise error
        rescue
          caught in Error -> {caught, __STACKTRACE__}
        end

      assert caught == error
      assert Exception.message(caught) =~ "kind: :broken"
      [{module, function, arity, location} | _] = stacktrace
      assert module == __MODULE__
      assert {function, arity} == __ENV__.function
      assert location[:line] == raise_line
    end

    test "supports raise with attributes and an explicit message without writing origin" do
      error =
        assert_raise Error, fn ->
          raise Error,
            raw: :probe_raw,
            kind: @kind,
            message: "The upload failed",
            metadata: %{operation: :probe}
        end

      assert error.metadata == %{operation: :probe}
      assert error.message == "The upload failed"
      assert Exception.message(error) =~ "message: \"The upload failed\""
      refute Exception.message(error) =~ "raw:"
    end

    test "keeps raw visible through the default inspect" do
      error = Error.new(:missing)
      assert inspect(error) =~ "raw: :missing"
    end
  end
end
