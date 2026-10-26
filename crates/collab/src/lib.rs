//! CADCraft collaboration bridge: what a drawing looks like as rows of a shared PostGIS store.
//!
//! The parametric recipe (constraints, parameters) lives in CADCraft; the database stores the
//! solved result. Each model-space entity becomes one row ([`rows`]) with two geometries
//! ([`wkt`]): the exact one (lines, arcs and bulge polylines as PostGIS curves) and a flattened
//! one for spatial queries and vector tiles. Constrained entities carry the key of their
//! constraint component ([`comps`]), the unit a collaborator leases while editing. Before a commit
//! is accepted, [`verify`] checks that the solved geometry still meets every constraint and that
//! no Fix moved.
//!
//! The crate is plain data in, plain data out: no database driver, no network. The Elixir server
//! calls it through a NIF; the CLI example prints the rows as JSON.

#![deny(clippy::unwrap_used, clippy::expect_used, clippy::panic, clippy::unimplemented, clippy::todo, clippy::unreachable)]

pub mod comps;
pub mod parts;
pub mod rows;
pub mod verify;
pub mod wkt;

pub use comps::components;
pub use parts::{Parts, check_json, snapshot_json};
pub use rows::{ConstraintRow, EntityRow, ParameterRow, Snapshot, snapshot};
pub use verify::{Verdict, check};

#[cfg(test)]
mod tests;
