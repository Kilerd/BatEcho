//! Local research adapter linked to GPL-3.0-or-later qingjian-neural.
use std::io::{self, BufRead, Write};
use std::path::Path;
use std::time::Instant;

use qingjian_neural::CharScorer;
use serde::Deserialize;

#[derive(Deserialize)]
struct Request {
    #[serde(default)]
    context: String,
    texts: Vec<String>,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let model = std::env::args().nth(1).ok_or("expected model.qjm path")?;
    let scorer = CharScorer::load(Path::new(&model))?;
    let mut out = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let request: Request = serde_json::from_str(&line?)?;
        let texts: Vec<&str> = request.texts.iter().map(String::as_str).collect();
        let start = Instant::now();
        let scores = scorer.score(&request.context, &texts)?;
        let result = serde_json::json!({"scores":scores,"elapsed_s":start.elapsed().as_secs_f64()});
        writeln!(out, "{result}")?;
        out.flush()?;
    }
    Ok(())
}
