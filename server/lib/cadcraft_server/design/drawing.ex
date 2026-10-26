defmodule CADCraftServer.Design.Drawing do
  @moduledoc """
  A drawing in a project, with the georeference that places its local CAD coordinates on the
  map: drawing units are scaled by `unit_scale`, rotated by `rotation` (degrees, counter-
  clockwise), moved to (`origin_x`, `origin_y`) and read as coordinates of `srid` (for example
  25832, UTM 32N). Tiles are cut from that, reprojected to Web Mercator.

  `revision` counts commits; a commit names the revision it was solved against and is refused
  when someone else committed in between.
  """
  use Ash.Resource,
    domain: CADCraftServer.Design,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias CADCraftServer.Checks.{ProjectRole, ShareActor, UserActor}

  @georef [:srid, :origin_x, :origin_y, :rotation, :unit_scale]

  postgres do
    table("cad_drawings")
    repo(CADCraftServer.Repo)

    references do
      reference(:project, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:revision, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:srid, :integer, allow_nil?: false, default: 3857, public?: true)
    attribute(:origin_x, :float, allow_nil?: false, default: 0.0, public?: true)
    attribute(:origin_y, :float, allow_nil?: false, default: 0.0, public?: true)
    attribute(:rotation, :float, allow_nil?: false, default: 0.0, public?: true)
    attribute(:unit_scale, :float, allow_nil?: false, default: 1.0, public?: true)

    # Chord tolerance (drawing units) for the flattened geometry used by tiles.
    attribute(:tolerance, :float,
      allow_nil?: false,
      default: 0.01,
      public?: true,
      constraints: [greater_than: 0.0]
    )

    timestamps()
  end

  relationships do
    belongs_to :project, CADCraftServer.Design.Project, allow_nil?: false, public?: true
    has_many :entities, CADCraftServer.Design.Entity
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:project_id, :name, :tolerance | @georef])
    end

    update :update do
      primary?(true)
      accept([:name | @georef])
      # Moving the drawing on the map re-places its tile geometry (database trigger).
    end

    action :commit, :map do
      description("Store a solved edit: see CADCraftServer.Design.Commit.")
      argument(:drawing_id, :uuid, allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false)
      # CADCraft entities (its own JSON) added or changed.
      argument(:upserts, {:array, :map}, default: [])
      # Hex handles of deleted entities.
      argument(:deletes, {:array, :string}, default: [])
      # The whole constraint and parameter lists, when they changed.
      argument(:constraints, {:array, :map})
      argument(:parameters, {:array, :map})
      run(CADCraftServer.Design.Commit)
    end
  end

  policies do
    policy [action_type(:read), UserActor] do
      authorize_if(expr(exists(project.memberships, user_id == ^actor(:id))))
    end

    policy [action_type(:read), ShareActor] do
      authorize_if(expr(project_id == ^actor(:share_project_id)))
    end

    policy action(:create) do
      authorize_if({ProjectRole, roles: [:owner, :editor], project: :project_id})
    end

    policy action(:commit) do
      authorize_if({ProjectRole, roles: [:owner, :editor], drawing: :drawing_id})
    end

    policy action(:update) do
      authorize_if(
        expr(
          exists(
            project.memberships,
            user_id == ^actor(:id) and role in [:owner, :editor]
          )
        )
      )
    end

    policy action(:destroy) do
      authorize_if(expr(exists(project.memberships, user_id == ^actor(:id) and role == :owner)))
    end
  end
end
