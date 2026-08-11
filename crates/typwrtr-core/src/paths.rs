//! Resolve ASR model paths for dogfood (aligned with euhadra L1 packs).

use std::path::{Path, PathBuf};

use euhadra::types::Language;

use crate::engine::EngineError;

/// Default relative model directory used by `scripts/fetch-models.sh`.
pub const DEFAULT_WHISPER_MODEL_SUBDIR: &str = "models/whisper";

/// Default relative whisper.cpp install used by `scripts/fetch-models.sh`.
pub const DEFAULT_WHISPER_CLI_REL: &str = "vendor/whisper.cpp/build/bin/whisper-cli";

/// Default Parakeet-ja ONNX bundle (euhadra `setup_parakeet_ja.sh` layout).
pub const DEFAULT_PARAKEET_JA_SUBDIR: &str = "models/parakeet-tdt_ctc-0.6b-ja";

/// Canary-180M-Flash ONNX (en / es) — euhadra `setup_canary.sh`.
pub const DEFAULT_CANARY_SUBDIR: &str = "models/canary-180m-flash-onnx";

/// Paraformer-large Chinese — euhadra `setup_paraformer_zh.sh`.
pub const DEFAULT_PARAFORMER_ZH_SUBDIR: &str = "models/paraformer-zh";

/// SenseVoice-Small ONNX (legacy ko) — euhadra `setup_sensevoice.sh`.
pub const DEFAULT_SENSEVOICE_SUBDIR: &str = "models/sensevoice-small-onnx";

/// Dolphin small CTC ONNX (ko) — euhadra `setup_dolphin_ko.sh`.
pub const DEFAULT_DOLPHIN_KO_SUBDIR: &str = "models/dolphin-ko";

/// Pick the ggml file for a language under a model directory.
pub fn whisper_model_path(model_dir: &Path, language: Language) -> PathBuf {
    match language {
        Language::English => model_dir.join("ggml-tiny.en.bin"),
        // Multilingual tiny covers ja (and other supported langs).
        _ => model_dir.join("ggml-tiny.bin"),
    }
}

/// BCP-47 / whisper `-l` / Canary language tag for Typwrtr's FFI languages.
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

/// Validate a Parakeet TDT ONNX bundle directory.
pub fn resolve_parakeet_dir(model_dir: impl AsRef<Path>) -> Result<PathBuf, EngineError> {
    let dir = model_dir.as_ref().to_path_buf();
    if !dir.is_dir() {
        return Err(EngineError::new(format!(
            "Parakeet model dir not found at {}",
            dir.display()
        )));
    }
    for required in [
        "encoder-model.onnx",
        "encoder-model.onnx.data",
        "decoder_joint-model.onnx",
        "vocab.txt",
    ] {
        let p = dir.join(required);
        if !p.is_file() {
            return Err(EngineError::new(format!(
                "Parakeet bundle incomplete: missing {} under {}",
                required,
                dir.display()
            )));
        }
    }
    Ok(dir)
}

/// Resolve Parakeet-ja dir from env / conventional dogfood locations.
pub fn resolve_parakeet_ja_from_env() -> Result<PathBuf, EngineError> {
    let dir = std::env::var_os("TYPWRTR_PARAKEET_JA_DIR")
        .or_else(|| std::env::var_os("PARAKEET_JA_DIR"))
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("TYPWRTR_MODELS_DIR")
                .map(|d| PathBuf::from(d).join("parakeet-tdt_ctc-0.6b-ja"))
        })
        .or_else(default_parakeet_ja_candidate)
        .ok_or_else(|| {
            EngineError::new(
                "Parakeet-ja dir not set (TYPWRTR_PARAKEET_JA_DIR) and default models path missing",
            )
        })?;
    resolve_parakeet_dir(dir)
}

/// Validate Canary ONNX bundle (INT8 and/or FP32 filenames).
pub fn resolve_canary_dir(model_dir: impl AsRef<Path>) -> Result<PathBuf, EngineError> {
    let dir = model_dir.as_ref().to_path_buf();
    if !dir.is_dir() {
        return Err(EngineError::new(format!(
            "Canary model dir not found at {}",
            dir.display()
        )));
    }
    let vocab = dir.join("vocab.txt");
    if !vocab.is_file() {
        return Err(EngineError::new(format!(
            "Canary bundle incomplete: missing vocab.txt under {}",
            dir.display()
        )));
    }
    let has_fp32 =
        dir.join("encoder-model.onnx").is_file() && dir.join("decoder-model.onnx").is_file();
    let has_int8 = dir.join("encoder-model.int8.onnx").is_file()
        && dir.join("decoder-model.int8.onnx").is_file();
    if !has_fp32 && !has_int8 {
        return Err(EngineError::new(format!(
            "Canary bundle incomplete: need encoder/decoder (.onnx or .int8.onnx) under {}",
            dir.display()
        )));
    }
    Ok(dir)
}

/// Prefer INT8 weights when present (and FP32 names are absent).
pub fn canary_uses_int8(model_dir: &Path) -> bool {
    model_dir.join("encoder-model.int8.onnx").is_file()
        && !model_dir.join("encoder-model.onnx").is_file()
}

pub fn resolve_canary_from_env() -> Result<PathBuf, EngineError> {
    let dir = std::env::var_os("TYPWRTR_CANARY_DIR")
        .or_else(|| std::env::var_os("CANARY_DIR"))
        .or_else(|| std::env::var_os("CANARY_ES_DIR"))
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("TYPWRTR_MODELS_DIR")
                .map(|d| PathBuf::from(d).join("canary-180m-flash-onnx"))
        })
        .or_else(default_canary_candidate)
        .ok_or_else(|| {
            EngineError::new(
                "Canary dir not set (TYPWRTR_CANARY_DIR) and default models path missing",
            )
        })?;
    resolve_canary_dir(dir)
}

/// Validate Paraformer-zh bundle.
pub fn resolve_paraformer_zh_dir(model_dir: impl AsRef<Path>) -> Result<PathBuf, EngineError> {
    let dir = model_dir.as_ref().to_path_buf();
    if !dir.is_dir() {
        return Err(EngineError::new(format!(
            "Paraformer model dir not found at {}",
            dir.display()
        )));
    }
    for required in ["model.onnx", "am.mvn", "tokens.json"] {
        let p = dir.join(required);
        if !p.is_file() {
            return Err(EngineError::new(format!(
                "Paraformer bundle incomplete: missing {} under {}",
                required,
                dir.display()
            )));
        }
    }
    Ok(dir)
}

pub fn resolve_paraformer_zh_from_env() -> Result<PathBuf, EngineError> {
    let dir = std::env::var_os("TYPWRTR_PARAFORMER_ZH_DIR")
        .or_else(|| std::env::var_os("PARAFORMER_ZH_DIR"))
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("TYPWRTR_MODELS_DIR").map(|d| PathBuf::from(d).join("paraformer-zh"))
        })
        .or_else(default_paraformer_zh_candidate)
        .ok_or_else(|| {
            EngineError::new(
                "Paraformer-zh dir not set (TYPWRTR_PARAFORMER_ZH_DIR) and default models path missing",
            )
        })?;
    resolve_paraformer_zh_dir(dir)
}

/// Validate SenseVoice-Small ONNX bundle.
pub fn resolve_sensevoice_dir(model_dir: impl AsRef<Path>) -> Result<PathBuf, EngineError> {
    let dir = model_dir.as_ref().to_path_buf();
    if !dir.is_dir() {
        return Err(EngineError::new(format!(
            "SenseVoice model dir not found at {}",
            dir.display()
        )));
    }
    for required in ["model.int8.onnx", "am.mvn", "tokens.txt", "metadata.json"] {
        let p = dir.join(required);
        if !p.is_file() {
            return Err(EngineError::new(format!(
                "SenseVoice bundle incomplete: missing {} under {}",
                required,
                dir.display()
            )));
        }
    }
    Ok(dir)
}

pub fn resolve_sensevoice_from_env() -> Result<PathBuf, EngineError> {
    let dir = std::env::var_os("TYPWRTR_SENSEVOICE_DIR")
        .or_else(|| std::env::var_os("SENSEVOICE_DIR"))
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("TYPWRTR_MODELS_DIR")
                .map(|d| PathBuf::from(d).join("sensevoice-small-onnx"))
        })
        .or_else(default_sensevoice_candidate)
        .ok_or_else(|| {
            EngineError::new(
                "SenseVoice dir not set (TYPWRTR_SENSEVOICE_DIR) and default models path missing",
            )
        })?;
    resolve_sensevoice_dir(dir)
}

/// Validate Dolphin small CTC ONNX bundle (Korean path).
pub fn resolve_dolphin_ko_dir(model_dir: impl AsRef<Path>) -> Result<PathBuf, EngineError> {
    let dir = model_dir.as_ref().to_path_buf();
    if !dir.is_dir() {
        return Err(EngineError::new(format!(
            "Dolphin-ko model dir not found at {}",
            dir.display()
        )));
    }
    for required in ["model.int8.onnx", "tokens.txt"] {
        let p = dir.join(required);
        if !p.is_file() {
            return Err(EngineError::new(format!(
                "Dolphin-ko bundle incomplete: missing {} under {}",
                required,
                dir.display()
            )));
        }
    }
    Ok(dir)
}

/// Resolve Dolphin-ko from env / conventional dogfood paths.
pub fn resolve_dolphin_ko_from_env() -> Result<PathBuf, EngineError> {
    let dir = std::env::var_os("TYPWRTR_DOLPHIN_KO_DIR")
        .or_else(|| std::env::var_os("DOLPHIN_KO_DIR"))
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("TYPWRTR_MODELS_DIR").map(|d| PathBuf::from(d).join("dolphin-ko"))
        })
        .or_else(default_dolphin_ko_candidate)
        .ok_or_else(|| {
            EngineError::new(
                "Dolphin-ko dir not set (TYPWRTR_DOLPHIN_KO_DIR) and default models path missing",
            )
        })?;
    resolve_dolphin_ko_dir(dir)
}

fn default_cli_candidate() -> Option<PathBuf> {
    let p = PathBuf::from(DEFAULT_WHISPER_CLI_REL);
    p.is_file().then_some(p)
}

fn default_model_dir_candidate() -> Option<PathBuf> {
    let p = PathBuf::from(DEFAULT_WHISPER_MODEL_SUBDIR);
    p.is_dir().then_some(p)
}

fn default_parakeet_ja_candidate() -> Option<PathBuf> {
    let p = PathBuf::from(DEFAULT_PARAKEET_JA_SUBDIR);
    p.is_dir().then_some(p)
}

fn default_canary_candidate() -> Option<PathBuf> {
    let p = PathBuf::from(DEFAULT_CANARY_SUBDIR);
    p.is_dir().then_some(p)
}

fn default_paraformer_zh_candidate() -> Option<PathBuf> {
    let p = PathBuf::from(DEFAULT_PARAFORMER_ZH_SUBDIR);
    p.is_dir().then_some(p)
}

fn default_sensevoice_candidate() -> Option<PathBuf> {
    let p = PathBuf::from(DEFAULT_SENSEVOICE_SUBDIR);
    p.is_dir().then_some(p)
}

fn default_dolphin_ko_candidate() -> Option<PathBuf> {
    let p = PathBuf::from(DEFAULT_DOLPHIN_KO_SUBDIR);
    p.is_dir().then_some(p)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

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

    #[test]
    fn resolve_parakeet_dir_requires_bundle_files() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("typwrtr-parakeet-{stamp}"));
        fs::create_dir_all(&dir).unwrap();
        let err = resolve_parakeet_dir(&dir).expect_err("empty dir should fail");
        assert!(err.message().contains("missing"), "{}", err.message());

        for name in [
            "encoder-model.onnx",
            "encoder-model.onnx.data",
            "decoder_joint-model.onnx",
            "vocab.txt",
        ] {
            fs::write(dir.join(name), b"x").unwrap();
        }
        let ok = resolve_parakeet_dir(&dir).expect("complete bundle");
        assert_eq!(ok, dir);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn resolve_canary_accepts_int8() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("typwrtr-canary-{stamp}"));
        fs::create_dir_all(&dir).unwrap();
        for name in [
            "encoder-model.int8.onnx",
            "decoder-model.int8.onnx",
            "vocab.txt",
        ] {
            fs::write(dir.join(name), b"x").unwrap();
        }
        let ok = resolve_canary_dir(&dir).expect("int8 bundle");
        assert!(canary_uses_int8(&ok));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn resolve_dolphin_ko_requires_model_and_tokens() {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("typwrtr-dolphin-{stamp}"));
        fs::create_dir_all(&dir).unwrap();
        let err = resolve_dolphin_ko_dir(&dir).expect_err("empty dir should fail");
        assert!(err.message().contains("missing"), "{}", err.message());

        fs::write(dir.join("model.int8.onnx"), b"x").unwrap();
        fs::write(dir.join("tokens.txt"), b"<blank> 0\n").unwrap();
        let ok = resolve_dolphin_ko_dir(&dir).expect("complete bundle");
        assert_eq!(ok, dir);
        let _ = fs::remove_dir_all(&dir);
    }
}
