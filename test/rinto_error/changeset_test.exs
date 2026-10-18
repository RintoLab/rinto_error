defmodule RintoError.ChangesetTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias RintoError.Fixture.Error
  alias RintoError.Fixture.{CustomChangesetKind, MinimalChangesetConfig}

  require Error
  require CustomChangesetKind
  require MinimalChangesetConfig

  describe "custom changeset kind" do
    test "keeps changeset wrapping separate from an existing changeset_error kind" do
      changeset =
        Changeset.change({%{}, %{name: :string}})
        |> RintoError.Changeset.add_error(:name, :invalid)

      error = CustomChangesetKind.new(changeset)
      assert error.kind == :validation_error
      assert error.raw == changeset
      assert error.errors == []
      assert error.metadata.origin.module == __MODULE__
      assert CustomChangesetKind.exception(changeset).kind == :validation_error
      assert CustomChangesetKind.http_status(error) == 422

      payload = %{
        kind: :invalid_input,
        data: %{},
        errors: [%{kind: :invalid, data: %{path: ["name"]}, errors: []}]
      }

      assert CustomChangesetKind.to_payload(error) == payload
      assert Jason.encode!(error) == Jason.encode!(payload)
      assert CustomChangesetKind.new(:validation_error).kind == :validation_error
      assert CustomChangesetKind.kinds() == [:changeset_error, :validation_error]

      assert List.last(CustomChangesetKind.kinds(:full)) == %{
               kind: :validation_error,
               as: :invalid_input,
               http_status: 422,
               doc: "输入校验失败"
             }

      assert CustomChangesetKind.kinds(:public)[:invalid_input] ==
               [List.last(CustomChangesetKind.kinds(:full))]

      classified = RintoError.Changeset.add_error(changeset, :name, :validation_error)

      assert hd(CustomChangesetKind.to_payload(CustomChangesetKind.new(classified)).errors).kind ==
               :validation_error

      business_error = CustomChangesetKind.new(:changeset_error)
      assert business_error.kind == :changeset_error
      assert CustomChangesetKind.http_status(business_error) == 409

      assert CustomChangesetKind.to_payload(business_error) == %{
               kind: :business_error,
               data: %{},
               errors: []
             }
    end

    test "entry_for works without optional output name, status, or doc" do
      changeset = Changeset.change({%{}, %{name: :string}})
      error = MinimalChangesetConfig.new(changeset)

      assert error.kind == :validation_error
      assert MinimalChangesetConfig.kinds() == [:changeset_error, :validation_error]

      assert MinimalChangesetConfig.to_payload(error) == %{
               kind: :validation_error,
               data: %{},
               errors: []
             }

      assert_raise ArgumentError, fn -> MinimalChangesetConfig.http_status(error) end
      assert MinimalChangesetConfig.new(:validation_error).kind == :validation_error
      assert MinimalChangesetConfig.new(:changeset_error).kind == :changeset_error
    end
  end

  defmodule Block do
    use Ecto.Schema

    schema "blocks" do
      field(:name, :string)
      field(:pos, :integer)
      belongs_to(:diagram, RintoError.ChangesetTest.Diagram)
    end
  end

  defmodule Diagram do
    use Ecto.Schema

    schema "diagrams" do
      belongs_to(:root, RintoError.ChangesetTest.Root)
      has_many(:blocks, RintoError.ChangesetTest.Block)
    end
  end

  defmodule Root do
    use Ecto.Schema

    schema "roots" do
      has_one(:diagram, RintoError.ChangesetTest.Diagram)
    end
  end

  describe "add_error/4" do
    test "adds and converts classified errors without an Error module or catalog" do
      changeset =
        Changeset.change({%{}, %{name: :string}})
        |> RintoError.Changeset.add_error(:name, :invalid)

      assert changeset.errors == [name: {"invalid", [error: :invalid]}]

      assert RintoError.Changeset.to_errors(changeset) == [
               %{kind: :invalid, data: %{path: ["name"]}, errors: []}
             ]
    end

    test "extracts the message, replaces error and preserves validation and other options" do
      message = "should be at least %{count} character(s)"

      changeset =
        Changeset.change({%{}, %{name: :string}})
        |> RintoError.Changeset.add_error(:name, :invalid,
          message: message,
          error: :unknown,
          validation: :required,
          kind: :min,
          count: 3,
          type: :string
        )

      assert [name: {^message, opts}] = changeset.errors

      assert opts == [
               error: :invalid,
               validation: :required,
               kind: :min,
               count: 3,
               type: :string
             ]

      assert Error.to_payload(Error.new(changeset)).errors == [
               %{
                 kind: :invalid,
                 data: %{path: ["name"], kind: :min, count: 3, type: %{t: :string}},
                 errors: []
               }
             ]
    end

    test "accepts catalog names as independent field classifications" do
      changeset = Changeset.change({%{}, %{name: :string}})

      for error <- [:missing, :broken, :changeset_error, :silent, :local] do
        classified = RintoError.Changeset.add_error(changeset, :name, error)

        assert Error.to_payload(Error.new(classified)).errors == [
                 %{kind: error, data: %{path: ["name"]}, errors: []}
               ]
      end
    end

    test "rejects non-atoms and nil or boolean classifications" do
      changeset = Changeset.change({%{}, %{name: :string}})

      for error <- ["invalid", nil, true, false, 1] do
        assert_raise ArgumentError, ~r/expected changeset error to be an atom/, fn ->
          RintoError.Changeset.add_error(changeset, :name, error, error: :invalid)
        end
      end
    end
  end

  describe "to_errors/1" do
    test "converts custom add_error entries without requiring classification metadata" do
      changeset =
        Changeset.change({%{}, %{name: :string, source: :string}})
        |> Changeset.validate_required([:name])
        |> Changeset.add_error(:name, "custom business failure")
        |> Changeset.add_error(:name, "another failure", reason: "unsupported character")
        |> Changeset.add_error(:source, "can't be blank")

      errors = RintoError.Changeset.to_errors(changeset)

      assert length(errors) == 4
      assert Enum.count(errors, &(&1.kind == :invalid and &1.data.path == ["name"])) == 2
      assert %{kind: :required, data: %{path: ["name"]}, errors: []} in errors
      assert %{kind: :invalid, data: %{path: ["source"]}, errors: []} in errors

      assert %{
               kind: :invalid,
               data: %{path: ["name"], reason: "unsupported character"},
               errors: []
             } in errors

      refute Jason.encode!(errors) =~ "custom business"
      refute Jason.encode!(errors) =~ "another failure"
    end

    test "classifies custom errors from metadata regardless of their message" do
      for message <- ["required", "should be at most %{count} character(s)", "translated message"] do
        changeset =
          Changeset.change({%{}, %{name: :string}})
          |> Changeset.add_error(:name, message,
            validation: :length,
            kind: :max,
            count: 20,
            constraint: :unique,
            reason: "unsupported character",
            path: ["incorrect"]
          )

        assert RintoError.Changeset.to_errors(changeset) == [
                 %{
                   kind: :length,
                   data: %{
                     path: ["name"],
                     kind: :max,
                     count: 20,
                     constraint: :unique,
                     reason: "unsupported character"
                   },
                   errors: []
                 }
               ]
      end
    end

    test "preserves Ecto length metadata without rewriting bounds" do
      for {value, options, bound} <- [
            {"a", [min: 3, max: 5], %{kind: :min, count: 3, type: %{t: :string}}},
            {"abcdef", [min: 3, max: 5], %{kind: :max, count: 5, type: %{t: :string}}},
            {"a", [is: 3], %{kind: :is, count: 3, type: %{t: :string}}}
          ] do
        changeset =
          Changeset.cast({%{}, %{name: :string}}, %{name: value}, [:name])
          |> Changeset.validate_length(:name, options ++ [message: "translated message"])

        assert RintoError.Changeset.to_errors(changeset) == [
                 %{
                   kind: :length,
                   data: Map.put(bound, :path, ["name"]),
                   errors: []
                 }
               ]
      end
    end

    test "preserves cast types, enum candidates and constraint metadata" do
      changeset =
        Changeset.cast({%{}, %{amount: :integer, role: :string}}, %{amount: "private"}, [:amount])
        |> Changeset.add_error(:role, "private enum message",
          validation: :inclusion,
          enum: ["private role"]
        )
        |> Changeset.add_error(:role, "private constraint message",
          constraint: :unique,
          constraint_name: "private_index"
        )

      errors = RintoError.Changeset.to_errors(changeset)
      assert MapSet.new(Enum.map(errors, & &1.kind)) == MapSet.new([:cast, :inclusion, :unique])
      assert %{kind: :cast, data: %{path: ["amount"], type: %{t: :integer}}, errors: []} in errors

      assert %{
               kind: :inclusion,
               data: %{path: ["role"], enum: ["private role"]},
               errors: []
             } in errors

      assert %{
               kind: :unique,
               data: %{path: ["role"], constraint: :unique, constraint_name: "private_index"},
               errors: []
             } in errors

      refute Jason.encode!(errors) =~ "private enum message"
      refute Jason.encode!(errors) =~ "private constraint message"
    end

    test "keeps relation-level errors and nested custom errors with their original list indexes" do
      valid = Changeset.change(%Block{name: "valid", pos: 1})

      invalid =
        Changeset.change(%Block{pos: 2})
        |> RintoError.Changeset.add_error(:name, :invalid)

      diagram =
        Changeset.change(%Diagram{})
        |> Changeset.put_assoc(:blocks, [valid, invalid])
        |> Changeset.add_error(:blocks, "custom collection failure")

      changeset =
        Changeset.change(%Root{})
        |> Changeset.put_assoc(:diagram, diagram)

      assert RintoError.Changeset.to_errors(changeset) == [
               %{kind: :invalid, data: %{path: ["diagram", "blocks"]}, errors: []},
               %{
                 kind: :invalid,
                 data: %{path: ["diagram", "blocks", 1, "name"]},
                 errors: []
               }
             ]
    end

    test "traverses embedded changesets as well as associations" do
      types = %{
        blocks:
          {:embed,
           %Ecto.Embedded{
             field: :blocks,
             related: Block,
             cardinality: :many,
             on_replace: :delete
           }}
      }

      invalid = Changeset.add_error(Changeset.change(%Block{}), :name, "custom failure")

      changeset =
        Changeset.change({%{blocks: []}, types})
        |> Changeset.put_embed(:blocks, [Changeset.change(%Block{}), invalid])

      assert RintoError.Changeset.to_errors(changeset) == [
               %{kind: :invalid, data: %{path: ["blocks", 1, "name"]}, errors: []}
             ]
    end

    test "returns field payloads with only kind, data, and errors" do
      changeset =
        Changeset.change({%{}, %{name: :string}})
        |> RintoError.Changeset.add_error(:name, :invalid)

      assert RintoError.Changeset.to_errors(changeset) == [
               %{kind: :invalid, data: %{path: ["name"]}, errors: []}
             ]
    end
  end
end
