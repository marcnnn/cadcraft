//! A drawing as the rows the server stores: entities, constraints and parameters.

use serde::Serialize;

use cadcraft_doc::{Drawing, Handle};

use crate::{comps, wkt};

/// One model-space entity.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntityRow {
    /// Hex handle, unique per drawing.
    pub handle: String,
    /// CADCraft's type name (`Line`, `Circle`, `Polyline`, …).
    pub kind: &'static str,
    pub layer: String,
    /// Exact geometry (curves kept), for the kinds PostGIS holds exactly.
    pub exact: Option<String>,
    /// Flattened geometry for spatial queries and tiles.
    pub flat: Option<String>,
    /// Hex key of the entity's constraint component; `None` when unconstrained.
    pub comp: Option<String>,
    /// The whole entity as CADCraft serializes it, so the drawing reads back losslessly.
    pub data: serde_json::Value,
}

/// One constraint, as CADCraft stores it.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConstraintRow {
    pub id: u32,
    /// Hex key of the component the constraint belongs to.
    pub comp: Option<String>,
    pub data: serde_json::Value,
}

/// One user parameter (Parameters Manager).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ParameterRow {
    pub name: String,
    pub expr: String,
    pub description: String,
}

/// Everything the server stores for one drawing revision.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub entities: Vec<EntityRow>,
    pub constraints: Vec<ConstraintRow>,
    pub parameters: Vec<ParameterRow>,
}

/// The rows of `d`'s model space, flattened within `tol` drawing units.
pub fn snapshot(d: &Drawing, tol: f64) -> Snapshot {
    let comp = comps::components(d);
    let key = |h: Handle| comp.get(&h).map(|k| k.hex());
    let entities = d
        .model
        .iter()
        .map(|e| EntityRow {
            handle: e.handle.hex(),
            kind: e.kind.type_name(),
            layer: e.common.layer.clone(),
            exact: wkt::exact(&e.kind),
            flat: wkt::flat(&e.kind, tol),
            comp: key(e.handle),
            data: serde_json::to_value(e.as_ref()).unwrap_or(serde_json::Value::Null),
        })
        .collect();
    let constraints = d
        .constraints
        .iter()
        .map(|c| ConstraintRow {
            id: c.id,
            comp: c.refs.first().and_then(|r| key(r.handle)),
            data: serde_json::to_value(c).unwrap_or(serde_json::Value::Null),
        })
        .collect();
    let parameters = d
        .parametric
        .parameters
        .iter()
        .map(|p| ParameterRow { name: p.name.clone(), expr: p.expr.clone(), description: p.description.clone() })
        .collect();
    Snapshot { entities, constraints, parameters }
}
