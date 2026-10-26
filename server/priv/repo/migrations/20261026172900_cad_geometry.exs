defmodule CADCraftServer.Repo.Migrations.CadGeometry do
  @moduledoc """
  The PostGIS side of `cad_entities`, which Ash does not manage:

    * `exact` - the entity's geometry with curves kept (CIRCULARSTRING, COMPOUNDCURVE), in
      drawing coordinates (SRID 0)
    * `flat` - the same, flattened to lines within the drawing's tolerance, SRID 0: viewport
      queries, snapping, picking
    * `tile_geom` - `flat` placed on the map by the drawing's georeference, in Web Mercator:
      vector tiles. A trigger keeps it current when an entity or the georeference changes.
    * `tags` - the vector tile feature properties (kind, layer, component), set by the trigger
  """
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS postgis")

    alter table(:cad_entities) do
      add :exact, :geometry
      add :flat, :geometry
      add :tile_geom, :"geometry(Geometry, 3857)"
      add :tags, :jsonb
    end

    execute("CREATE INDEX cad_entities_flat_gist ON cad_entities USING GIST (flat)")
    execute("CREATE INDEX cad_entities_tile_gist ON cad_entities USING GIST (tile_geom)")

    execute("""
    CREATE FUNCTION cad_georef(g geometry, srid bigint, ox float8, oy float8, rot float8, s float8)
    RETURNS geometry LANGUAGE sql STABLE PARALLEL SAFE AS $$
      SELECT ST_Transform(
        ST_SetSRID(ST_Translate(ST_Scale(ST_Rotate(ST_SetSRID(g, 0), radians(rot)), s, s), ox, oy), srid::int),
        3857)
    $$
    """)

    execute("""
    CREATE FUNCTION cad_entities_place() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE d cad_drawings%ROWTYPE;
    BEGIN
      NEW.tags := jsonb_build_object('kind', NEW.kind, 'layer', NEW.layer, 'comp', NEW.comp);
      IF NEW.flat IS NULL THEN
        NEW.tile_geom := NULL;
      ELSE
        SELECT * INTO d FROM cad_drawings WHERE id = NEW.drawing_id;
        NEW.tile_geom := cad_georef(NEW.flat, d.srid, d.origin_x, d.origin_y, d.rotation, d.unit_scale);
      END IF;
      RETURN NEW;
    END $$
    """)

    execute("""
    CREATE TRIGGER cad_entities_place BEFORE INSERT OR UPDATE ON cad_entities
      FOR EACH ROW EXECUTE FUNCTION cad_entities_place()
    """)

    execute("""
    CREATE FUNCTION cad_drawings_replace() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      UPDATE cad_entities
        SET tile_geom = cad_georef(flat, NEW.srid, NEW.origin_x, NEW.origin_y, NEW.rotation, NEW.unit_scale)
        WHERE drawing_id = NEW.id AND flat IS NOT NULL;
      RETURN NEW;
    END $$
    """)

    execute("""
    CREATE TRIGGER cad_drawings_replace
      AFTER UPDATE OF srid, origin_x, origin_y, rotation, unit_scale ON cad_drawings
      FOR EACH ROW EXECUTE FUNCTION cad_drawings_replace()
    """)
  end

  def down do
    execute("DROP TRIGGER cad_drawings_replace ON cad_drawings")
    execute("DROP FUNCTION cad_drawings_replace()")
    execute("DROP TRIGGER cad_entities_place ON cad_entities")
    execute("DROP FUNCTION cad_entities_place()")
    execute("DROP FUNCTION cad_georef(geometry, bigint, float8, float8, float8, float8)")

    alter table(:cad_entities) do
      remove :tags
      remove :tile_geom
      remove :flat
      remove :exact
    end
  end
end
