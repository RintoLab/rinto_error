defmodule RintoError.ChangesetKindTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias RintoError.Fixture.FieldKindError, as: Error

  test "native field classifications are independent of catalog aliases" do
    changeset =
      Changeset.cast({%{}, %{name: :string, title: :string}}, %{title: "a"}, [:name, :title])
      |> Changeset.validate_required([:name])
      |> Changeset.validate_length(:title, min: 3)

    error = Error.exception(changeset)
    payload = Error.to_payload(error)

    assert payload.kind == :invalid_input
    assert Error.http_status(error) == 422

    assert Map.new(payload.errors, &{&1.data.path, &1.kind}) == %{
             ["name"] => :required,
             ["title"] => :length
           }

    assert RintoError.Changeset.to_errors(changeset) == payload.errors

    business = Error.exception(:required)
    assert Error.to_payload(business).kind == :authentication_required
    assert Error.http_status(business) == 401
  end

  test "custom field classifications can reuse catalog names without applying aliases" do
    for kind <- [:required, :length, :invalid] do
      changeset =
        Changeset.change({%{}, %{name: :string}})
        |> RintoError.Changeset.add_error(:name, kind)

      expected = %{kind: kind, data: %{path: ["name"]}, errors: []}
      [field] = RintoError.Changeset.to_errors(changeset)

      assert field == expected
      assert Error.to_payload(Error.exception(changeset)).errors == [expected]
    end
  end

  test "nested changeset field kinds stay independent in both JSON encoders" do
    leaf =
      Changeset.change({%{}, %{name: :string}})
      |> Changeset.validate_required([:name])

    relation = %Ecto.Embedded{cardinality: :many}
    changeset = %Changeset{types: %{items: {:embed, relation}}, changes: %{items: [leaf]}}
    error = Error.exception(changeset)

    expected = %{
      kind: :invalid_input,
      data: %{},
      errors: [
        %{kind: :required, data: %{path: ["items", 0, "name"]}, errors: []}
      ]
    }

    assert Error.to_payload(error) == expected
    assert Jason.encode!(error) == Jason.encode!(expected)

    if Code.ensure_loaded?(JSON) do
      assert apply(JSON, :encode!, [error]) == apply(JSON, :encode!, [expected])
    end
  end
end
