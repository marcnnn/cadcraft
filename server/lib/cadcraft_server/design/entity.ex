defmodule CADCraftServer.Design.Entity do
  @moduledoc """
  One model-space entity as last committed. `data` is the entity in CADCraft's own JSON and is
  the source of truth; CADCraft reads it back losslessly.

  The table also has geometry columns that Ash does not load (Elixir's `geo` cannot decode
  PostGIS curves): `exact` (curves kept, local coordinates), `flat` (lines, local coordinates)
  and `tile_geom` (`flat` georeferenced to Web Mercator, kept up to date by a trigger), plus
  `tags`, the vector tile properties. See the `cad_geometry` migration.
  """
  use Ash.Resource,
    domain: CADCraftServer.Design,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias CADCraftServer.Checks.{ShareActor, UserActor}

  postgres do
    table("cad_entities")
    repo(CADCraftServer.Repo)

    references do
      reference(:drawing, on_delete: :delete)
    end

    custom_indexes do
      index([:drawing_id, :comp], where: "comp IS NOT NULL")
    end
  end

  attributes do
    # Hex handle, unique per drawing.
    attribute(:handle, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:kind, :string, allow_nil?: false, public?: true)
    attribute(:layer, :string, allow_nil?: false, public?: true)
    # Constraint component key (hex handle), nil when unconstrained.
    attribute(:comp, :string, public?: true)
    attribute(:data, :map, allow_nil?: false, public?: true)
    # The drawing revision that last wrote this entity.
    attribute(:revision, :integer, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to :drawing, CADCraftServer.Design.Drawing,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end

  actions do
    defaults([:read])

    # Entities whose flattened geometry touches a box in drawing coordinates.
    read :in_view do
      argument(:drawing_id, :uuid, allow_nil?: false)
      argument(:min_x, :float, allow_nil?: false)
      argument(:min_y, :float, allow_nil?: false)
      argument(:max_x, :float, allow_nil?: false)
      argument(:max_y, :float, allow_nil?: false)

      filter(
        expr(
          drawing_id == ^arg(:drawing_id) and
            fragment(
              "flat && ST_MakeEnvelope(?, ?, ?, ?, 0)",
              ^arg(:min_x),
              ^arg(:min_y),
              ^arg(:max_x),
              ^arg(:max_y)
            )
        )
      )
    end
  end

  policies do
    policy [action_type(:read), UserActor] do
      authorize_if(expr(exists(drawing.project.memberships, user_id == ^actor(:id))))
    end

    policy [action_type(:read), ShareActor] do
      authorize_if(
        expr(
          drawing.project_id == ^actor(:share_project_id) and
            layer not in ^actor(:hidden_layers)
        )
      )
    end
  end
end
