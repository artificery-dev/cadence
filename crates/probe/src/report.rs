//! The probe's answer sheet: typed fields under the Dart `MediaMetadata`
//! JSON names, raw tags in `extra`, pictures alongside.
//!
//! Fields fill first-wins — the best-informed source speaks first and the
//! rest only fill silence — which mirrors how the Dart facade merges tiers.

use base64::Engine;
use serde_json::{Map, Value};

pub struct Report {
    kind: &'static str,
    fields: Map<String, Value>,
    extra: Map<String, Value>,
    artwork: Vec<Artwork>,
}

pub struct Artwork {
    pub mime: String,
    pub bytes: Vec<u8>,
    pub role: &'static str,
}

impl Report {
    pub fn new(kind: &'static str) -> Self {
        Report {
            kind,
            fields: Map::new(),
            extra: Map::new(),
            artwork: Vec::new(),
        }
    }

    pub fn has(&self, key: &str) -> bool {
        self.fields.contains_key(key)
    }

    /// Which shape this report is filling — a field only one shape owns
    /// must check before it types, or the facade drops it on the floor.
    pub fn is_kind(&self, kind: &str) -> bool {
        self.kind == kind
    }

    /// Sets a typed field, first value wins; empty strings say nothing.
    pub fn set(&mut self, key: &str, value: Value) {
        if value.as_str().is_some_and(|s| s.trim().is_empty()) {
            return;
        }
        if !self.fields.contains_key(key) {
            self.fields.insert(key.to_owned(), value);
        }
    }

    pub fn set_str(&mut self, key: &str, value: &str) {
        self.set(key, Value::from(value.trim()));
    }

    pub fn set_int(&mut self, key: &str, value: i64) {
        self.set(key, Value::from(value));
    }

    pub fn set_f64(&mut self, key: &str, value: f64) {
        if value.is_finite() {
            self.set(key, Value::from(value));
        }
    }

    pub fn set_bool(&mut self, key: &str, value: bool) {
        self.set(key, Value::from(value));
    }

    /// Appends to a list field, deduplicated, blanks dropped.
    pub fn push_list(&mut self, key: &str, value: &str) {
        let value = value.trim();
        if value.is_empty() {
            return;
        }
        let list = self
            .fields
            .entry(key.to_owned())
            .or_insert_with(|| Value::Array(Vec::new()));
        if let Value::Array(items) = list {
            if !items.iter().any(|v| v.as_str() == Some(value)) {
                items.push(Value::from(value));
            }
        }
    }

    /// Appends a `{title, startMs}` chapter mark.
    pub fn push_chapter(&mut self, title: &str, start_ms: i64) {
        let list = self
            .fields
            .entry("chapters".to_owned())
            .or_insert_with(|| Value::Array(Vec::new()));
        if let Value::Array(items) = list {
            items.push(serde_json::json!({ "title": title, "startMs": start_ms }));
        }
    }

    /// Sets a member of a nested value type (`musicBrainz`, `replayGain`).
    pub fn set_nested(&mut self, outer: &str, inner: &str, value: Value) {
        if value.as_str().is_some_and(|s| s.trim().is_empty()) {
            return;
        }
        let map = self
            .fields
            .entry(outer.to_owned())
            .or_insert_with(|| Value::Object(Map::new()));
        if let Value::Object(members) = map {
            members.entry(inner.to_owned()).or_insert(value);
        }
    }

    /// The leading four digits of the `date` field, when one was set —
    /// what a video shape stores as its `year`.
    pub fn date_year(&self) -> Option<i64> {
        let date = self.fields.get("date")?.as_str()?;
        let year: String = date.chars().take(4).collect();
        year.parse().ok().filter(|y| *y >= 1000)
    }

    /// Preserves a raw tag under its source-original key, first value wins.
    pub fn extra(&mut self, key: &str, value: Value) {
        if !self.extra.contains_key(key) {
            self.extra.insert(key.to_owned(), value);
        }
    }

    pub fn extra_str(&mut self, key: &str, value: &str) {
        self.extra(key, Value::from(value));
    }

    pub fn push_artwork(&mut self, mime: &str, bytes: &[u8], role: &'static str) {
        if bytes.is_empty() {
            return;
        }
        self.artwork.push(Artwork {
            mime: mime.to_owned(),
            bytes: bytes.to_vec(),
            role,
        });
    }

    /// The `ok` payload, exactly as probe.dart expects to read it.
    pub fn to_json(&self) -> Value {
        let engine = base64::engine::general_purpose::STANDARD;
        let artwork: Vec<Value> = self
            .artwork
            .iter()
            .map(|art| {
                serde_json::json!({
                    "mime": art.mime,
                    "bytesBase64": engine.encode(&art.bytes),
                    "role": art.role,
                })
            })
            .collect();
        let mut ok = Map::new();
        ok.insert("kind".into(), Value::from(self.kind));
        ok.insert("fields".into(), Value::Object(self.fields.clone()));
        ok.insert("extra".into(), Value::Object(self.extra.clone()));
        ok.insert("artwork".into(), Value::Array(artwork));
        Value::Object(ok)
    }
}
