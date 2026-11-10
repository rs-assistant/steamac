//! Steam app name lookup for `game <appid> <name>` (launcher settings list).
//!
//! Library folders: ~/.local/share/Steam/steamapps/libraryfolders.vdf lists
//! every library ("path" "<dir>"); each has steamapps/appmanifest_<id>.acf
//! whose AppState "name" key is the display name. Both files are Valve KeyValues
//! text; only quoted tokens matter here, so a tiny tokenizer is enough.

use std::collections::HashSet;
use std::path::PathBuf;

use crate::port::Port;

/// Shared by focus and scope tracking: report a game's name at most once per
/// boot, including across agent/session restarts. Missing manifests are retried.
pub struct Names {
    steam_root: PathBuf,
    marker: PathBuf,
    named: HashSet<u32>,
}

impl Names {
    pub fn new(steam_root: PathBuf, marker: PathBuf) -> Names {
        let named = crate::read_marker(&marker).map(|text| {
            let mut lines = text.lines();
            if lines.next().map(str::trim) == Some(crate::boot_id().as_str()) {
                lines.filter_map(|line| line.trim().parse().ok()).collect()
            } else {
                HashSet::new()
            }
        }).unwrap_or_default();
        Names { steam_root, marker, named }
    }

    pub fn report(&mut self, appid: u32, port: &mut Port) {
        if self.named.contains(&appid) {
            return;
        }
        if let Some(name) = lookup(&self.steam_root, appid) {
            port.send(&format!("game {appid} {name}"));
            self.named.insert(appid);
            let mut marker = crate::boot_id();
            for id in &self.named {
                marker.push_str(&format!("\n{id}"));
            }
            crate::write_marker(&self.marker, &marker);
        }
    }
}

/// Quoted tokens of a KeyValues text, with \" \\ \n \t unescaped.
fn tokens(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '"' {
            continue;
        }
        let mut s = String::new();
        while let Some(c) = chars.next() {
            match c {
                '"' => break,
                '\\' => match chars.next() {
                    Some('n') => s.push('\n'),
                    Some('t') => s.push('\t'),
                    Some(o) => s.push(o),
                    None => break,
                },
                o => s.push(o),
            }
        }
        out.push(s);
    }
    out
}

/// Value of the first `"key" "value"` pair (case-insensitive key).
fn first_value(text: &str, key: &str) -> Option<String> {
    let t = tokens(text);
    t.windows(2).find(|w| w[0].eq_ignore_ascii_case(key)).map(|w| w[1].clone())
}

/// Steam's default library; shared by manifest and Proton prefix lookups.
pub(crate) fn steam_root() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/home/steamos".into());
    std::env::var("FX_PROGRESS_STEAM_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(format!("{home}/.local/share/Steam")))
}

pub(crate) fn library_dirs(steam_root: &PathBuf) -> Vec<PathBuf> {
    let mut dirs = vec![steam_root.clone()];
    if let Ok(vdf) = std::fs::read_to_string(steam_root.join("steamapps/libraryfolders.vdf")) {
        let t = tokens(&vdf);
        for w in t.windows(2) {
            if w[0].eq_ignore_ascii_case("path") {
                let p = PathBuf::from(&w[1]);
                if !dirs.contains(&p) {
                    dirs.push(p);
                }
            }
        }
    }
    dirs
}

/// Display name of `appid` from the first library that has its manifest,
/// sanitised to one line of printable text; None if not installed/unknown.
fn lookup(root: &PathBuf, appid: u32) -> Option<String> {
    for dir in library_dirs(root) {
        let acf = dir.join(format!("steamapps/appmanifest_{appid}.acf"));
        let Ok(text) = std::fs::read_to_string(&acf) else { continue };
        if let Some(name) = first_value(&text, "name") {
            let clean: String = name
                .chars()
                .map(|c| if c.is_control() { ' ' } else { c })
                .collect::<String>()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            if !clean.is_empty() {
                return Some(clean);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acf_name() {
        let acf = "\"AppState\"\n{\n\t\"appid\"\t\t\"570\"\n\t\"name\"\t\t\"Dota \\\"2\\\"\"\n\t\"UserConfig\"\n\t{\n\t\t\"name\"\t\"x\"\n\t}\n}\n";
        assert_eq!(first_value(acf, "name").as_deref(), Some("Dota \"2\""));
    }

    #[test]
    fn vdf_paths() {
        let vdf = "\"libraryfolders\"\n{\n\"0\"\n{\n\"path\"\t\t\"/home/steamos/.local/share/Steam\"\n}\n\"1\"\n{\n\"path\"\t\t\"/run/media/sd\"\n}\n}";
        let t = tokens(vdf);
        let paths: Vec<_> = t.windows(2).filter(|w| w[0] == "path").map(|w| w[1].clone()).collect();
        assert_eq!(paths, vec!["/home/steamos/.local/share/Steam", "/run/media/sd"]);
    }
}
