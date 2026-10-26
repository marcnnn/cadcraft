//! Constraint components: groups of entities tied together by constraints.
//!
//! A change inside one component can move every entity in it and nothing outside it, so the
//! component is what a collaborator leases while dragging a grip or editing a dimension. Its key
//! is the smallest handle in it: stable across saves and reloads (no database sequence), and it
//! changes only when constraints join or split components, which a commit has to report anyway.

use std::collections::BTreeMap;

use cadcraft_doc::{Drawing, Handle};

/// Each constrained entity's component key (the smallest handle in its component).
/// Unconstrained entities are absent.
pub fn components(d: &Drawing) -> BTreeMap<Handle, Handle> {
    let mut parent: BTreeMap<Handle, Handle> = BTreeMap::new();
    for c in &d.constraints {
        let mut refs = c.refs.iter().map(|r| r.handle);
        let Some(first) = refs.next() else { continue };
        parent.entry(first).or_insert(first);
        for h in refs {
            parent.entry(h).or_insert(h);
            union(&mut parent, first, h);
        }
    }
    let handles: Vec<Handle> = parent.keys().copied().collect();
    handles.into_iter().map(|h| (h, root(&mut parent, h))).collect()
}

/// The root of `h`, halving paths on the way. Roots are always the smallest handle of their
/// set, so the root is the component key.
fn root(parent: &mut BTreeMap<Handle, Handle>, mut h: Handle) -> Handle {
    // Each step moves to a strictly smaller handle, so the walk ends; the bound only guards
    // against a corrupted map.
    for _ in 0..parent.len() {
        let p = parent.get(&h).copied().unwrap_or(h);
        if p == h {
            return h;
        }
        let gp = parent.get(&p).copied().unwrap_or(p);
        parent.insert(h, gp);
        h = gp;
    }
    h
}

fn union(parent: &mut BTreeMap<Handle, Handle>, a: Handle, b: Handle) {
    let (ra, rb) = (root(parent, a), root(parent, b));
    if ra != rb {
        let (lo, hi) = if ra < rb { (ra, rb) } else { (rb, ra) };
        parent.insert(hi, lo);
    }
}
