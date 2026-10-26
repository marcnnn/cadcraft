# Collaborative design on PostgreSQL + PostGIS

Status: working prototype on branch `collab-postgis` (not upstream). Based on CADCraft `main` at
`d3ae8a6` (2026-10-26).

Several people edit one drawing, parametric parts included. The shared copy lives in PostGIS,
an Elixir/Ash server guards it, and the same data comes out as vector tiles over
OpenStreetMap for anyone with a browser.

## The one rule

**CADCraft solves; the database stores the result.**

The parametric recipe (constraints, parameters, expressions) belongs to CADCraft. When a user
drags a grip or changes `width`, CADCraft's solver runs locally at interactive speed and
produces plain geometry. That geometry is what gets committed, indexed and rendered. The server
never solves. It *checks* the result with CADCraft's own code (a Rust NIF), so a client cannot
store geometry that breaks its constraints.

It follows that:

- Tiles, viewport queries and snapping read ordinary PostGIS geometry. They know nothing about
  constraints.
- Under-constrained geometry is no problem. It has concrete coordinates like anything else (the
  solver moves things as little as possible), so it renders like anything else. Fully
  constrained is not a precondition for being shown.
- The recipe is still stored (constraint and parameter rows), so the next person who opens the
  drawing in CADCraft can keep editing parametrically.

## What is in the branch

| Path | What |
|---|---|
| `crates/collab` | `cadcraft-collab`: drawing → rows (exact and flattened WKT, component keys), commit check, JSON entry points. 8 tests. |
| `crates/constraints` | One addition: `unsatisfied(d)`, the ids `all_satisfied` would complain about, using the solver's own tolerance. |
| `server/` | Phoenix + Ash server: projects, roles, share links, drawings, commits, leases, channel, vector tiles. 7 end-to-end tests against PostGIS. |
| `server/native/cadcraft_collab_nif` | Rustler NIF wrapping `cadcraft-collab` (dirty CPU scheduler). |
| `crates/collab/examples/snapshot.rs` | `cargo run -p cadcraft-collab --example snapshot -- file.dxf` prints a drawing's rows as JSON. |

## Architecture

```
 CADCraft (desktop / wasm)                 Elixir server (Phoenix + Ash)                PostgreSQL + PostGIS
 ─────────────────────────                 ─────────────────────────────                ────────────────────
 edit, solve locally (LM solver)
 commit {base_revision, upserts,  ──HTTP/channel──>  Drawing.commit (policy: editor)
         deletes, constraints?}                      1 lock drawing, check revision ──>  SELECT ... FOR UPDATE
                                                     2 load stored parts            ──>  cad_entities.data, ...
                                                     3 NIF check(before, after)
                                                       (constraints hold? Fix moved?)
                                                     4 leases on touched components ──>  cad_leases
                                                     5 NIF snapshot(after) → rows   ──>  upsert exact/flat geometry
                                                                                         trigger: tile_geom (3857), tags
 <── "committed" {revision, touched} ── PubSub "drawing:<id>"
 pull touched handles

 MapLibre / OpenLayers / CADCraft web
 GET /tiles/:drawing/:z/:x/:y.mvt  ──>  Ash.get(Drawing, actor)  ──>  geo_sql VectorTiles  ──>  ST_AsMVT(tile_geom)
                                                                       + optional OSM layers     + planet_osm_* tables
```

## Data model

All tables are Ash resources (`server/lib/cadcraft_server/design/*.ex`); the geometry columns
are added by a hand-written migration (`priv/repo/migrations/*_cad_geometry.exs`).

| Table | Key | Holds |
|---|---|---|
| `users` | id | email, SHA-256 of the API token |
| `projects` | id | name |
| `memberships` | id; unique (project, user) | role: `owner`, `editor`, `commenter`, `viewer` |
| `share_links` | id; unique token | project, `hidden_layers`, `expires_at` |
| `cad_drawings` | id | project, `revision`, georeference (`srid`, `origin_x/y`, `rotation`, `unit_scale`), chord `tolerance` |
| `cad_entities` | (drawing, handle) | `kind`, `layer`, `comp`, `data` (CADCraft JSON, the source of truth), `revision`, `exact`, `flat`, `tile_geom`, `tags` |
| `cad_constraints` | (drawing, cid) | `comp`, `data` (CADCraft JSON) |
| `cad_parameters` | (drawing, name) | `expr`, `description` |
| `cad_leases` | (drawing, comp) | user, `expires_at` |
| `cad_revisions` | (drawing, number) | author, touched handles |

The three geometry columns:

- `exact` (SRID 0, drawing coordinates): lines, arcs, circles and bulge polylines as PostGIS
  curves (`CIRCULARSTRING`, `COMPOUNDCURVE`). Nothing lost.
- `flat` (SRID 0): everything flattened to points, lines or polygons within the drawing's
  tolerance, using CADCraft's own tessellation. Viewport queries (`&&`), picking, snapping.
  Text, blocks and dimensions currently contribute their insertion point only.
- `tile_geom` (SRID 3857): `flat` scaled, rotated and moved by the drawing's georeference,
  then reprojected. A trigger keeps it current when an entity or the georeference changes.

`data` is what CADCraft reads back. Geometry columns are derived from it on every write, by the
server, never sent by the client.

### Constraint components and their keys

Constraints split a drawing into connected components; an edit inside one can move anything in
it and nothing outside it. The component is the unit of a lease. Its key is **the smallest
handle in it** (hex), computed by `cadcraft_collab::components`. Unlike a database sequence it
is the same after a reload, on any machine. It changes only when constraints merge or split
components, and the commit check reports both old and new keys then.

## Commit protocol

A client sends the revision it solved against, the entities it added or changed (CADCraft
JSON), the handles it deleted, and the full constraint and parameter lists if they changed.
`CADCraftServer.Design.Commit` then, in one transaction:

1. Locks the drawing; refuses with `stale` when the revision moved on. The client pulls,
   re-solves, retries.
2. Rebuilds the drawing before and after from stored rows plus the request.
3. Runs `cadcraft_collab::check`: every interpretable constraint must hold within the solver's
   tolerance, and no pre-existing Fix may have moved (`constraints::restore_fixed`). Refuses
   with `constraints not met: {"unsatisfied": [...], "fixedMoved": ...}`.
4. Refuses when another user holds a live lease on a touched component.
5. Writes touched entities and those whose component key changed, deletes removed ones,
   replaces constraints and parameters when sent, bumps the revision, logs a revision row.
6. Broadcasts `committed` with the touched and deleted handles on `drawing:<id>`.

Leases are coordination, not correctness: step 1 already serializes commits, step 3 keeps them
valid. A lease shows everyone who is working where, and keeps two people from fighting over
the same component.

Unconstrained entities need no lease.

## Authorization (Ash policies)

| Who | Can |
|---|---|
| owner | everything; members; share links; delete |
| editor | create drawings, commit, lease, change georeference |
| commenter, viewer | read drawings, entities, constraints, parameters, revisions, tiles |
| share link | read the project's drawings and entities except `hidden_layers`; never constraints or parameters; nothing else |
| anyone else | nothing; the API answers every refusal with 404, so strangers learn nothing about what exists |

Policies live on the resources, so the JSON API, the channel and the tile endpoint all ask
the same rules. One caveat: tiles are built by `geo_sql` with Ecto, not by an Ash read. The
endpoint first reads the drawing through Ash (that is the access decision) and then applies a
share link's hidden layers in the tile query itself. A later step can build the tile source
from Ash's authorized query instead.

## Vector tiles

`GET /tiles/:drawing_id/:z/:x/:y.mvt` uses `GeoSQL.PostGIS.VectorTiles` (Aaron Seigo's
[`geo_sql`](https://hex.pm/packages/geo_sql)). The `cad` layer carries each entity with its
handle and `tags` (kind, layer, component), so a web viewer can style by layer, highlight a
leased component, and use the handle to fetch exact geometry when it needs to snap.

Base map layers come from configuration (`config :cadcraft_server, :base_layers`): any table in
the same database with a 3857 geometry column, an id and a jsonb tags column, for example from
`osm2pgsql` with a flex style that writes tags as jsonb.

## What changed on main since the first plan

The first plan was written against `e707ab4` (2026-10-14). `main` is now at `d3ae8a6`, 343
commits later. Most of it is UI (egui 0.37, docking side panels, Arabic, Korean, Swedish),
DXF/PDF fixes and refactors. What matters here:

1. **Fix no longer stores a position** (#1139, #2077). A Fix locks parameters at the values
   they had *before* the edit, via `restore_fixed(d, before)`; a Fix on a derived point
   (midpoint, arc end) holds where it was. `SolveOptions` gained `hold` and `anchors`.
   Consequence: checking a commit needs the drawing before the edit, not only after. The
   server has it (stored rows), and `check()` uses `restore_fixed` to catch moved Fixes.
2. **The solver's work is bounded** (#1850, #1851, #1959): caps on constraints, rigid members,
   residual evaluation and expression depth. That is what makes it reasonable to run CADCraft's
   constraint code inside a server on input from the network. The NIF also runs on a dirty
   scheduler so a big drawing never blocks the BEAM.
3. **Renaming a parameter rewrites every expression** (#1142). The first plan's recursive SQL
   over parameter names (regex matching on expressions) is gone: the server does not evaluate
   expressions at all. Parameters are rows, replaced whole when a commit sends them.
4. **Ellipse solutions are checked on their stored form** (#2082). Good for us: the server
   checks exactly what is stored.
5. Components are still private in the solver, so `cadcraft-collab` computes them itself and
   keys them by smallest handle instead of the `BIGSERIAL` the first plan proposed.

## Corrections to the first plan

Found while building it:

- `geo_sql` layers take exactly `geometry`, `id` and `tags` columns, and filter with
  `compose_query_fn`. The first sketch put `where: "drawing_id = '#{id}'"` into a string, which
  would have been SQL injection. It also unions all layers into one `ST_AsMVT` call; the server
  generates each layer on its own and concatenates them, which is a valid tile.
- SRID 0 cannot be reprojected, so tiles need a georeference per drawing. Added.
- MVT encoding needs linear geometry, and Elixir's `geo` cannot decode PostGIS curves. Hence
  `exact` (curves) and `flat` (lines), and geometry columns outside Ash attributes.
- PostGIS refuses a `COMPOUNDCURVE` whose parts do not meet exactly; arc ends recomputed from
  centres are off by 1e-15. The writer uses the polyline vertices themselves.
- A 60 m drawing is smaller than a pixel at zoom 0, so it vanishes from low-zoom tiles. Expected
  for maps; a viewer should zoom to the drawing's extent.
- "Ash policies compile into the tile SQL" was too strong; see the caveat above.

## Running it

Needs Rust, Elixir 1.18 / OTP 27, and PostGIS 3.5 (on ARM use the `imresamu/postgis` image).

```sh
podman run -d --name cadcraft-postgis -e POSTGRES_PASSWORD=postgres -p 55432:5432 docker.io/imresamu/postgis:17-3.5

cargo test -p cadcraft-collab

cd server
export PGPORT=55432
mix setup        # deps, database, migrations
mix test         # 7 end-to-end tests
mix phx.server   # http://localhost:4000
```

Try it with curl:

```sh
curl -s localhost:4000/api/users -H 'content-type: application/json' -d '{"email":"me@example.com","token":"secret"}'
AUTH='authorization: Bearer secret'
P=$(curl -s localhost:4000/api/projects -H "$AUTH" -H 'content-type: application/json' -d '{"name":"Riverside"}' | jq -r .id)
D=$(curl -s localhost:4000/api/projects/$P/drawings -H "$AUTH" -H 'content-type: application/json' \
      -d '{"name":"Site","srid":25832,"origin_x":691000,"origin_y":5336000}' | jq -r .id)
```

Import an existing DXF as the first commit:

```sh
cargo run -q -p cadcraft-collab --example snapshot -- plan.dxf > rows.json
# rows.json's entities[].data, constraints[].data and parameters are the commit's
# upserts, constraints and parameters:
jq '{base_revision: 0, upserts: [.entities[].data], constraints: [.constraints[].data], parameters: .parameters}' rows.json \
  | curl -s localhost:4000/api/drawings/$D/commit -H "$AUTH" -H 'content-type: application/json' -d @-
```

### API

| Method | Path | |
|---|---|---|
| POST | `/api/users` | `{email, token}`; open registration for trying it out |
| POST | `/api/projects` | `{name}`; caller becomes owner |
| POST | `/api/projects/:id/members` | `{user_id, role}`; owner |
| POST | `/api/projects/:id/share_links` | `{hidden_layers?, expires_at?}` → `{token}`; owner |
| POST | `/api/projects/:id/drawings` | `{name, srid?, origin_x?, origin_y?, rotation?, unit_scale?, tolerance?}` |
| GET | `/api/drawings/:id` | drawing with its revision |
| GET | `/api/drawings/:id/entities?bbox=x0,y0,x1,y1` | entities in a box of drawing coordinates |
| POST | `/api/drawings/:id/commit` | `{base_revision, upserts, deletes, constraints?, parameters?}` |
| POST / DELETE | `/api/drawings/:id/leases/:comp` | take or renew (`duration_ms`, max 60 s) / release |
| GET | `/tiles/:drawing_id/:z/:x/:y.mvt` | vector tile |
| WS | `/socket?token=…` or `?share=…`, topic `drawing:<id>` | events `committed`, `lease`, `lease_released`, `cursor`; push `cursor`, `lease:acquire`, `lease:release`, `commit` |

Auth: `Authorization: Bearer <token>` for users, `?share=<token>` or `X-Share-Token` for share
links.

## Next steps

1. **The CADCraft side.** A sync module in `crates/engine`: open a drawing from the server,
   subscribe to `drawing:<id>`, take a lease when a grip drag or dimension edit starts in a
   constrained component, commit after the solve, apply `committed` events by pulling touched
   handles. Everything is a command, so: `COLLABOPEN`, `COLLABCOMMIT`, and the rest.
2. Real accounts: replace the token resource with `ash_authentication`.
3. Check only the touched components instead of loading the whole drawing.
4. Blocks, text and dimensions in tiles (today they are insertion points): expand them with
   CADCraft's renderer into `flat`.
5. Paper space and layouts (today model space only).
6. `dof` per component as a tile tag, so a viewer can show what is still free.
7. Presence (Phoenix.Presence) for who is in the drawing; review comments for commenters.
8. Tile caching keyed by drawing revision; history and undo from `cad_revisions`.
