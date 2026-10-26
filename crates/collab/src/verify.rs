//! The server's check of a commit: the solved geometry a client sends must still meet the
//! drawing's constraints, Fixes must not have moved, and the server needs to know which
//! components the commit touched so it can check the committer's leases.
//!
//! The server never solves; it only measures. Solving is the client's job (CADCraft), the
//! store keeps the result.

use std::collections::BTreeSet;
use std::sync::Arc;

use serde::Serialize;

use cadcraft_doc::{Drawing, Handle};

use crate::comps;

/// What [`check`] found.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Verdict {
    /// The commit may be stored.
    pub ok: bool,
    /// Constraints (by id) that do not hold in `after`.
    pub unsatisfied: Vec<u32>,
    /// Constraints (by id) that cannot be interpreted in `after` (a reference to a deleted
    /// entity, a bad expression). Reported, but they do not reject the commit: CADCraft keeps
    /// such constraints too and shows them as invalid.
    pub uninterpretable: Vec<u32>,
    /// A Fix that existed before holds something that moved.
    pub fixed_moved: bool,
    /// Entities added, removed or changed (hex handles).
    pub touched: Vec<String>,
    /// Keys of the components the touched entities belonged to before or belong to after: the
    /// leases the committer must hold. Merged and split components show up under both keys.
    pub components: Vec<String>,
}

/// Check a commit that turns `before` into `after`.
pub fn check(before: &Drawing, after: &Drawing) -> Verdict {
    let touched = touched(before, after);
    let (old, new) = (comps::components(before), comps::components(after));
    let components: BTreeSet<Handle> = touched.iter().flat_map(|h| [old.get(h), new.get(h)]).flatten().copied().collect();

    let unsatisfied = cadcraft_constraints::unsatisfied(after);
    let uninterpretable = cadcraft_constraints::residuals(after).into_iter().filter(|(_, r)| r.is_none()).map(|(id, _)| id).collect();

    let mut restored = after.clone();
    let fixed_moved = cadcraft_constraints::restore_fixed(&mut restored, before);

    Verdict {
        ok: unsatisfied.is_empty() && !fixed_moved,
        unsatisfied,
        uninterpretable,
        fixed_moved,
        touched: touched.iter().map(|h| h.hex()).collect(),
        components: components.iter().map(|h| h.hex()).collect(),
    }
}

/// Entities whose content differs between the two drawings, in handle order.
fn touched(before: &Drawing, after: &Drawing) -> BTreeSet<Handle> {
    let mut out = BTreeSet::new();
    for e in after.model.iter() {
        match before.model.get(e.handle) {
            Some(b) if Arc::ptr_eq(b, e) || b == e => {}
            _ => {
                out.insert(e.handle);
            }
        }
    }
    for e in before.model.iter() {
        if !after.model.contains(e.handle) {
            out.insert(e.handle);
        }
    }
    out
}
