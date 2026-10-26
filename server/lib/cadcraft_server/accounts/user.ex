defmodule CADCraftServer.Accounts.User do
  use Ash.Resource,
    domain: CADCraftServer.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  postgres do
    table("users")
    repo(CADCraftServer.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:email, :ci_string, allow_nil?: false, public?: true)
    attribute(:token_hash, :string, allow_nil?: false, sensitive?: true)
    timestamps()
  end

  identities do
    identity(:unique_email, [:email])
    identity(:unique_token, [:token_hash])
  end

  actions do
    defaults([:read])

    create :register do
      accept([:email])
      argument(:token, :string, allow_nil?: false, sensitive?: true)

      change(fn changeset, _ ->
        token = Ash.Changeset.get_argument(changeset, :token)
        Ash.Changeset.force_change_attribute(changeset, :token_hash, hash_token(token))
      end)
    end

    read :by_token do
      argument(:token, :string, allow_nil?: false, sensitive?: true)
      get?(true)

      prepare(fn query, _ ->
        hash = query |> Ash.Query.get_argument(:token) |> hash_token()
        Ash.Query.filter(query, token_hash == ^hash)
      end)
    end
  end

  policies do
    # The auth plug looks the caller up before there is an actor.
    policy action(:by_token) do
      authorize_if(always())
    end

    # Open registration for trying the server out; ash_authentication replaces it.
    policy action(:register) do
      authorize_if(always())
    end

    policy action(:read) do
      authorize_if(expr(id == ^actor(:id)))
    end
  end

  @doc "Tokens are stored as SHA-256 hashes, so a database dump does not leak them."
  def hash_token(token) when is_binary(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
