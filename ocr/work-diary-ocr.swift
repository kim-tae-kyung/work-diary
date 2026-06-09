// work-diary-ocr — on-device OCR helper for work-diary-capture.
//
// Reads ONE image file and prints the recognized text as a JSON array, one entry per text
// observation: [{"t": <string>, "h": <normalized box height 0..1>, "c": <confidence 0..1>}, ...].
// The caller ranks by "h" (taller box = larger font = titles/app names/headings) and keeps the
// most prominent lines, so the vision model can ground its summary in real on-screen text instead
// of guessing. Operates on an image file in-process, so it needs no Screen Recording permission.
//
// Apple Vision (VNRecognizeTextRequest). Build: swiftc -O -o work-diary-ocr work-diary-ocr.swift
// Usage: work-diary-ocr [--lang ko-KR,en-US] <image-path>
// On any failure it prints "[]" and exits 0 — OCR is best-effort; the pipeline falls back to
// vision-only. Standard-library/system-framework only; no third-party dependencies.

import Foundation
import Vision
import ImageIO
import CoreGraphics

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func recognize(_ cg: CGImage, langs: [String]) -> [[String: Any]] {
    // Run once with the requested languages; if that throws (e.g. an unsupported language on this
    // OS), retry with Vision's defaults so OCR still returns something.
    func run(setLangs: Bool) throws -> [[String: Any]] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        if setLangs && !langs.isEmpty {
            req.recognitionLanguages = langs
        }
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        var out: [[String: Any]] = []
        for obs in (req.results ?? []) {
            guard let top = obs.topCandidates(1).first else { continue }
            out.append(["t": top.string, "h": Double(obs.boundingBox.height), "c": Double(top.confidence)])
        }
        return out
    }
    if let r = try? run(setLangs: true) { return r }
    return (try? run(setLangs: false)) ?? []
}

// ── main ──
var langs: [String] = []
var paths: [String] = []
var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    if argv[i] == "--lang", i + 1 < argv.count {
        langs = argv[i + 1].split(separator: ",").map(String.init)
        i += 2
    } else {
        paths.append(argv[i])
        i += 1
    }
}

func emit(_ items: [[String: Any]]) {
    if let data = try? JSONSerialization.data(withJSONObject: items, options: []) {
        FileHandle.standardOutput.write(data)
    } else {
        FileHandle.standardOutput.write(Data("[]".utf8))
    }
}

guard let path = paths.first, let cg = loadCGImage(path) else {
    emit([])
    exit(0)
}
emit(recognize(cg, langs: langs))
