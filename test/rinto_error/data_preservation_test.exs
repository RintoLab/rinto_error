defmodule RintoError.DataPreservationTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias RintoError.Fixture.{DetailedSource, Error, SourceError}

  test "ordinary errors preserve caller data and details without normalization" do
    data = %{
      type: {:array, :integer},
      position: {12, 34},
      nested: [%{type: {:map, :integer}}],
      descriptor: %{name: :array, of: :integer},
      semantic_type: Ecto.UUID,
      date: ~D[2026-10-18]
    }

    details = [%{field: "value", context: data}]
    error = Error.exception(kind: :broken, data: data, errors: details)
    payload = Error.to_payload(error)

    assert payload.data == data
    assert payload.errors == details
    assert error.data == data
    assert error.errors == details
  end

  test "Ecto normalizes only its field type and preserves caller data and other metadata" do
    type = {:array, :integer}

    data = %{
      type: type,
      position: {12, 34},
      nested: [%{type: type}],
      descriptor: %{name: :array, of: :integer},
      semantic_type: Ecto.UUID
    }

    changeset =
      Changeset.cast({%{}, %{ids: type, name: :string}}, %{ids: ["bad"]}, [:ids])
      |> Changeset.add_error(:name, "custom error", reason: {:custom, 1}, details: data)

    error = %{Error.exception(changeset) | data: data}
    payload = Error.to_payload(error)
    fields = Map.new(payload.errors, &{&1.data.path, &1.data})

    assert payload.data == data
    assert fields[["ids"]] == %{path: ["ids"], type: %{t: :array, of: %{t: :integer}}}
    assert fields[["name"]] == %{path: ["name"], reason: {:custom, 1}, details: data}
    assert error.raw == changeset

    {_message, metadata} = Keyword.fetch!(error.raw.errors, :ids)
    assert metadata[:type] == type
  end

  test "custom source data and explicit overrides retain their values" do
    data = %{
      type: {:array, :integer},
      position: {12, 34},
      descriptor: %{name: :array, of: :integer},
      semantic_type: Ecto.UUID
    }

    error = SourceError.exception(%DetailedSource{reason: data})
    error = %{error | data: %{type: {:map, :integer}}}

    assert SourceError.to_payload(error).data == %{
             reason: data,
             context: SourceError,
             type: {:map, :integer}
           }
  end
end
