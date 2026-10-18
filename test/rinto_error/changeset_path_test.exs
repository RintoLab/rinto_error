defmodule RintoError.ChangesetPathTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias RintoError.Fixture.Error

  defmodule EmbeddedItem do
    use Ecto.Schema

    @primary_key {:id, :integer, autogenerate: false}
    embedded_schema do
      field(:name, :string)
    end

    def changeset(data, params) do
      data
      |> Changeset.cast(params, [:id, :name])
      |> Changeset.validate_required(:name)
    end
  end

  defmodule EmbeddedGroup do
    use Ecto.Schema

    @primary_key {:id, :integer, autogenerate: false}
    embedded_schema do
      embeds_many(:items, EmbeddedItem, on_replace: :delete)
    end

    def changeset(data, params) do
      data
      |> Changeset.cast(params, [:id])
      |> Changeset.cast_embed(:items)
    end
  end

  defmodule EmbeddedRoot do
    use Ecto.Schema

    embedded_schema do
      embeds_one(:group, EmbeddedGroup)
    end
  end

  defmodule AssociatedItem do
    use Ecto.Schema

    schema "path_items" do
      field(:name, :string)
      field(:delete, :boolean, virtual: true, default: false)
      belongs_to(:group, RintoError.ChangesetPathTest.AssociatedGroup)
    end

    def changeset(data, params) do
      changeset =
        data
        |> Changeset.cast(params, [:name, :delete])
        |> Changeset.validate_required(:name)

      if Changeset.get_field(changeset, :delete) do
        %{changeset | action: :delete}
      else
        changeset
      end
    end
  end

  defmodule AssociatedGroup do
    use Ecto.Schema

    schema "path_groups" do
      belongs_to(:root, RintoError.ChangesetPathTest.AssociatedRoot)
      has_many(:items, AssociatedItem, on_replace: :delete)
    end

    def changeset(data, params) do
      data
      |> Changeset.cast(params, [])
      |> Changeset.cast_assoc(:items)
    end
  end

  defmodule AssociatedRoot do
    use Ecto.Schema

    schema "path_roots" do
      has_one(:group, AssociatedGroup)
    end
  end

  test "cast_embed replacement keeps nested indexes aligned with submitted valid and invalid rows" do
    data = %EmbeddedRoot{
      group: %EmbeddedGroup{
        id: 10,
        items: [%EmbeddedItem{id: 1, name: "old first"}, %EmbeddedItem{id: 2, name: "old second"}]
      }
    }

    params = %{
      "group" => %{
        "id" => 10,
        "items" => [%{"name" => "valid"}, %{"name" => ""}]
      }
    }

    changeset =
      data
      |> Changeset.cast(params, [])
      |> Changeset.cast_embed(:group)

    items = changeset.changes.group.changes.items
    assert Enum.count(items, &(&1.action == :replace)) == 2

    assert Error.to_payload(Error.exception(changeset)).errors == [
             %{kind: :required, data: %{path: ["group", "items", 1, "name"]}, errors: []}
           ]
  end

  test "cast_assoc replacement keeps nested indexes and still counts submitted delete and valid rows" do
    items = [
      Ecto.put_meta(%AssociatedItem{id: 1, group_id: 10, name: "replaced"}, state: :loaded),
      Ecto.put_meta(%AssociatedItem{id: 2, group_id: 10, name: "deleted"}, state: :loaded)
    ]

    group =
      Ecto.put_meta(%AssociatedGroup{id: 10, root_id: 100, items: items}, state: :loaded)

    data = Ecto.put_meta(%AssociatedRoot{id: 100, group: group}, state: :loaded)

    params = %{
      "group" => %{
        "id" => 10,
        "items" => [
          %{"id" => 2, "delete" => true},
          %{"name" => "valid"},
          %{"name" => ""}
        ]
      }
    }

    changeset =
      data
      |> Changeset.cast(params, [])
      |> Changeset.cast_assoc(:group)

    assert Enum.map(changeset.changes.group.changes.items, & &1.action) == [
             :replace,
             :delete,
             :insert,
             :insert
           ]

    assert Error.to_payload(Error.exception(changeset)).errors == [
             %{kind: :required, data: %{path: ["group", "items", 2, "name"]}, errors: []}
           ]
  end
end
