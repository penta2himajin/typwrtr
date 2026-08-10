//! Speaker term dictionary on disk (ux-decisions §9a).
//!
//! euhadra owns match behaviour (`TermDictionary`); Typwrtr owns the JSON
//! files under Application Support and when the engine is rebuilt.

use std::fs;
use std::path::{Path, PathBuf};

use euhadra::dictionary::{MatchPolicy, TermDictionary, TermEntry};
use euhadra::types::Language;
use serde::{Deserialize, Serialize};

/// One term and the ASR strings that should become it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredTerm {
    /// Preferred spelling, emitted verbatim.
    pub term: String,
    /// What the recogniser tends to produce instead.
    pub aliases: Vec<String>,
}

impl From<StoredTerm> for TermEntry {
    fn from(value: StoredTerm) -> Self {
        TermEntry {
            term: value.term,
            aliases: value.aliases,
        }
    }
}

impl From<&TermEntry> for StoredTerm {
    fn from(value: &TermEntry) -> Self {
        StoredTerm {
            term: value.term.clone(),
            aliases: value.aliases.clone(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
struct DictionaryFile {
    entries: Vec<StoredTerm>,
}

/// Result of reading a language's dictionary file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DictionaryLoad {
    /// File missing or empty — treat as no terms.
    Empty,
    /// Parsed and validated.
    Ready(Vec<StoredTerm>),
    /// File present but unusable. Do not overwrite; mount an empty dictionary.
    Corrupt {
        /// Why the load failed.
        message: String,
    },
}

impl DictionaryLoad {
    /// Entries to hand the pipeline (empty when missing or corrupt).
    pub fn entries_for_pipeline(&self) -> Vec<TermEntry> {
        match self {
            Self::Ready(entries) => entries.iter().cloned().map(TermEntry::from).collect(),
            Self::Empty | Self::Corrupt { .. } => Vec::new(),
        }
    }

    /// Whether Settings should warn that the on-disk file was skipped.
    pub fn load_failed(&self) -> bool {
        matches!(self, Self::Corrupt { .. })
    }

    /// Failure detail when [`load_failed`](Self::load_failed).
    pub fn failure_message(&self) -> Option<&str> {
        match self {
            Self::Corrupt { message } => Some(message.as_str()),
            _ => None,
        }
    }
}

/// Conventional directory: `~/Library/Application Support/Typwrtr/dictionaries`.
pub fn dictionaries_dir() -> PathBuf {
    let home = std::env::var_os("HOME").unwrap_or_default();
    PathBuf::from(home)
        .join("Library")
        .join("Application Support")
        .join("Typwrtr")
        .join("dictionaries")
}

/// Path for one language's JSON file.
pub fn dictionary_path(language: Language) -> PathBuf {
    dictionaries_dir().join(format!("{}.json", language_stem(language)))
}

fn language_stem(language: Language) -> &'static str {
    match language {
        Language::English => "en",
        Language::Japanese => "ja",
        Language::Chinese => "zh",
        Language::Korean => "ko",
        Language::Spanish => "es",
        // euhadra marks Language #[non_exhaustive]; keep a stable stem if variants grow.
        _ => "und",
    }
}

/// Read and validate the on-disk dictionary for `language`.
///
/// Missing file → [`DictionaryLoad::Empty`]. Corrupt / invalid →
/// [`DictionaryLoad::Corrupt`] without touching the file.
pub fn load(language: Language) -> DictionaryLoad {
    load_from_path(&dictionary_path(language), language)
}

/// Load from an explicit path (tests).
pub fn load_from_path(path: &Path, language: Language) -> DictionaryLoad {
    if !path.is_file() {
        return DictionaryLoad::Empty;
    }
    let raw = match fs::read_to_string(path) {
        Ok(s) => s,
        Err(err) => {
            return DictionaryLoad::Corrupt {
                message: format!("could not read {}: {err}", path.display()),
            };
        }
    };
    if raw.trim().is_empty() {
        return DictionaryLoad::Empty;
    }
    let file: DictionaryFile = match serde_json::from_str(&raw) {
        Ok(f) => f,
        Err(err) => {
            return DictionaryLoad::Corrupt {
                message: format!("invalid JSON in {}: {err}", path.display()),
            };
        }
    };
    match validate(language, &file.entries) {
        Ok(()) => {
            if file.entries.is_empty() {
                DictionaryLoad::Empty
            } else {
                DictionaryLoad::Ready(file.entries)
            }
        }
        Err(message) => DictionaryLoad::Corrupt { message },
    }
}

/// Validate entries the way the pipeline will.
pub fn validate(language: Language, entries: &[StoredTerm]) -> Result<(), String> {
    let term_entries: Vec<TermEntry> = entries.iter().cloned().map(TermEntry::from).collect();
    TermDictionary::new(term_entries, MatchPolicy::for_language(language)).map_err(|err| {
        err.problems
            .iter()
            .map(|p| format!("{p:?}"))
            .collect::<Vec<_>>()
            .join("; ")
    })?;
    Ok(())
}

/// Build the processor for the pipeline (always, including empty — Q37).
pub fn term_dictionary(
    language: Language,
    entries: Vec<TermEntry>,
) -> Result<TermDictionary, String> {
    TermDictionary::new(entries, MatchPolicy::for_language(language)).map_err(|err| err.to_string())
}

/// Atomically replace the on-disk dictionary after validation (Q36).
pub fn save(language: Language, entries: Vec<StoredTerm>) -> Result<(), String> {
    save_to_path(&dictionary_path(language), language, entries)
}

/// Save to an explicit path (tests).
pub fn save_to_path(
    path: &Path,
    language: Language,
    entries: Vec<StoredTerm>,
) -> Result<(), String> {
    validate(language, &entries)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let file = DictionaryFile { entries };
    let body = serde_json::to_string_pretty(&file).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, body).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_path(name: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("typwrtr-dict-{name}-{nanos}.json"))
    }

    #[test]
    fn missing_file_is_empty() {
        let path = temp_path("missing");
        let _ = fs::remove_file(&path);
        assert_eq!(
            load_from_path(&path, Language::Japanese),
            DictionaryLoad::Empty
        );
    }

    #[test]
    fn round_trip_save_and_load() {
        let path = temp_path("round");
        let _ = fs::remove_file(&path);
        let entries = vec![StoredTerm {
            term: "typwrtr".into(),
            aliases: vec!["タイプライター".into()],
        }];
        save_to_path(&path, Language::Japanese, entries.clone()).unwrap();
        assert_eq!(
            load_from_path(&path, Language::Japanese),
            DictionaryLoad::Ready(entries)
        );
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn corrupt_json_is_skipped_and_left_on_disk() {
        let path = temp_path("corrupt");
        fs::write(&path, "{not json").unwrap();
        let load = load_from_path(&path, Language::English);
        assert!(load.load_failed(), "{load:?}");
        assert!(load.entries_for_pipeline().is_empty());
        assert_eq!(fs::read_to_string(&path).unwrap(), "{not json");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn invalid_entries_refuse_save() {
        let path = temp_path("bad-save");
        let err = save_to_path(
            &path,
            Language::English,
            vec![StoredTerm {
                term: "ok".into(),
                aliases: vec!["x".into()], // too short
            }],
        )
        .expect_err("short alias must fail");
        assert!(!path.is_file(), "must not write: {err}");
    }

    #[test]
    fn invalid_entries_on_disk_are_corrupt_not_partial() {
        let path = temp_path("bad-load");
        fs::write(&path, r#"{"entries":[{"term":"ok","aliases":["x"]}]}"#).unwrap();
        let load = load_from_path(&path, Language::English);
        assert!(load.load_failed(), "{load:?}");
        assert!(path.is_file());
        let _ = fs::remove_file(&path);
    }
}
