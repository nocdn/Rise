//! Rise's ad blocking for Chromium pages: Brave's adblock engine, built from EasyList
//! and Rise's ad rules, behind a small C interface for the bridge.
//! Requests are checked on Chromium's network thread; until the engines load, nothing is blocked.

use adblock::request::Request;
use adblock::Engine;
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::sync::OnceLock;

static LISTS: OnceLock<Vec<Engine>> = OnceLock::new();

const SAVED: [&[u8]; 2] = [
    include_bytes!(concat!(env!("OUT_DIR"), "/easylist.dat")),
    include_bytes!(concat!(env!("OUT_DIR"), "/rise.dat")),
];

fn text<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value) }.to_str().ok()
}

fn owned(value: String) -> *mut c_char {
    CString::new(value).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// Loads the engines; slow enough to keep off the main thread. Safe to call more than once.
#[no_mangle]
pub extern "C" fn rise_adblock_load() -> bool {
    LISTS
        .get_or_init(|| {
            SAVED
                .iter()
                .filter_map(|bytes| {
                    let mut engine = Engine::default();
                    engine.deserialize(bytes).ok()?;
                    Some(engine)
                })
                .collect()
        })
        .len()
        == SAVED.len()
}

/// Whether a request for `url` should not go out. `source` is the page's own address (its
/// top-level site), and `kind` the adblock name for what's fetched: script, image, stylesheet,
/// xmlhttprequest, sub_frame and so on.
#[no_mangle]
pub extern "C" fn rise_adblock_blocks(url: *const c_char, source: *const c_char, kind: *const c_char) -> bool {
    let (Some(url), Some(source), Some(kind)) = (text(url), text(source), text(kind)) else { return false };
    let Some(lists) = LISTS.get() else { return false };
    let Ok(request) = Request::new(url, source, kind, "get") else { return false };
    lists.iter().any(|engine| engine.check_network_request(&request).should_block())
}

/// Selectors to hide on a document at `url`, as a JSON list. With `classes` and `ids`, JSON
/// lists of the names the document uses, it's the general selectors for those names instead.
/// Free with `rise_adblock_free_string`.
#[no_mangle]
pub extern "C" fn rise_adblock_hidden(url: *const c_char, classes: *const c_char, ids: *const c_char) -> *mut c_char {
    let Some(url) = text(url) else { return std::ptr::null_mut() };
    let Some(lists) = LISTS.get() else { return owned("[]".into()) };
    let names = |value: *const c_char| -> Option<Vec<String>> { serde_json::from_str(text(value)?).ok() };
    let general = names(classes).zip(names(ids));
    let mut selectors: Vec<String> = Vec::new();
    for engine in lists {
        let resources = engine.url_cosmetic_resources(url);
        match &general {
            None => selectors.extend(resources.hide_selectors),
            Some(_) if resources.generichide => {}
            Some((classes, ids)) => {
                let exceptions: HashSet<String> = resources.exceptions;
                selectors.extend(engine.hidden_class_id_selectors(classes, ids, &exceptions));
            }
        }
    }
    selectors.sort();
    selectors.dedup();
    owned(serde_json::to_string(&selectors).unwrap_or_else(|_| "[]".into()))
}

#[no_mangle]
pub extern "C" fn rise_adblock_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hidden(url: &str, general: Option<(&str, &str)>) -> Vec<String> {
        let url = CString::new(url).unwrap();
        let (classes, ids) = general.map(|(c, i)| (CString::new(c).unwrap(), CString::new(i).unwrap())).unzip();
        let value = rise_adblock_hidden(
            url.as_ptr(),
            classes.as_ref().map_or(std::ptr::null(), |c| c.as_ptr()),
            ids.as_ref().map_or(std::ptr::null(), |i| i.as_ptr()),
        );
        let list = serde_json::from_str(unsafe { CStr::from_ptr(value) }.to_str().unwrap()).unwrap();
        rise_adblock_free_string(value);
        list
    }

    fn blocks(url: &str, source: &str, kind: &str) -> bool {
        let [url, source, kind] = [url, source, kind].map(|s| CString::new(s).unwrap());
        rise_adblock_blocks(url.as_ptr(), source.as_ptr(), kind.as_ptr())
    }

    #[test]
    fn blocks_ads_and_hides_ad_slots() {
        let start = std::time::Instant::now();
        assert!(rise_adblock_load());
        eprintln!("loaded in {:?}", start.elapsed());
        assert!(blocks("https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js", "https://example.com/", "script"));
        assert!(blocks("https://example.com/js/ads.min.js", "https://example.com/", "script"));
        assert!(!blocks("http://localhost:8000/ads.js", "http://localhost:8000/", "script"));
        assert!(!blocks("https://example.com/app.js", "https://example.com/", "script"));
        assert!(hidden("https://example.com/", None).iter().any(|s| s.contains("ads_banner")));
        assert!(hidden("https://example.com/", Some((r#"["adsbox"]"#, "[]"))).contains(&".adsbox".to_string()));
        assert!(!hidden("http://localhost:8000/", Some((r#"["adsbox"]"#, "[]"))).iter().any(|s| s.contains("adsbox")));
    }

    #[test]
    fn sites_keep_their_own_assets() {
        assert!(rise_adblock_load());
        for (url, kind) in [
            ("https://sentry.io/_astro/Layout.CKBeCQbz.css", "stylesheet"),
            ("https://sentry.io/_astro/page.CVCtUsIM.js", "script"),
            ("https://sentry.io/fonts/inter.woff2", "font"),
            ("https://sentry.io/logo.svg", "image"),
            ("https://static.sentry.io/app.js", "script"),
        ] {
            assert!(!blocks(url, "https://sentry.io/", kind), "site asset blocked: {url}");
        }
        assert!(!blocks("https://sentry.io/_astro/page.CVCtUsIM.js", "https://www.sentry.io/", "script"));
        assert!(!blocks("https://plausible.io/assets/app.css", "https://plausible.io/", "stylesheet"));
        assert!(!blocks("https://sentry.anytype.io/assets/app.css", "https://anytype.io/", "stylesheet"));
    }

    #[test]
    fn analytics_and_telemetry_are_not_blocked() {
        assert!(rise_adblock_load());
        for source in ["https://example.com/", "https://sentry.io/"] {
            for (url, kind) in [
                ("https://www.google-analytics.com/analytics.js", "script"),
                ("https://plausible.io/js/script.js", "script"),
                ("https://sentry.io/_astro/page.CVCtUsIM.js", "script"),
                ("https://o123.ingest.sentry.io/api/456/envelope/", "xmlhttprequest"),
                ("https://sentry.anytype.io/assets/app.css", "stylesheet"),
                ("https://browser.sentry-cdn.com/bundle.min.js", "script"),
            ] {
                assert!(!blocks(url, source, kind), "non-ad request blocked: {url} from {source}");
            }
        }
        // Removing telemetry rules must preserve first-party ad rules.
        assert!(blocks("https://sentry.io/js/ads.min.js", "https://sentry.io/", "script"));
        assert!(blocks("https://sentry.io/x_ads_banner_1.png", "https://sentry.io/", "image"));
    }

    #[test]
    fn sentry_dashboard_keeps_its_separate_asset_cdn() {
        assert!(rise_adblock_load());
        for source in ["https://sentry.io/auth/login/", "https://acme.sentry.io/settings/organization/", "https://sentry.dev/"] {
            for (url, kind) in [
                ("https://s1.sentry-cdn.com/_static/dist/sentry/entrypoints-hashed/sentry.css", "stylesheet"),
                ("https://s1.sentry-cdn.com/_static/dist/sentry/entrypoints-hashed/app.js", "script"),
                ("https://s1.sentry-cdn.com/_static/version/sentry/js/ads.js", "script"),
            ] {
                assert!(!blocks(url, source, kind), "dashboard asset blocked: {url} from {source}");
            }
        }
        // The exception for Sentry's ads.js probe is limited to its own sites.
        for source in ["https://example.com/", "https://sentry.io.example.com/"] {
            assert!(blocks("https://s1.sentry-cdn.com/_static/version/sentry/js/ads.js", source, "script"));
        }
    }
}
