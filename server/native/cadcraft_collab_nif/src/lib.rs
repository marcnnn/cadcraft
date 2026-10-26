//! The server's bridge to `cadcraft-collab`: JSON in, JSON out, run on a dirty CPU scheduler so
//! a large drawing never blocks the BEAM's normal schedulers.

#[rustler::nif(schedule = "DirtyCpu")]
fn snapshot(parts: String, tol: f64) -> Result<String, String> {
    cadcraft_collab::snapshot_json(&parts, tol)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn check(before: String, after: String) -> Result<String, String> {
    cadcraft_collab::check_json(&before, &after)
}

rustler::init!("Elixir.CADCraftServer.Collab");
