defmodule CADCraftServer.Design.Membership do
  @moduledoc """
  A user's role in a project:

    * `:owner` - everything, including members, share links and deleting the project
    * `:editor` - drawings: create, commit, lease components
    * `:commenter` - read, and (once review notes land) comment
    * `:viewer` - read
  """
  use Ash.Resource,
    domain: CADCraftServer.Design,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias CADCraftServer.Checks.{ProjectRole, UserActor}

  @roles [:owner, :editor, :commenter, :viewer]

  postgres do
    table("memberships")
    repo(CADCraftServer.Repo)

    references do
      reference(:project, on_delete: :delete)
      reference(:user, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:role, :atom, allow_nil?: false, public?: true, constraints: [one_of: @roles])
    timestamps()
  end

  relationships do
    belongs_to :project, CADCraftServer.Design.Project, allow_nil?: false, public?: true
    belongs_to :user, CADCraftServer.Accounts.User, allow_nil?: false, public?: true
  end

  identities do
    identity(:one_role_per_project, [:project_id, :user_id])
  end

  actions do
    defaults([:read, :destroy])

    create :invite do
      accept([:project_id, :user_id, :role])
      primary?(true)
    end

    # Only the project's create action makes the first owner, with authorization off.
    create :seed_owner do
      accept([:project_id, :user_id])
      change(set_attribute(:role, :owner))
    end

    update :set_role do
      accept([:role])
      primary?(true)
    end
  end

  policies do
    policy [action_type(:read), UserActor] do
      authorize_if(expr(exists(project.memberships, user_id == ^actor(:id))))
    end

    policy action(:invite) do
      authorize_if({ProjectRole, roles: [:owner], project: :project_id})
    end

    policy action(:seed_owner) do
      forbid_if(always())
    end

    policy action_type([:update, :destroy]) do
      authorize_if(expr(exists(project.memberships, user_id == ^actor(:id) and role == :owner)))
    end
  end

  def roles, do: @roles
end
