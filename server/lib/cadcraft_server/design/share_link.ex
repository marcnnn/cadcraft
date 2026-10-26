defmodule CADCraftServer.Design.ShareLink do
  @moduledoc """
  Read-only access to a project for people who are not members (a client, a planning office,
  a phone on site). The link can expire and can hide layers; it never shows the parametric
  recipe (constraints, parameters).
  """
  use Ash.Resource,
    domain: CADCraftServer.Design,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias CADCraftServer.Checks.{ProjectRole, UserActor}

  postgres do
    table("share_links")
    repo(CADCraftServer.Repo)

    references do
      reference(:project, on_delete: :delete)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:token, :string, allow_nil?: false, public?: true, sensitive?: true)
    attribute(:hidden_layers, {:array, :string}, allow_nil?: false, default: [], public?: true)
    attribute(:expires_at, :utc_datetime, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :project, CADCraftServer.Design.Project, allow_nil?: false, public?: true
  end

  identities do
    identity(:unique_token, [:token])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:project_id, :hidden_layers, :expires_at])

      change(fn changeset, _ ->
        token = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
        Ash.Changeset.force_change_attribute(changeset, :token, token)
      end)
    end

    # Turn a token into a grant; runs before there is an actor.
    read :grant do
      argument(:token, :string, allow_nil?: false, sensitive?: true)
      get?(true)
      filter(expr(token == ^arg(:token) and (is_nil(expires_at) or expires_at > now())))
    end
  end

  policies do
    policy action(:grant) do
      authorize_if(always())
    end

    policy action(:create) do
      authorize_if({ProjectRole, roles: [:owner], project: :project_id})
    end

    policy [action_type([:read, :destroy]), UserActor] do
      authorize_if(expr(exists(project.memberships, user_id == ^actor(:id) and role == :owner)))
    end
  end

  @doc "The actor for requests made with this link."
  def to_grant(link) do
    %CADCraftServer.Design.ShareGrant{
      share_project_id: link.project_id,
      link_id: link.id,
      hidden_layers: link.hidden_layers || []
    }
  end
end
