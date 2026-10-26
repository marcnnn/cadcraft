//! Entity geometry as (E)WKT text PostGIS reads with `ST_GeomFromText`.
//!
//! [`exact`] keeps arcs as arcs (`CIRCULARSTRING`, `COMPOUNDCURVE`), so nothing is lost when a
//! drawing is read back from the store. [`flat`] is a line approximation within a chord
//! tolerance: vector tiles and most spatial functions only take linear geometry.

use std::fmt::Write;

use cadcraft_doc::{EntityKind, Prim};
use cadcraft_geom::{Polyline, Segment, Vec2};

/// Most points one flattened entity may have; a bigger one (a hostile spline, a tolerance of
/// nearly nothing) has no flat geometry rather than an unbounded one.
pub const MAX_POINTS: usize = 200_000;

/// Smallest chord tolerance accepted, relative to nothing: below it the tolerance is raised.
const MIN_TOL: f64 = 1e-9;

/// The entity's exact geometry, for the kinds PostGIS can hold without approximation.
pub fn exact(kind: &EntityKind) -> Option<String> {
    match kind {
        EntityKind::Point(p) => Some(format!("POINT({})", xy(p.p.xy())?)),
        EntityKind::Line(l) => Some(format!("LINESTRING({}, {})", xy(l.a.xy())?, xy(l.b.xy())?)),
        EntityKind::Circle(c) => {
            let (a, b) = (c.center.xy() + Vec2::new(c.radius, 0.0), c.center.xy() - Vec2::new(c.radius, 0.0));
            Some(format!("CIRCULARSTRING({}, {}, {})", xy(a)?, xy(b)?, xy(a)?))
        }
        EntityKind::Arc(a) => {
            let arc = cadcraft_geom::Arc::new(a.center.xy(), a.radius, a.start, a.end);
            Some(format!("CIRCULARSTRING({}, {}, {})", xy(arc.start_point())?, xy(arc.mid_point())?, xy(arc.end_point())?))
        }
        EntityKind::LwPolyline(p) => compound(&Polyline { vertices: p.vertices.clone(), closed: p.closed }),
        _ => None,
    }
}

/// A polyline as one `COMPOUNDCURVE`, or a plain `LINESTRING` when it has no arcs.
///
/// Segment ends are the vertices themselves, not points recomputed from arc centres: PostGIS
/// rejects a compound curve whose parts do not meet exactly.
fn compound(pl: &Polyline) -> Option<String> {
    let segs = pl.segments();
    let n = pl.vertices.len();
    let ends: Vec<(Vec2, Vec2)> = (0..segs.len()).filter_map(|i| Some((pl.vertices.get(i)?.p, pl.vertices.get((i + 1) % n)?.p))).collect();
    let (first, _) = *ends.first()?;
    if segs.iter().all(|s| matches!(s, Segment::Line(_))) {
        let mut out = format!("LINESTRING({}", xy(first)?);
        for (_, b) in &ends {
            write!(out, ", {}", xy(*b)?).ok()?;
        }
        out.push(')');
        return Some(out);
    }
    let parts: Option<Vec<String>> = segs
        .iter()
        .zip(&ends)
        .map(|(s, &(a, b))| match s {
            Segment::Line(_) => Some(format!("({}, {})", xy(a)?, xy(b)?)),
            Segment::Arc { .. } => Some(format!("CIRCULARSTRING({}, {}, {})", xy(a)?, xy(s.mid())?, xy(b)?)),
        })
        .collect();
    Some(format!("COMPOUNDCURVE({})", parts?.join(", ")))
}

/// The entity's geometry flattened to points, lines or polygons within `tol` (drawing units).
///
/// Fills win over outlines and outlines over points, so the result is a single geometry type
/// (vector tile features cannot be collections). Text, blocks and dimensions have only their
/// insertion point here; their drawn geometry is the renderer's.
pub fn flat(kind: &EntityKind, tol: f64) -> Option<String> {
    let tol = if tol.is_finite() && tol > MIN_TOL { tol } else { MIN_TOL.max(1e-3) };
    let mut lines: Vec<Vec<Vec2>> = Vec::new();
    let mut points = Vec::new();
    let mut fills = Vec::new();
    let mut budget = MAX_POINTS;
    for prim in kind.prims() {
        let mut pts = Vec::new();
        match prim {
            Prim::Point(p) => {
                points.push(p);
                continue;
            }
            Prim::Fill(poly) => {
                budget = budget.checked_sub(poly.len())?;
                fills.push(poly);
                continue;
            }
            Prim::Infinite { .. } => continue,
            Prim::Seg(s) => s.tessellate(tol, &mut pts),
            Prim::Circle(c) => {
                c.tessellate(tol, &mut pts);
                close(&mut pts);
            }
            Prim::Ellipse(e) => e.tessellate(tol, &mut pts),
            Prim::Spline(s) => pts = s.tessellate(tol),
        }
        budget = budget.checked_sub(pts.len())?;
        // Consecutive segments of one outline join into one line.
        match lines.last_mut() {
            Some(last) if last.last().zip(pts.first()).is_some_and(|(a, b)| (*a - *b).len() <= tol) => {
                last.extend(pts.into_iter().skip(1));
            }
            _ => lines.push(pts),
        }
    }
    lines.retain(|l| l.len() >= 2);
    if !fills.is_empty() {
        let rings: Option<Vec<String>> = fills.iter().map(|f| ring(f)).collect();
        let rings = rings?;
        return match rings.as_slice() {
            [one] => Some(format!("POLYGON({one})")),
            _ => Some(format!("MULTIPOLYGON({})", rings.iter().map(|r| format!("({r})")).collect::<Vec<_>>().join(", "))),
        };
    }
    if !lines.is_empty() {
        let parts: Option<Vec<String>> = lines.iter().map(|l| path(l)).collect();
        let parts = parts?;
        return match parts.as_slice() {
            [one] => Some(format!("LINESTRING{one}")),
            _ => Some(format!("MULTILINESTRING({})", parts.join(", "))),
        };
    }
    match points.as_slice() {
        [] => None,
        [p] => Some(format!("POINT({})", xy(*p)?)),
        _ => {
            let parts: Option<Vec<String>> = points.iter().map(|p| xy(*p).map(|s| format!("({s})"))).collect();
            Some(format!("MULTIPOINT({})", parts?.join(", ")))
        }
    }
}

fn close(pts: &mut Vec<Vec2>) {
    if let (Some(&a), Some(&b)) = (pts.first(), pts.last())
        && a != b
    {
        pts.push(a);
    }
}

/// A closed ring `(x y, …, x y)` for a polygon.
fn ring(poly: &[Vec2]) -> Option<String> {
    let mut pts = poly.to_vec();
    close(&mut pts);
    if pts.len() < 4 {
        return None;
    }
    path(&pts)
}

/// `(x y, x y, …)`.
fn path(pts: &[Vec2]) -> Option<String> {
    let parts: Option<Vec<String>> = pts.iter().map(|p| xy(*p)).collect();
    Some(format!("({})", parts?.join(", ")))
}

/// `x y`, or `None` for a coordinate PostGIS would reject (NaN, infinity).
fn xy(p: Vec2) -> Option<String> {
    (p.x.is_finite() && p.y.is_finite()).then(|| format!("{} {}", p.x, p.y))
}
