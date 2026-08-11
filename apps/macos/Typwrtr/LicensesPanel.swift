import AppKit

/// Settings → Licenses… — attribution for Typwrtr, euhadra, and downloaded models.
enum LicensesPanel {
    static func runModal() {
        let width: CGFloat = 440
        let height: CGFloat = 420
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Licenses & Attribution"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.center()

        let host = ContentView()
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = host
        // Traffic-light close must end the modal session or the parent Settings
        // (and menu) stay frozen inside `runModal`.
        panel.delegate = host
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.delegate = nil
    }

    fileprivate final class ContentView: NSView, NSWindowDelegate {
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            build()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:)") }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            NSApp.stopModal()
            return true
        }

        private func build() {
            let pad: CGFloat = 14
            let width: CGFloat = 440
            let height: CGFloat = 420
            var y = height - pad

            y -= 28
            let close = NSButton(title: "Close", target: self, action: #selector(closeTapped))
            close.bezelStyle = .rounded
            close.controlSize = .small
            close.frame = NSRect(x: width - pad - 72, y: y, width: 72, height: 24)
            addSubview(close)

            let heading = NSTextField(labelWithString: "Licenses & Attribution")
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            heading.frame = NSRect(x: pad, y: y, width: width - pad * 2 - 80, height: 24)
            addSubview(heading)

            y -= 10
            let textHeight = y - pad
            y -= textHeight

            let scroll = NSScrollView(frame: NSRect(x: pad, y: y, width: width - pad * 2, height: textHeight))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.autohidesScrollers = true

            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 1))
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = true
            text.backgroundColor = .textBackgroundColor
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.font = .systemFont(ofSize: 11)
            text.string = Self.attributionText
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.containerSize = NSSize(
                width: scroll.contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
            scroll.documentView = text
            addSubview(scroll)
        }

        @objc private func closeTapped() {
            NSApp.stopModal()
        }

        /// Informational summary; canonical license texts are linked.
        private static let attributionText = """
        Typwrtr credits the open-source software and model weights it depends on. \
        This summary is not legal advice — follow the linked license texts.

        ── Software ──

        Typwrtr
        Copyright (c) 2026 Kenya Nara (penta2himajin)
        License: MIT
        https://github.com/penta2himajin/typwrtr

        euhadra (ASR pipeline)
        Copyright (c) 2026 Kenya Nara (penta2himajin)
        License: MIT OR Apache-2.0
        https://github.com/penta2himajin/euhadra

        earshot (live voice activity detection; embedded neural net)
        License: MIT OR Apache-2.0
        https://crates.io/crates/earshot

        ort / ONNX Runtime
        License: MIT OR Apache-2.0 (crate); Apache-2.0 (ONNX Runtime)
        https://github.com/pykeio/ort

        UniFFI (Rust ↔ Swift bindings)
        License: MPL-2.0
        https://github.com/mozilla/uniffi-rs

        whisper.cpp (legacy Whisper path)
        License: MIT
        https://github.com/ggerganov/whisper.cpp

        Other Rust crates used by typwrtr-core are primarily MIT and/or Apache-2.0. \
        See Cargo.lock in the Typwrtr repository for the full dependency tree.

        ── Speech model weights (downloaded per language) ──

        Models are not bundled in the app binary; they are fetched when you install \
        a language pack. Redistribution or commercial use still requires the \
        attribution below for the packs you use.

        Japanese — nvidia/parakeet-tdt_ctc-0.6b-ja
        ONNX mirror: sunilmahendrakar/parakeet-tdt-0.6b-ja-onnx
        License: CC BY 4.0
        https://creativecommons.org/licenses/by/4.0/
        https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja

        English / Spanish — nvidia/canary-180m-flash
        ONNX mirror: istupakov/canary-180m-flash-onnx
        License: CC BY 4.0 (commercial use permitted by the model card)
        https://creativecommons.org/licenses/by/4.0/
        https://huggingface.co/nvidia/canary-180m-flash

        Chinese — funasr/Paraformer-large
        License: Apache-2.0 (as declared on the Hugging Face model card)
        https://www.apache.org/licenses/LICENSE-2.0
        https://huggingface.co/funasr/Paraformer-large
        Note: FunASR’s project README also references the FunASR Model License \
        for some pretrained models; this app consumes the HF distribution above.

        Korean (experimental) — DataoceanAI Dolphin small CTC
        ONNX export: csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02
        License: Apache-2.0
        https://www.apache.org/licenses/LICENSE-2.0
        https://github.com/DataoceanAI/Dolphin
        https://huggingface.co/csukuangfj/sherpa-onnx-dolphin-small-ctc-multi-lang-int8-2025-04-02

        Legacy fallback — OpenAI Whisper (ggml-tiny / ggml-tiny.en via whisper.cpp)
        License: Apache-2.0
        https://github.com/openai/whisper
        https://huggingface.co/ggerganov/whisper.cpp

        ── CC BY 4.0 (NVIDIA Parakeet / Canary) ──

        You must give appropriate credit, provide a link to the license, and \
        indicate if changes were made (for example, ONNX / INT8 conversion). \
        See the Creative Commons legal code linked above.
        """
    }
}
