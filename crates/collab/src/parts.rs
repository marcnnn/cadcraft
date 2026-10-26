//! A drawing rebuilt from the rows the server stores, so the server can check a commit with the
//! same code CADCraft uses, and the JSON entry points the server's NIF calls.

use serde::{Deserialize, Serialize};

use cadcraft_doc::{Constraint, Drawing, Entity, Parameter};

use crate::{rows, verify};

/// Most entities, constraints or parameters one request may carry.
pub const MAX_ROWS: usize = 1_000_000;

/// The parametric content of a drawing as stored: entities (CADCraft's own JSON), constraints
/// and parameters.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Parts {
    #[serde(default)]
    pub entities: Vec<Entity>,
    #[serde(default)]
    pub constraints: Vec<Constraint>,
    #[serde(default)]
    pub parameters: Vec<Parameter>,
}

impl Parts {
    /// A drawing holding these parts in model space.
    pub fn drawing(self) -> Result<Drawing, String> {
        if self.entities.len() > MAX_ROWS || self.constraints.len() > MAX_ROWS || self.parameters.len() > MAX_ROWS {
            return Err(format!("more than {MAX_ROWS} rows"));
        }
        let mut d = Drawing::default();
        for e in self.entities {
            d.bump_handseed(e.handle);
            d.ensure_layer(&e.common.layer);
            d.model.push(e);
        }
        d.constraints = self.constraints;
        d.parametric.parameters = self.parameters;
        Ok(d)
    }
}

/// `parts` JSON in, [`rows::Snapshot`] JSON out.
pub fn snapshot_json(parts: &str, tol: f64) -> Result<String, String> {
    let d = parse(parts)?.drawing()?;
    serde_json::to_string(&rows::snapshot(&d, tol)).map_err(|e| e.to_string())
}

/// `before` and `after` [`Parts`] JSON in, [`verify::Verdict`] JSON out.
pub fn check_json(before: &str, after: &str) -> Result<String, String> {
    let (before, after) = (parse(before)?.drawing()?, parse(after)?.drawing()?);
    serde_json::to_string(&verify::check(&before, &after)).map_err(|e| e.to_string())
}

fn parse(json: &str) -> Result<Parts, String> {
    serde_json::from_str(json).map_err(|e| format!("bad drawing parts: {e}"))
}
