defmodule RintoError.EncodingTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias RintoError.Fixture.{CatalogOptions, Error}

  require Error

  describe "Jason encoding" do
    test "encodes output aliases without HTTP configuration or alias registration" do
      error = CatalogOptions.exception(:broken)
      payload = %{kind: :unavailable, data: %{}, errors: []}
      assert CatalogOptions.to_payload(error) == payload
      assert Jason.encode!(error) == Jason.encode!(payload)
    end

    test "matches to_payload and hides raw, message, and metadata" do
      error = Error.new(:broken, "hidden reason")
      payload = Error.to_payload(error)

      assert Jason.encode!(error) == Jason.encode!(payload)
      refute Jason.encode!(error) =~ "hidden reason"
      refute Jason.encode!(error) =~ "broken"
    end

    test "encodes an expanded changeset the same way as its payload" do
      changeset =
        {%{}, %{name: :string}}
        |> Changeset.cast(%{name: "a"}, [:name])
        |> Changeset.validate_length(:name, min: 3)

      error = Error.new(changeset, "hidden changeset message")
      payload = Error.to_payload(error)

      assert Jason.encode!(error) == Jason.encode!(payload)
      refute Jason.encode!(error) =~ "hidden changeset message"
    end
  end

  describe "standard-library JSON encoding" do
    @describetag skip: not Code.ensure_loaded?(JSON)

    test "encodes output aliases without HTTP configuration or alias registration" do
      error = CatalogOptions.exception(:broken)
      payload = %{kind: :unavailable, data: %{}, errors: []}
      assert CatalogOptions.to_payload(error) == payload
      assert json_encode!(error) == json_encode!(payload)
    end

    test "matches to_payload and hides raw, message, and metadata" do
      error = Error.new(:broken, "hidden reason")
      payload = Error.to_payload(error)

      assert json_encode!(error) == json_encode!(payload)
      refute json_encode!(error) =~ "hidden reason"
      refute json_encode!(error) =~ "broken"
    end

    test "encodes an expanded changeset the same way as its payload" do
      changeset =
        {%{}, %{name: :string}}
        |> Changeset.cast(%{name: "a"}, [:name])
        |> Changeset.validate_length(:name, min: 3)

      error = Error.new(changeset, "hidden changeset message")
      payload = Error.to_payload(error)

      assert json_encode!(error) == json_encode!(payload)
      refute json_encode!(error) =~ "hidden changeset message"
    end
  end

  # Avoid an undefined-function warning on Elixir 1.17, which has no JSON module.
  defp json_encode!(term), do: apply(JSON, :encode!, [term])
end
