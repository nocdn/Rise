//! Builds one engine per filter list, as WebKit gets one rule set per list, so each list keeps
//! its own exceptions, with Rise's site compatibility exceptions shared by all of them;
//! they're saved for the library to load.

use adblock::lists::{FilterSet, ParseOptions};
use adblock::Engine;
use std::path::PathBuf;

const LISTS: [(&str, &str); 2] = [
    ("easylist", "../../Filters/Sources/easylist.txt"),
    ("rise", "rise.txt"),
];

fn main() {
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let compatibility = root.join("compatibility.txt");
    println!("cargo:rerun-if-changed={}", compatibility.display());
    let compatibility = std::fs::read_to_string(compatibility).expect("compatibility exceptions");
    for (name, path) in LISTS {
        let path = root.join(path);
        println!("cargo:rerun-if-changed={}", path.display());
        let text = std::fs::read_to_string(&path).expect("filter list");
        let mut filters = FilterSet::new(false);
        filters.add_filter_list(text, ParseOptions::default());
        filters.add_filter_list(compatibility.clone(), ParseOptions::default());
        let engine = Engine::new_with_filter_set(filters);
        std::fs::write(out.join(format!("{name}.dat")), engine.serialize()).unwrap();
    }
}
