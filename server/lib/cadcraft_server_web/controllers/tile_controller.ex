defmodule CADCraftServerWeb.TileController do
  @moduledoc """
  Mapbox vector tiles of a drawing over the configured base layers, made by PostGIS through
  `geo_sql` (`GeoSQL.PostGIS.VectorTiles`).

  The drawing is read through Ash with the request's actor first, so the project policies decide
  who may see it at all; layers a share link hides are left out of the CAD layer. Each layer is
  generated on its own and the encoded layers are concatenated, which is a valid tile.
  """
  use CADCraftServerWeb, :controller
  import Ecto.Query

  alias CADCraftServer.Design.{Drawing, ShareGrant}
  alias GeoSQL.PostGIS.VectorTiles

  def show(conn, %{"drawing_id" => id, "z" => z, "x" => x, "y" => y}) do
    actor = Ash.PlugHelpers.get_actor(conn)

    with {:ok, z, x, y} <- coords(z, x, y),
         {:ok, drawing} <- Ash.get(Drawing, id, actor: actor) do
      tile =
        [cad_layer(drawing, hidden(actor)) | base_layers()]
        |> Enum.map(&(VectorTiles.generate(CADCraftServer.Repo, z, x, y, [&1]) || <<>>))
        |> IO.iodata_to_binary()

      conn
      |> put_resp_content_type("application/vnd.mapbox-vector-tile")
      # Tiles change with every commit; clients refetch on the channel's `committed` event.
      |> put_resp_header("cache-control", "private, max-age=0, must-revalidate")
      |> put_resp_header("etag", ~s("#{drawing.id}-#{drawing.revision}-#{z}-#{x}-#{y}"))
      |> send_resp(200, tile)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp cad_layer(drawing, hidden) do
    %VectorTiles.Layer{
      name: "cad",
      source: "cad_entities",
      srid: 3857,
      columns: %{geometry: :tile_geom, id: :handle, tags: :tags},
      compose_query_fn: fn q ->
        from(g in q,
          where: g.drawing_id == type(^drawing.id, Ecto.UUID) and g.layer not in ^hidden
        )
      end
    }
  end

  defp base_layers do
    for l <- Application.get_env(:cadcraft_server, :base_layers, []) do
      struct!(VectorTiles.Layer, Map.put_new(l, :srid, 3857))
    end
  end

  defp hidden(%ShareGrant{hidden_layers: layers}), do: layers
  defp hidden(_), do: []

  defp coords(z, x, y) do
    with {z, ""} <- Integer.parse(z),
         {x, ""} <- Integer.parse(x),
         {y, ext} when ext in ["", ".mvt", ".pbf"] <- Integer.parse(y),
         true <-
           z in 0..24 and x in 0..(Integer.pow(2, z) - 1) and y in 0..(Integer.pow(2, z) - 1) do
      {:ok, z, x, y}
    else
      _ -> :error
    end
  end
end
