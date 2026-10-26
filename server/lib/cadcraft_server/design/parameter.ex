defmodule CADCraftServer.Design.Parameter do
  @moduledoc "One user parameter (Parameters Manager). Members only, like constraints."
  use Ash.Resource,
    domain: CADCraftServer.Design,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias CADCraftServer.Checks.UserActor

  postgres do
    table("cad_parameters")
    repo(CADCraftServer.Repo)

    references do
      reference(:drawing, on_delete: :delete)
    end
  end

  attributes do
    attribute(:name, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:expr, :string, allow_nil?: false, public?: true)
    attribute(:description, :string, allow_nil?: false, default: "", public?: true)
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
