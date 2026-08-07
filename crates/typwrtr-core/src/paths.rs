//! Resolve WhisperLocal CLI / model paths for dogfood.

use std::path::{Path, PathBuf};

use euhadra::types::Language;

use crate::engine::EngineError;

/// Default relative model directory used by `scripts/fetch-models.sh`.
pub const DEFAULT_WHISPER_MODEL_SUBDIR: &str = "models/whisper";

/// Default relative whisper.cpp install used by `scripts/fetch-models.sh`.
pub const DEFAULT_WHISPER_CLI_REL: &str = "vendor/whisper.cpp/build/bin/whisper-cli";

/// Pick the ggml file for a language under a model directory.
pub fn whisper_model_path(model_dir: &Path, language: Language) -> PathBuf {
    match language {
        Language::English => model_dir.join("ggml-tiny.en.bin"),
        // Multilingual tiny covers ja (and other supported langs).
        _ => model_dir.join("ggml-tiny.bin"),
    }
}

/// BCP-47 / whisper `-l` tag for Typwrtr's FFI languages.
pub fn whisper_language_tag(language: Language) -> &'static str {
    match language {
        Language::English => "en",
        Language::Japanese => "ja",
        Language::Chinese => "zh",
        Language::Korean => "ko",
        Language::Spanish => "es",
        // Language is #[non_exhaustive] in euhadra.
        _ => "en",
    }
}

/// Resolve CLI + model from explicit paths, validating they exist.
pub fn resolve_whisper_paths(
    cli_path: impl AsRef<Path>,
    model_path: impl AsRef<Path>,
) -> Result<(PathBuf, PathBuf), EngineError> {
    let cli = cli_path.as_ref().to_path_buf();
    let model = model_path.as_ref().to_path_buf();
    if !cli.is_file() {
        return Err(EngineError::new(format!(
            "whisper-cli not found at {}",
            cli.display()
        )));
    }
    if !model.is_file() {
        return Err(EngineError::new(format!(
            "whisper model not found at {}",
            model.display()
        )));
    }
    Ok((cli, model))
}

/// Resolve from environment / conventional dogfood locations.
///
/// Looks for:
/// - `TYPWRTR_WHISPER_CLI` or `WHISPER_CLI`
/// - `TYPWRTR_WHISPER_MODEL_DIR` or `TYPWRTR_MODELS_DIR/whisper` or `./models/whisper`
pub fn resolve_whisper_from_env(language: Language) -> Result<(PathBuf, PathBuf), EngineError> {
    let cli = std::env::var_os("TYPWRTR_WHISPER_CLI")
        .or_else(|| std::env::var_os("WHISPER_CLI"))
        .map(PathBuf::from)
        .or_else(default_cli_candidate)
        .ok_or_else(|| {
            EngineError::new(
                "whisper-cli path not set (TYPWRTR_WHISPER_CLI / WHISPER_CLI) and default vendor path missing",
            )
        })?;

    let model_dir = std::env::var_os("TYPWRTR_WHISPER_MODEL_DIR")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("TYPWRTR_MODELS_DIR").map(|d| PathBuf::from(d).join("whisper"))
        })
        .or_else(default_model_dir_candidate)
        .ok_or_else(|| {
            EngineError::new(
                "whisper model dir not set (TYPWRTR_WHISPER_MODEL_DIR) and ./models/whisper missing",
            )
        })?;

    let model = whisper_model_path(&model_dir, language);
    resolve_whisper_paths(cli, model)
}

fn default_cli_candidate() -> Option<PathBuf> {
    let p = PathBuf::from(DEFAULT_WHISPER_CLI_REL);
    p.is_file().then_some(p)
}

fn default_model_dir_candidate() -> Option<PathBuf> {
    let p = PathBuf::from(DEFAULT_WHISPER_MODEL_SUBDIR);
    p.is_dir().then_some(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn english_uses_tiny_en_model() {
        let p = whisper_model_path(Path::new("/m"), Language::English);
        assert!(p.ends_with("ggml-tiny.en.bin"));
    }

    #[test]
    fn japanese_uses_multilingual_tiny() {
        let p = whisper_model_path(Path::new("/m"), Language::Japanese);
        assert!(p.ends_with("ggml-tiny.bin"));
    }
}
