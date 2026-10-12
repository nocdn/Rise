//! Builds one engine per filter list, as WebKit gets one rule set per list, so each list keeps
//! its own exceptions; they're saved for the library to load.

use adblock::lists::{FilterSet, ParseOptions};
use adblock::Engine;
use std::path::PathBuf;

const LISTS: [(&str, &str); 4] = [
    ("hagezi", "../../Filters/Sources/hagezi-mini.txt"),
    ("easylist", "../../Filters/Sources/easylist.txt"),
    ("easyprivacy", "../../Filters/Sources/easyprivacy.txt"),
    ("rise", "rise.txt"),
];

fn main() {
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    for (name, path) in LISTS {
        let path = root.join(path);
        println!("cargo:rerun-if-changed={}", path.display());
        let text = std::fs::read_to_string(&path).expect("filter list");
        let mut filters = FilterSet::new(false);
        filters.add_filter_list(text, ParseOptions::default());
        let engine = Engine::new_with_filter_set(filters);
        std::fs::write(out.join(format!("{name}.dat")), engine.serialize()).unwrap();
    }
}
