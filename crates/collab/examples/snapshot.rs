//! Print a drawing's PostGIS rows as JSON: `cargo run -p cadcraft-collab --example snapshot -- in.dxf [tol]`.
//!
//! The Elixir server's `mix cadcraft.import` reads this output.

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(path) = args.first() else {
        eprintln!("usage: snapshot <drawing.dxf|.dwg> [chord tolerance]");
        return ExitCode::FAILURE;
    };
    let tol = args.get(1).and_then(|t| t.parse().ok()).unwrap_or(0.01);
    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("{path}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let d = match cadcraft_io::read(&bytes, path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("{path}: {e}");
            return ExitCode::FAILURE;
        }
    };
    match serde_json::to_string(&cadcraft_collab::snapshot(&d, tol)) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
