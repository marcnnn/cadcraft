defmodule CADCraftServer.Design.Lease do
  @moduledoc """
  A short claim on one constraint component while a user drags a grip or edits a dimension in
  it. Others see who holds what (the channel broadcasts it) and their commits touching the
  component are refused until the lease ends or runs out. The holder renews it while editing.

  Leases are coordination, not correctness: every commit is still checked against the
  constraints and against the revision it was solved on.
  """
  use Ash.Resource,
    domain: CADCraftServer.Design,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias CADCraftServer.Checks.{ProjectRole, UserActor}
  alias CADCraftServer.Repo

  @default_ms 5_000
  @max_ms 60_000

  postgres do
    table("cad_leases")
    repo(CADCraftServer.Repo)

    references do
      reference(:drawing, on_delete: :delete)
      reference(:user, on_delete: :delete)
    end
  end

  attributes do
    attribute(:comp, :string, primary_key?: true, allow_nil?: false, public?: true)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to :drawing, CADCraftServer.Design.Drawing,
      primary_key?: true,
      allow_nil?: false,
      public?: true

    belongs_to :user, CADCraftServer.Accounts.User, allow_nil?: false, public?: true
  end

  actions do
    defaults([:read])

    action :acquire, :map do
      argument(:drawing_id, :uuid, allow_nil?: false)
      argument(:comp, :string, allow_nil?: false)

      argument(:duration_ms, :integer,
        default: @default_ms,
        constraints: [min: 100, max: @max_ms]
      )

      run(fn input, context -> acquire(input.arguments, context.actor) end)
    end

    action :release, :map do
      argument(:drawing_id, :uuid, allow_nil?: false)
      argument(:comp, :string, allow_nil?: false)
      run(fn input, context -> release(input.arguments, context.actor) end)
    end
  end

  policies do
    policy [action_type(:read), UserActor] do
      authorize_if(expr(exists(drawing.project.memberships, user_id == ^actor(:id))))
    end

    policy action([:acquire, :release]) do
      authorize_if({ProjectRole, roles: [:owner, :editor], drawing: :drawing_id})
    end
  end

  # Take the lease when it is free, expired or already ours (then renew it), in one statement.
  defp acquire(%{drawing_id: drawing_id, comp: comp} = args, actor) do
    ms = Map.get(args, :duration_ms, @default_ms)

    sql = """
    INSERT INTO cad_leases (drawing_id, comp, user_id, expires_at)
    VALUES ($1, $2, $3, now() + make_interval(secs => $4::float8 / 1000))
    ON CONFLICT (drawing_id, comp) DO UPDATE
      SET user_id = EXCLUDED.user_id, expires_at = EXCLUDED.expires_at
      WHERE cad_leases.user_id = EXCLUDED.user_id OR cad_leases.expires_at < now()
    RETURNING expires_at
    """

    case Repo.query(sql, [dump(drawing_id), comp, dump(actor.id), ms]) do
      {:ok, %{rows: [[expires_at]]}} ->
        broadcast(drawing_id, "lease", %{comp: comp, user_id: actor.id, expires_at: expires_at})
        {:ok, %{comp: comp, expires_at: expires_at}}

      {:ok, %{rows: []}} ->
        {:error, "component #{comp} is leased by #{holder(drawing_id, comp)}"}

      {:error, e} ->
        {:error, e}
    end
  end

  defp release(%{drawing_id: drawing_id, comp: comp}, actor) do
    Repo.query!(
      "DELETE FROM cad_leases WHERE drawing_id = $1 AND comp = $2 AND user_id = $3",
      [dump(drawing_id), comp, dump(actor.id)]
    )

    broadcast(drawing_id, "lease_released", %{comp: comp, user_id: actor.id})
    {:ok, %{comp: comp}}
  end

  defp holder(drawing_id, comp) do
    case Repo.query("SELECT user_id FROM cad_leases WHERE drawing_id = $1 AND comp = $2", [
           dump(drawing_id),
           comp
         ]) do
      {:ok, %{rows: [[id]]}} -> Ecto.UUID.cast!(id)
      _ -> "someone else"
    end
  end

  @doc """
  Components among `comps` that someone other than `user_id` holds a live lease on.
  Commits call this inside their transaction.
  """
  def held_by_others(drawing_id, comps, user_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT comp FROM cad_leases
        WHERE drawing_id = $1 AND comp = ANY($2) AND user_id <> $3 AND expires_at >= now()
        """,
        [dump(drawing_id), comps, dump(user_id)]
      )

    List.flatten(rows)
  end

  defp broadcast(drawing_id, event, payload),
    do: CADCraftServer.Design.Events.broadcast(drawing_id, event, payload)

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end
