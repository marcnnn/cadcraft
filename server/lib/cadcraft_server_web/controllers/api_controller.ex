defmodule CADCraftServerWeb.ApiController do
  @moduledoc """
  A thin JSON API over the Ash actions. Every call runs with the request's actor, so the
  resource policies decide; this module only maps HTTP to actions and results to JSON.
  """
  use CADCraftServerWeb, :controller

  alias CADCraftServer.Accounts.User
  alias CADCraftServer.Design.{Drawing, Entity, Lease, Membership, Project, ShareLink}

  action_fallback CADCraftServerWeb.FallbackController

  def register(conn, %{"email" => email, "token" => token}) do
    with {:ok, user} <- Ash.create(User, %{email: email, token: token}, action: :register) do
      json(conn, %{id: user.id, email: to_string(user.email)})
    end
  end

  def create_project(conn, %{"name" => name}) do
    with {:ok, p} <- Ash.create(Project, %{name: name}, actor: actor(conn)) do
      json(conn, %{id: p.id, name: p.name})
    end
  end

  def add_member(conn, %{"project_id" => project_id, "user_id" => user_id, "role" => role}) do
    with {:ok, m} <-
           Ash.create(Membership, %{project_id: project_id, user_id: user_id, role: role},
             action: :invite,
             actor: actor(conn)
           ) do
      json(conn, %{id: m.id, role: m.role})
    end
  end

  def create_share_link(conn, %{"project_id" => project_id} = params) do
    attrs = %{
      project_id: project_id,
      hidden_layers: params["hidden_layers"] || [],
      expires_at: params["expires_at"]
    }

    with {:ok, link} <- Ash.create(ShareLink, attrs, actor: actor(conn)) do
      json(conn, %{id: link.id, token: link.token, expires_at: link.expires_at})
    end
  end

  def create_drawing(conn, %{"project_id" => project_id} = params) do
    attrs =
      params
      |> Map.take(~w(name srid origin_x origin_y rotation unit_scale tolerance))
      |> Map.put("project_id", project_id)

    with {:ok, d} <- Ash.create(Drawing, attrs, actor: actor(conn)) do
      json(conn, drawing_json(d))
    end
  end

  def show_drawing(conn, %{"id" => id}) do
    with {:ok, d} <- Ash.get(Drawing, id, actor: actor(conn)) do
      json(conn, drawing_json(d))
    end
  end

  def commit(conn, %{"id" => id} = params) do
    args = %{
      drawing_id: id,
      base_revision: params["base_revision"],
      upserts: params["upserts"] || [],
      deletes: params["deletes"] || [],
      constraints: params["constraints"],
      parameters: params["parameters"]
    }

    with {:ok, result} <-
           Drawing
           |> Ash.ActionInput.for_action(:commit, args, actor: actor(conn))
           |> Ash.run_action() do
      json(conn, result)
    end
  end

  # Entities in a box of drawing coordinates: `?bbox=min_x,min_y,max_x,max_y`.
  def entities(conn, %{"id" => id, "bbox" => bbox}) do
    with [min_x, min_y, max_x, max_y] <- parse_bbox(bbox),
         {:ok, entities} <-
           Entity
           |> Ash.Query.for_read(
             :in_view,
             %{drawing_id: id, min_x: min_x, min_y: min_y, max_x: max_x, max_y: max_y},
             actor: actor(conn)
           )
           |> Ash.read() do
      json(
        conn,
        Enum.map(entities, &Map.take(&1, [:handle, :kind, :layer, :comp, :data, :revision]))
      )
    else
      {:error, _} = e -> e
      _ -> {:error, :bad_request}
    end
  end

  def acquire_lease(conn, %{"id" => id, "comp" => comp} = params) do
    args = %{drawing_id: id, comp: comp, duration_ms: params["duration_ms"] || 5_000}

    with {:ok, result} <-
           Lease
           |> Ash.ActionInput.for_action(:acquire, args, actor: actor(conn))
           |> Ash.run_action() do
      json(conn, result)
    end
  end

  def release_lease(conn, %{"id" => id, "comp" => comp}) do
    with {:ok, result} <-
           Lease
           |> Ash.ActionInput.for_action(:release, %{drawing_id: id, comp: comp},
             actor: actor(conn)
           )
           |> Ash.run_action() do
      json(conn, result)
    end
  end

  defp actor(conn), do: Ash.PlugHelpers.get_actor(conn)

  defp drawing_json(d),
    do:
      Map.take(d, [
        :id,
        :project_id,
        :name,
        :revision,
        :srid,
        :origin_x,
        :origin_y,
        :rotation,
        :unit_scale,
        :tolerance
      ])

  defp parse_bbox(bbox) do
    bbox
    |> String.split(",")
    |> Enum.map(&Float.parse/1)
    |> Enum.map(fn
      {f, ""} -> f
      _ -> nil
    end)
    |> then(fn l -> if Enum.any?(l, &is_nil/1), do: :error, else: l end)
  end
end
