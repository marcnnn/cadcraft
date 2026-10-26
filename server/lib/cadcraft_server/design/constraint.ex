defmodule CADCraftServer.Design.Constraint do
  @moduledoc "One CADCraft constraint (its own JSON in `data`). Members only: share links never see the recipe."
  use Ash.Resource,
    domain: CADCraftServer.Design,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias CADCraftServer.Checks.UserActor

  postgres do
    table("cad_constraints")
    repo(CADCraftServer.Repo)

    references do
      reference(:drawing, on_delete: :delete)
    end
  end

  attributes do
    attribute(:cid, :integer, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:comp, :string, public?: true)
    attribute(:data, :map, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to :drawing, CADCraftServer.Design.Drawing,
      primary_key?: true,
      allow_nil?: false,
      public?: true
  end

  actions do
    defaults([:read])
  end

  policies do
    policy [action_type(:read), UserActor] do
      authorize_if(expr(exists(drawing.project.memberships, user_id == ^actor(:id))))
    end
  end
end
