//! The pinned 64-bit SimHash of document text — near prose, near hash.
//!
//! This is a cross-language contract: `packages/media/lib/src/extract/
//! simhash.dart` implements the same algorithm bit for bit, and
//! `packages/media/test/fixtures/simhash_vectors.json` holds vectors both
//! sides must reproduce. Never change it without versioning the hash kind.
//! The steps, precisely:
//!
//! 1. Normalize: lowercase the text, then turn every run of characters
//!    outside ASCII `a-z0-9` (accented letters and em-dashes included —
//!    anything non-ASCII is a separator) into a single space, and trim.
//! 2. Split on single spaces into words.
//! 3. Take 3-word shingles — consecutive, overlapping. A text with fewer
//!    than three words contributes its whole normalized string as the one
//!    shingle, the empty text included.
//! 4. Hash each shingle's UTF-8 bytes with FNV-1a 64: offset basis
//!    0xcbf29ce484222325, prime 0x100000001b3, wrapping multiplication.
//! 5. Classic SimHash bit-vote: 64 counters, +1 where a shingle hash has
//!    the bit set and -1 where it hasn't; the final bit is set where its
//!    counter ends above zero.
//! 6. Render as 16 lowercase hex digits.

/// The SimHash of `text`, as 16 lowercase hex digits.
pub fn simhash(text: &str) -> String {
    let mut votes = [0i64; 64];
    for shingle in shingles(text) {
        let hash = fnv1a64(shingle.as_bytes());
        for (bit, vote) in votes.iter_mut().enumerate() {
            *vote += if (hash >> bit) & 1 == 1 { 1 } else { -1 };
        }
    }
    let mut hash = 0u64;
    for (bit, vote) in votes.iter().enumerate() {
        if *vote > 0 {
            hash |= 1 << bit;
        }
    }
    format!("{hash:016x}")
}

/// FNV-1a 64 over `bytes` — the pinned shingle hash.
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Lowercased, separator-collapsed words, re-joined into 3-word shingles;
/// a text too short to shingle is its own single shingle.
fn shingles(text: &str) -> Vec<String> {
    let normalized = normalize(text);
    let words: Vec<&str> = if normalized.is_empty() {
        Vec::new()
    } else {
        normalized.split(' ').collect()
    };
    if words.len() < 3 {
        return vec![normalized];
    }
    words.windows(3).map(|w| w.join(" ")).collect()
}

fn normalize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut pending_space = false;
    for ch in text.chars() {
        let ch = ch.to_ascii_lowercase();
        if ch.is_ascii_alphanumeric() {
            if pending_space && !out.is_empty() {
                out.push(' ');
            }
            pending_space = false;
            out.push(ch);
        } else {
            pending_space = true;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hamming(a: &str, b: &str) -> u32 {
        let a = u64::from_str_radix(a, 16).unwrap();
        let b = u64::from_str_radix(b, 16).unwrap();
        (a ^ b).count_ones()
    }

    #[test]
    fn short_text_hashes_whole_string() {
        assert_eq!(simhash("hello world"), {
            format!("{:016x}", fnv1a64(b"hello world"))
        });
    }

    #[test]
    fn empty_text_hashes_empty_shingle() {
        assert_eq!(simhash(""), format!("{:016x}", fnv1a64(b"")));
    }

    #[test]
    fn reworded_text_stays_near() {
        let a = simhash("the quick brown fox jumps over the lazy dog");
        let b = simhash("the quick brown fox leaps over the lazy dog");
        assert!(hamming(&a, &b) <= 20, "reworded text drifted too far");
    }

    /// The cross-tier vectors published by the Dart side — both languages
    /// must reproduce them exactly.
    #[test]
    fn matches_pinned_vectors() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../packages/media/test/fixtures/simhash_vectors.json"
        );
        let raw = std::fs::read_to_string(path)
            .expect("simhash_vectors.json missing — run from the repo tree");
        let vectors: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap();
        assert!(vectors.len() >= 5);
        for vector in vectors {
            let text = vector["text"].as_str().unwrap();
            let expected = vector["hashHex"].as_str().unwrap();
            assert_eq!(simhash(text), expected, "vector diverged for {text:?}");
        }
    }
}
