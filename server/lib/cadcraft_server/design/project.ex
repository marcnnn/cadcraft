defmodule CADCraftServer.Design.Project do
  use Ash.Resource,
    domain: CADCraftServer.Design,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias CADCraftServer.Checks.{ShareActor, UserActor}

  postgres do
    table("projects")
    repo(CADCraftServer.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    has_many :memberships, CADCraftServer.Design.Membership
    has_many :drawings, CADCraftServer.Design.Drawing
    has_many :share_links, CADCraftServer.Design.ShareLink
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:name])
      primary?(true)

      # Whoever creates a project owns it.
      change(
        after_action(fn _changeset, project, context ->
          CADCraftServer.Design.Membership
          |> Ash.Changeset.for_create(:seed_owner, %{
            project_id: project.id,
            user_id: context.actor.id
          })
          |> Ash.create(authorize?: false)
          |> case do
            {:ok, _} -> {:ok, project}
            error -> error
          end
        end)
      )
    end

    update :update do
      accept([:name])
      primary?(true)
    end
  end

  policies do
    policy action_type(:create) do
      authorize_if(UserActor)
    end

    policy [action_type(:read), UserActor] do
      authorize_if(expr(exists(memberships, user_id == ^actor(:id))))
    end

    policy [action_type(:read), ShareActor] do
      authorize_if(expr(id == ^actor(:share_project_id)))
    end

    policy action_type([:update, :destroy]) do
      authorize_if(expr(exists(memberships, user_id == ^actor(:id) and role == :owner)))
    end
  end
end
