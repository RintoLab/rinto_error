defmodule RintoError.ChangesetTypeTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias RintoError.Fixture.Error

  defmodule EnumFields do
    use Ecto.Schema

    @values [:reviewer, :author, :admin]
    @integer_values [reviewer: 30, author: 10, admin: 20]

    embedded_schema do
      field(:role, Ecto.Enum, values: @values)
      field(:integer_role, Ecto.Enum, values: @integer_values)
      field(:roles, {:array, Ecto.Enum}, values: @values)
      field(:roles_by_group, {:map, Ecto.Enum}, values: @integer_values)
      field(:role_groups, {:array, {:map, Ecto.Enum}}, values: @values)
    end
  end

  defmodule ParameterizedCollection do
    use Ecto.ParameterizedType

    @impl true
    def init(opts) do
      %{base_type: Keyword.fetch!(opts, :base_type), private_metadata: {:internal, :only}}
    end

    @impl true
    def type(params), do: params.base_type

    @impl true
    def cast(value, params), do: Ecto.Type.cast(params.base_type, value)

    @impl true
    def load(value, _loader, params), do: Ecto.Type.load(params.base_type, value)

    @impl true
    def dump(value, _dumper, params), do: Ecto.Type.dump(params.base_type, value)
  end

  defmodule UUIDAlias do
    use Ecto.Type

    @impl true
    def type, do: Ecto.UUID

    @impl true
    defdelegate cast(value), to: Ecto.UUID

    @impl true
    defdelegate load(value), to: Ecto.UUID

    @impl true
    defdelegate dump(value), to: Ecto.UUID
  end

  defmodule CustomArray do
    use Ecto.Type

    @impl true
    def type, do: {:array, {:map, UUIDAlias}}

    @impl true
    def cast(value), do: Ecto.Type.cast(type(), value)

    @impl true
    def load(value), do: Ecto.Type.load(type(), value)

    @impl true
    def dump(value), do: Ecto.Type.dump(type(), value)
  end

  defmodule CustomMap do
    use Ecto.Type

    @impl true
    def type, do: {:map, {:array, :integer}}

    @impl true
    def cast(value), do: Ecto.Type.cast(type(), value)

    @impl true
    def load(value), do: Ecto.Type.load(type(), value)

    @impl true
    def dump(value), do: Ecto.Type.dump(type(), value)
  end

  defmodule CyclicType do
    use Ecto.Type

    @impl true
    def type, do: {:array, __MODULE__}

    @impl true
    def cast(_value), do: :error

    @impl true
    def load(_value), do: :error

    @impl true
    def dump(_value), do: :error
  end

  for {type, input} <- [
        id: "invalid",
        integer: "invalid",
        float: "invalid",
        decimal: "invalid",
        boolean: "invalid",
        string: %{},
        binary: %{},
        binary_id: %{},
        bitstring: %{},
        map: "invalid",
        date: "invalid",
        time: "invalid",
        time_usec: "invalid",
        naive_datetime: "invalid",
        naive_datetime_usec: "invalid",
        utc_datetime: "invalid",
        utc_datetime_usec: "invalid"
      ] do
    @cast_type type
    @cast_input input

    test "wraps the meaningful #{@cast_type} cast type without renaming it" do
      changeset = cast_value(@cast_type, @cast_input)
      assert_type_payload(changeset, :value, %{t: @cast_type})
    end
  end

  for {label, type, input, expected} <- [
        {"array", {:array, :integer}, ["invalid"], %{t: :array, of: %{t: :integer}}},
        {"map", {:map, :integer}, %{"key" => "invalid"}, %{t: :map, of: %{t: :integer}}},
        {"nested arrays", {:array, {:array, :integer}}, [["invalid"]],
         %{t: :array, of: %{t: :array, of: %{t: :integer}}}},
        {"nested maps", {:map, {:map, :integer}}, %{"outer" => %{"inner" => "invalid"}},
         %{t: :map, of: %{t: :map, of: %{t: :integer}}}},
        {"array of maps", {:array, {:map, :integer}}, [%{"key" => "invalid"}],
         %{t: :array, of: %{t: :map, of: %{t: :integer}}}},
        {"map of arrays", {:map, {:array, :integer}}, %{"key" => ["invalid"]},
         %{t: :map, of: %{t: :array, of: %{t: :integer}}}},
        {"UUID", Ecto.UUID, "invalid", %{t: :uuid}},
        {"array of UUID", {:array, Ecto.UUID}, ["invalid"], %{t: :array, of: %{t: :uuid}}},
        {"map of UUID", {:map, Ecto.UUID}, %{"key" => "invalid"}, %{t: :map, of: %{t: :uuid}}}
      ] do
    @cast_type type
    @cast_input input
    @expected_type expected

    test "describes #{label} with structured JSON-compatible types" do
      changeset = cast_value(@cast_type, @cast_input)
      assert_type_payload(changeset, :value, @expected_type)
    end
  end

  for field <- [:role, :integer_role] do
    @enum_field field

    test "describes #{@enum_field} with candidate names in declaration order" do
      changeset = Changeset.cast(%EnumFields{}, %{@enum_field => "unknown"}, [@enum_field])

      assert_type_payload(changeset, @enum_field, %{
        t: :enum,
        values: ["reviewer", "author", "admin"]
      })
    end
  end

  for {field, input, expected} <- [
        {:roles, ["unknown"],
         %{t: :array, of: %{t: :enum, values: ["reviewer", "author", "admin"]}}},
        {:roles_by_group, %{"editors" => "unknown"},
         %{t: :map, of: %{t: :enum, values: ["reviewer", "author", "admin"]}}},
        {:role_groups, [%{"editors" => "unknown"}],
         %{
           t: :array,
           of: %{t: :map, of: %{t: :enum, values: ["reviewer", "author", "admin"]}}
         }}
      ] do
    @enum_field field
    @cast_input input
    @expected_type expected

    test "preserves nested enum candidates in #{@enum_field}" do
      changeset = Changeset.cast(%EnumFields{}, %{@enum_field => @cast_input}, [@enum_field])
      assert_type_payload(changeset, @enum_field, @expected_type)
    end
  end

  test "describes another parameterized type through its recursively normalized underlying type" do
    type =
      Ecto.ParameterizedType.init(ParameterizedCollection, base_type: {:map, {:array, :integer}})

    changeset = cast_value(type, %{"key" => ["invalid"]})

    assert_type_payload(changeset, :value, %{
      t: :map,
      of: %{t: :array, of: %{t: :integer}}
    })
  end

  for {type, input, expected} <- [
        {UUIDAlias, "invalid", %{t: :uuid}},
        {CustomArray, [%{"key" => "invalid"}], %{t: :array, of: %{t: :map, of: %{t: :uuid}}}},
        {CustomMap, %{"key" => ["invalid"]}, %{t: :map, of: %{t: :array, of: %{t: :integer}}}}
      ] do
    @cast_type type
    @cast_input input
    @expected_type expected

    test "describes #{inspect(type)} through its recursively normalized type/0 result" do
      changeset = cast_value(@cast_type, @cast_input)
      assert_type_payload(changeset, :value, @expected_type)
    end
  end

  for {context_type, schema_type, input, opts} <- [
        {:list, {:array, :integer}, [1], [min: 2]},
        {:binary, :string, "é", [min: 3, count: :bytes]},
        {:string, :string, "é", [min: 2]},
        {:map, {:map, :integer}, %{"one" => 1}, [min: 2]}
      ] do
    @context_type context_type
    @schema_type schema_type
    @cast_input input
    @length_opts opts

    test "keeps the #{@context_type} length-error context without enriching it from the schema" do
      changeset =
        @schema_type
        |> cast_value(@cast_input)
        |> Changeset.validate_length(:value, @length_opts)

      assert [value: {_message, metadata}] = changeset.errors
      assert metadata[:validation] == :length
      assert metadata[:type] == @context_type

      data = assert_type_payload(changeset, :value, %{t: @context_type})
      assert data.kind == :min
      assert data.count == @length_opts[:min]
    end
  end

  test "rejects a cyclic custom type description instead of recursing indefinitely" do
    changeset = cast_value(CyclicType, "invalid")
    refute changeset.valid?

    assert_raise ArgumentError, ~r/cyclic Ecto type description/, fn ->
      changeset |> Error.exception() |> Error.to_payload()
    end
  end

  defp cast_value(type, input) do
    Changeset.cast({%{}, %{value: type}}, %{value: input}, [:value])
  end

  defp assert_type_payload(changeset, field, expected_type) do
    refute changeset.valid?
    assert [{^field, {_message, _opts}}] = changeset.errors

    error = Error.exception(changeset)
    payload = Error.to_payload(error)
    assert [%{data: data}] = payload.errors
    assert data.type == expected_type
    assert data.path == [Atom.to_string(field)]

    assert RintoError.Changeset.to_errors(changeset) == payload.errors
    assert Jason.encode!(error) == Jason.encode!(payload)

    if Code.ensure_loaded?(JSON) do
      # Avoid undefined-function warnings on Elixir 1.17, which has no JSON module.
      assert apply(JSON, :encode!, [error]) == apply(JSON, :encode!, [payload])
    end

    data
  end
end
