defmodule CADCraftServer.Design.Commit do
  @moduledoc """
  Store a solved edit of a drawing.

  CADCraft solved it; the server does not solve, it checks. In one transaction:

    1. Lock the drawing and refuse the commit when its revision moved past `base_revision`
       (someone else committed since the client last synced: pull, re-solve, retry).
    2. Rebuild the drawing before and after the edit from the stored rows and the request.
    3. Run CADCraft's check (`CADCraftServer.Collab.check/2`): every constraint holds, no Fix
       moved. Refuse otherwise.
    4. Refuse when another user holds a live lease on a component the edit touched.
    5. Write the touched entities (and those whose component changed) with their geometry,
       delete removed ones, replace constraints and parameters when sent, bump the revision.

  Then broadcast `committed` on the drawing's topic so other clients pull the touched handles.

  The whole drawing is loaded to check it. That is simple and right; for very large drawings
  the next step is to load only the components the edit touches.
  """
  use Ash.Resource.Actions.Implementation

  alias CADCraftServer.{Collab, Repo}
  alias CADCraftServer.Design.{Events, Lease}

  @impl true
  def run(input, _opts, context) do
    args = input.arguments
    actor = context.actor

    result =
      Repo.transaction(fn ->
        case commit(args, actor) do
          {:ok, done} -> done
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, done} ->
        Events.broadcast(args.drawing_id, "committed", %{
          revision: done.revision,
          touched: done.touched,
          deleted: done.deleted,
          author: actor.id
        })

        {:ok, done}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp commit(args, actor) do
    id = Ecto.UUID.dump!(args.drawing_id)

    with {:ok, revision, tolerance} <- lock(id, args.base_revision),
         before = load(id),
         after_parts = apply_edit(before, args),
         {:ok, verdict} <- check(before.parts, after_parts),
         :ok <- leases(args.drawing_id, verdict["components"], actor.id),
         {:ok, rows} <- snapshot(after_parts, tolerance) do
      next = revision + 1
      deleted = Enum.filter(verdict["touched"], &(not Map.has_key?(rows.entities, &1)))
      write_entities(id, rows.entities, before.comps, MapSet.new(verdict["touched"]), next)
      delete_entities(id, deleted)
      if args[:constraints], do: replace_constraints(id, rows.constraints)
      if args[:parameters], do: replace_parameters(id, after_parts["parameters"])

      Repo.query!("UPDATE cad_drawings SET revision = $2, updated_at = now() WHERE id = $1", [
        id,
        next
      ])

      Repo.query!(
        "INSERT INTO cad_revisions (drawing_id, number, author_id, touched, inserted_at) VALUES ($1, $2, $3, $4, now())",
        [id, next, Ecto.UUID.dump!(actor.id), verdict["touched"]]
      )

      {:ok,
       %{
         revision: next,
         touched: verdict["touched"] -- deleted,
         deleted: deleted,
         components: verdict["components"]
       }}
    end
  end

  defp lock(id, base) do
    case Repo.query!("SELECT revision, tolerance FROM cad_drawings WHERE id = $1 FOR UPDATE", [id]) do
      %{rows: [[^base, tol]]} -> {:ok, base, tol}
      %{rows: [[rev, _]]} -> {:error, "stale: drawing is at revision #{rev}, not #{base}"}
      %{rows: []} -> {:error, "no such drawing"}
    end
  end

  # The stored drawing, as CADCraft parts plus each entity's stored component.
  defp load(id) do
    %{rows: entities} =
      Repo.query!("SELECT handle, comp, data FROM cad_entities WHERE drawing_id = $1", [id])

    %{rows: constraints} =
      Repo.query!("SELECT data FROM cad_constraints WHERE drawing_id = $1 ORDER BY cid", [id])

    %{rows: parameters} =
      Repo.query!(
        "SELECT name, expr, description FROM cad_parameters WHERE drawing_id = $1 ORDER BY name",
        [id]
      )

    %{
      parts: %{
        "entities" => Enum.map(entities, fn [_, _, data] -> data end),
        "constraints" => List.flatten(constraints),
        "parameters" =>
          Enum.map(parameters, fn [n, e, d] -> %{"name" => n, "expr" => e, "description" => d} end)
      },
      comps: Map.new(entities, fn [h, c, _] -> {h, c} end)
    }
  end

  defp apply_edit(%{parts: parts}, args) do
    deletes = MapSet.new(args[:deletes] || [], &String.upcase/1)
    upserts = Map.new(args[:upserts] || [], &{hex(&1["handle"]), &1})

    entities =
      parts["entities"]
      |> Enum.reject(
        &(MapSet.member?(deletes, hex(&1["handle"])) or Map.has_key?(upserts, hex(&1["handle"])))
      )
      |> Kernel.++(Enum.reject(Map.values(upserts), &MapSet.member?(deletes, hex(&1["handle"]))))

    %{
      "entities" => entities,
      "constraints" => args[:constraints] || parts["constraints"],
      "parameters" => args[:parameters] || parts["parameters"]
    }
  end

  defp check(before, after_parts) do
    with {:ok, json} <- Collab.check(Jason.encode!(before), Jason.encode!(after_parts)) do
      verdict = Jason.decode!(json)

      if verdict["ok"],
        do: {:ok, verdict},
        else:
          {:error,
           "constraints not met: " <> Jason.encode!(Map.take(verdict, ~w(unsatisfied fixedMoved)))}
    end
  end

  defp leases(drawing_id, comps, user_id) do
    case Lease.held_by_others(drawing_id, comps, user_id) do
      [] -> :ok
      held -> {:error, "leased by another user: #{Enum.join(held, ", ")}"}
    end
  end

  defp snapshot(parts, tolerance) do
    with {:ok, json} <- Collab.snapshot(Jason.encode!(parts), tolerance) do
      rows = Jason.decode!(json)

      {:ok,
       %{
         entities: Map.new(rows["entities"], &{&1["handle"], &1}),
         constraints: rows["constraints"]
       }}
    end
  end

  # Write the touched entities and every entity whose component key changed (constraints
  # added or removed elsewhere can merge or split components).
  defp write_entities(id, rows, old_comps, touched, revision) do
    rows =
      rows
      |> Map.values()
      |> Enum.filter(
        &(MapSet.member?(touched, &1["handle"]) or old_comps[&1["handle"]] != &1["comp"])
      )

    unless rows == [] do
      cols = fn key -> Enum.map(rows, & &1[key]) end

      Repo.query!(
        """
        INSERT INTO cad_entities (drawing_id, handle, kind, layer, comp, data, revision, exact, flat)
        SELECT $1, h, k, l, c, d, $2, ST_GeomFromText(e, 0), ST_GeomFromText(f, 0)
        FROM unnest($3::text[], $4::text[], $5::text[], $6::text[], $7::jsonb[], $8::text[], $9::text[])
          AS t(h, k, l, c, d, e, f)
        ON CONFLICT (drawing_id, handle) DO UPDATE SET
          kind = EXCLUDED.kind, layer = EXCLUDED.layer, comp = EXCLUDED.comp, data = EXCLUDED.data,
          revision = EXCLUDED.revision, exact = EXCLUDED.exact, flat = EXCLUDED.flat
        """,
        [
          id,
          revision,
          cols.("handle"),
          cols.("kind"),
          cols.("layer"),
          cols.("comp"),
          cols.("data"),
          cols.("exact"),
          cols.("flat")
        ]
      )
    end
  end

  defp delete_entities(_id, []), do: :ok

  defp delete_entities(id, handles),
    do:
      Repo.query!("DELETE FROM cad_entities WHERE drawing_id = $1 AND handle = ANY($2)", [
        id,
        handles
      ])

  defp replace_constraints(id, rows) do
    Repo.query!("DELETE FROM cad_constraints WHERE drawing_id = $1", [id])

    unless rows == [] do
      Repo.query!(
        "INSERT INTO cad_constraints (drawing_id, cid, comp, data) SELECT $1, i, c, d FROM unnest($2::bigint[], $3::text[], $4::jsonb[]) AS t(i, c, d)",
        [
          id,
          Enum.map(rows, & &1["id"]),
          Enum.map(rows, & &1["comp"]),
          Enum.map(rows, & &1["data"])
        ]
      )
    end
  end

  defp replace_parameters(id, params) do
    Repo.query!("DELETE FROM cad_parameters WHERE drawing_id = $1", [id])

    unless params == [] do
      Repo.query!(
        "INSERT INTO cad_parameters (drawing_id, name, expr, description) SELECT $1, n, e, d FROM unnest($2::text[], $3::text[], $4::text[]) AS t(n, e, d)",
        [
          id,
          Enum.map(params, & &1["name"]),
          Enum.map(params, & &1["expr"]),
          Enum.map(params, &(&1["description"] || ""))
        ]
      )
    end
  end

  # CADCraft serializes handles as integers; rows key them by upper-case hex.
  defp hex(h) when is_integer(h), do: Integer.to_string(h, 16)
  defp hex(h) when is_binary(h), do: String.upcase(h)
end
