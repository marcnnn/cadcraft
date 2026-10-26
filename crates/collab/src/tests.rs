use cadcraft_constraints::SolveOptions;
use cadcraft_doc::{
    Arc as DArc, Circle as DCircle, Common, Constraint, ConstraintKind, DistAxis, Drawing, EntityKind, GeomRef, Handle, Line as DLine, LwPolyline,
    Space, Sub,
};
use cadcraft_geom::{PolyVertex, Vec2, Vec3};

use crate::{Parts, check, check_json, components, snapshot, snapshot_json, wkt};

fn v(x: f64, y: f64) -> Vec3 {
    Vec3::new(x, y, 0.0)
}
fn add_e(d: &mut Drawing, k: EntityKind) -> Handle {
    d.add(&Space::Model, Common::default(), k).unwrap()
}
fn line(d: &mut Drawing, a: (f64, f64), b: (f64, f64)) -> Handle {
    add_e(d, EntityKind::Line(DLine { a: v(a.0, a.1), b: v(b.0, b.1) }))
}
fn con(kind: ConstraintKind, refs: &[GeomRef]) -> Constraint {
    Constraint { id: 0, kind, refs: refs.to_vec(), name: String::new(), expr: String::new() }
}
fn constrain(d: &mut Drawing, c: Constraint) -> u32 {
    cadcraft_constraints::add(d, c, &SolveOptions::default()).unwrap()
}
fn move_line(d: &mut Drawing, h: Handle, a: (f64, f64), b: (f64, f64)) {
    d.modify_entity(h, |e| {
        if let EntityKind::Line(l) = &mut e.kind {
            l.a = v(a.0, a.1);
            l.b = v(b.0, b.1);
        }
    })
    .unwrap();
}

#[test]
fn exact_keeps_curves() {
    let line = EntityKind::Line(DLine { a: v(0.0, 0.0), b: v(10.0, 0.5) });
    assert_eq!(wkt::exact(&line).as_deref(), Some("LINESTRING(0 0, 10 0.5)"));
    let circle = EntityKind::Circle(DCircle { center: v(1.0, 2.0), radius: 3.0 });
    assert_eq!(wkt::exact(&circle).as_deref(), Some("CIRCULARSTRING(4 2, -2 2, 4 2)"));
    let arc = EntityKind::Arc(DArc { center: v(0.0, 0.0), radius: 1.0, start: 0.0, end: std::f64::consts::PI });
    let a = wkt::exact(&arc).unwrap();
    assert!(a.starts_with("CIRCULARSTRING(1 0, "), "{a}");
}

#[test]
fn polyline_with_bulge_is_a_compound_curve() {
    let p = LwPolyline {
        vertices: vec![
            PolyVertex::new(Vec2::new(0.0, 0.0)),
            PolyVertex::with_bulge(Vec2::new(10.0, 0.0), 1.0),
            PolyVertex::new(Vec2::new(10.0, 10.0)),
        ],
        closed: false,
        const_width: 0.0,
        elevation: 0.0,
        plinegen: false,
    };
    let w = wkt::exact(&EntityKind::LwPolyline(p.clone())).unwrap();
    assert!(w.starts_with("COMPOUNDCURVE((0 0, 10 0), CIRCULARSTRING(10 0, "), "{w}");
    let straight = LwPolyline { vertices: p.vertices.iter().map(|x| PolyVertex::new(x.p)).collect(), ..p };
    assert_eq!(wkt::exact(&EntityKind::LwPolyline(straight)).as_deref(), Some("LINESTRING(0 0, 10 0, 10 10)"));
}

#[test]
fn flat_closes_circles_and_bounds_hostile_input() {
    let circle = EntityKind::Circle(DCircle { center: v(0.0, 0.0), radius: 5.0 });
    let f = wkt::flat(&circle, 0.01).unwrap();
    assert!(f.starts_with("LINESTRING(5 0, "), "{f}");
    assert!(f.ends_with(", 5 0)"), "{f}");
    // A nonsense tolerance falls back to a sane one instead of looping forever.
    assert!(wkt::flat(&circle, f64::NAN).is_some());
    let nan = EntityKind::Line(DLine { a: v(f64::NAN, 0.0), b: v(1.0, 1.0) });
    assert_eq!(wkt::exact(&nan), None);
    assert_eq!(wkt::flat(&nan, 0.01), None);
}

#[test]
fn components_are_keyed_by_smallest_handle() {
    let mut d = Drawing::default();
    let a = line(&mut d, (0.0, 0.0), (10.0, 0.0));
    let b = line(&mut d, (10.0, 0.0), (10.0, 8.0));
    let c = line(&mut d, (20.0, 0.0), (30.0, 0.0));
    let free = line(&mut d, (50.0, 0.0), (60.0, 0.0));
    constrain(&mut d, con(ConstraintKind::Coincident, &[GeomRef::new(b, Sub::Start), GeomRef::new(a, Sub::End)]));
    constrain(&mut d, con(ConstraintKind::Horizontal, &[GeomRef::whole(c)]));
    let m = components(&d);
    assert_eq!(m.get(&a), Some(&a));
    assert_eq!(m.get(&b), Some(&a));
    assert_eq!(m.get(&c), Some(&c));
    assert_eq!(m.get(&free), None);

    let s = snapshot(&d, 0.01);
    assert_eq!(s.entities.len(), 4);
    assert_eq!(s.entities.iter().find(|e| e.handle == b.hex()).and_then(|e| e.comp.clone()), Some(a.hex()));
    assert_eq!(s.constraints.len(), 2);
}

#[test]
fn check_accepts_a_solved_commit_and_names_its_component() {
    let mut before = Drawing::default();
    let a = line(&mut before, (0.0, 0.0), (10.0, 0.0));
    let b = line(&mut before, (10.0, 0.0), (10.0, 8.0));
    constrain(&mut before, con(ConstraintKind::Coincident, &[GeomRef::new(a, Sub::End), GeomRef::new(b, Sub::Start)]));
    let mut after = before.clone();
    // The client dragged the shared corner and moved both lines with it.
    move_line(&mut after, a, (0.0, 0.0), (12.0, 0.0));
    move_line(&mut after, b, (12.0, 0.0), (10.0, 8.0));
    let v = check(&before, &after);
    assert!(v.ok, "{v:?}");
    assert_eq!(v.touched, vec![a.hex(), b.hex()]);
    assert_eq!(v.components, vec![a.hex()]);
}

#[test]
fn check_rejects_broken_constraints_and_moved_fixes() {
    let mut before = Drawing::default();
    let a = line(&mut before, (0.0, 0.0), (10.0, 0.0));
    let b = line(&mut before, (10.0, 0.0), (10.0, 8.0));
    let id = constrain(&mut before, con(ConstraintKind::Coincident, &[GeomRef::new(a, Sub::End), GeomRef::new(b, Sub::Start)]));
    let mut after = before.clone();
    // Only one line moved: the corner came apart.
    move_line(&mut after, a, (0.0, 0.0), (12.0, 0.0));
    let v = check(&before, &after);
    assert!(!v.ok);
    assert_eq!(v.unsatisfied, vec![id]);

    let mut before = Drawing::default();
    let f = line(&mut before, (0.0, 0.0), (10.0, 0.0));
    constrain(&mut before, con(ConstraintKind::Fix, &[GeomRef::new(f, Sub::Start)]));
    let mut after = before.clone();
    move_line(&mut after, f, (1.0, 0.0), (10.0, 0.0));
    let v = check(&before, &after);
    assert!(v.fixed_moved && !v.ok, "{v:?}");
}

#[test]
fn distance_constraint_rows_round_trip_through_json() {
    let mut d = Drawing::default();
    let a = line(&mut d, (0.0, 0.0), (10.0, 0.0));
    let mut c = con(ConstraintKind::Distance(DistAxis::Aligned), &[GeomRef::new(a, Sub::Start), GeomRef::new(a, Sub::End)]);
    c.name = "d1".into();
    c.expr = "10".into();
    constrain(&mut d, c);
    let s = snapshot(&d, 0.01);
    let row = s.constraints.first().unwrap();
    let back: Constraint = serde_json::from_value(row.data.clone()).unwrap();
    assert_eq!(back.name, "d1");
    assert_eq!(row.comp, Some(a.hex()));
}

#[test]
fn parts_rebuild_the_drawing_for_the_server() {
    let mut d = Drawing::default();
    let a = line(&mut d, (0.0, 0.0), (10.0, 0.0));
    let b = line(&mut d, (10.0, 0.0), (10.0, 8.0));
    constrain(&mut d, con(ConstraintKind::Perpendicular, &[GeomRef::whole(a), GeomRef::whole(b)]));
    let parts = Parts { entities: d.model.iter().map(|e| e.as_ref().clone()).collect(), constraints: d.constraints.clone(), parameters: vec![] };
    let before = serde_json::to_string(&parts).unwrap();
    let rows: serde_json::Value = serde_json::from_str(&snapshot_json(&before, 0.01).unwrap()).unwrap();
    assert_eq!(rows["entities"][1]["comp"], serde_json::json!(a.hex()));

    let mut tilted = parts.clone();
    if let Some(EntityKind::Line(l)) = tilted.entities.get_mut(1).map(|e| &mut e.kind) {
        l.b = v(11.0, 8.0);
    }
    let verdict: serde_json::Value = serde_json::from_str(&check_json(&before, &serde_json::to_string(&tilted).unwrap()).unwrap()).unwrap();
    assert_eq!(verdict["ok"], serde_json::json!(false));
    assert_eq!(verdict["touched"], serde_json::json!([b.hex()]));
    assert!(check_json("{not json", &before).is_err());
}
