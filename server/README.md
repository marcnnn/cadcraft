# CADCraft collaboration server

Phoenix + Ash + PostGIS. Projects with roles and share links, drawings whose entities are
committed by CADCraft and checked with CADCraft's own constraint code (a Rustler NIF over
`crates/collab`), live updates over a Phoenix channel, and vector tiles through `geo_sql`.

The plan, the data model, the API and what is still missing: [`docs/collab-postgis.md`](../docs/collab-postgis.md).

```sh
podman run -d --name cadcraft-postgis -e POSTGRES_PASSWORD=postgres -p 55432:5432 docker.io/imresamu/postgis:17-3.5
export PGPORT=55432
mix setup
mix test
mix phx.server
```

Building needs a Rust toolchain: `mix compile` builds the NIF from `native/cadcraft_collab_nif`.
