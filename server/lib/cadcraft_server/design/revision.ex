defmodule CADCraftServer.Design.Revision do
  @moduledoc "One accepted commit: who, when, and which entities it touched."
  use Ash.Resource,
    domain: CADCraftServer.Design,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias CADCraftServer.Checks.UserActor

  postgres do
    table("cad_revisions")
    repo(CADCraftServer.Repo)

    references do
      reference(:drawing, on_delete: :delete)
      reference(:author, on_delete: :nilify)
    end
  end

  attributes do
    attribute(:number, :integer, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:touched, {:array, :string}, allow_nil?: false, default: [], public?: true)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :drawing, CADCraftServer.Design.Drawing,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :author, CADCraftServer.Accounts.User, public?: true
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
