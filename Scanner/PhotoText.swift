//
//  PhotoText.swift
//  Scanner
//
//  Created by Mikel on 11/8/26.
//


import SwiftUI
import Vision
 
// MARK: - Model type
 
struct PhotoText: Identifiable, Sendable {
    let id = UUID()
    let index: Int          // 1-based photo number
    let text: String
}
 
// MARK: - OCR
 
enum TextRecognizer {
 
    /// Reads the text in every photo, off the main thread. Results keep photo order.
    static func recognize(_ photos: [Data]) async -> [PhotoText] {
        await Task.detached(priority: .userInitiated) {
            photos.enumerated().map { offset, data in
                PhotoText(index: offset + 1, text: recognizeText(in: data))
            }
        }.value
    }
 
    nonisolated private static func recognizeText(in data: Data) -> String {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else { return "" }
 
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
 
        // cgImage ignores UIImage's orientation, so pass it to Vision explicitly.
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
 
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
 
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
 
struct FirstLastWords {
    let first: String
    let last: String
}

struct SOData {
    let SONum: String
    let type: String
    let orderQt: Int
}
 



struct PhotoTextResultsView: View {
    let items: [PhotoText]
 
    @State private var processed: [Int: [String]] = [:]   // words per photo, keyed by photo index
    @State private var hasProcessed = false
    @State private var isSending = false
    @State private var didSend = false
    @State private var sendStatus: String?
    @Environment(\.dismiss) private var dismiss
 
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Photo \(item.index)")
                                .font(.headline)
 
                            if hasProcessed {
                                if let words = processed[item.index] {
                                    Text(words.joined(separator: "\n"))
                                        .textSelection(.enabled)
                                } else {
                                    Text("No matching lines")
                                        .foregroundStyle(.secondary)
                                }
                            } else if item.text.isEmpty {
                                Text("No text found")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(item.text)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle("Text found")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if hasProcessed {
                    VStack(spacing: 6) {
                        if let sendStatus {
                            Text(sendStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button { sendToSheet() } label: {
                            if isSending {
                                ProgressView()
                            } else {
                                Label(didSend ? "Sent" : "Send to Sheet",
                                      systemImage: didSend ? "checkmark" : "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSending || didSend)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {      // left
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {      // right
                    Button("Process") { process() }
                }
            }
        }
    }
 
    // MARK: Processing
 
    // MARK: Google Sheet
 
    /// One row per photo: SO number -> C, line type -> D, order quantity -> E.
    private func buildRows() -> [SheetRow] {
        items.compactMap { item in
            let lines = processed[item.index] ?? []
            let so = lines.first {
                $0.range(of: #"SO\s*\d{8}"#, options: [.regularExpression, .caseInsensitive]) != nil
            } ?? ""
            let qty = quantity(from: lines)
            let option = lineOption(from: lines)
 
            if so.isEmpty && qty.isEmpty && option.isEmpty { return nil }
            return SheetRow(so: so, option: option, qty: qty)
        }
    }
 
    /// "Total Order Qt. 24" -> "24"
    private func quantity(from lines: [String]) -> String {
        guard let line = lines.first(where: { $0.localizedCaseInsensitiveContains("Total Order Qt.") }) else {
            return ""
        }
        let rest = line.replacingOccurrences(of: "Total Order Qt.", with: "", options: .caseInsensitive)
        guard let range = rest.range(of: #"\d[\d,]*"#, options: .regularExpression) else { return "" }
        return rest[range].replacingOccurrences(of: ",", with: "")
    }
 
    /// Picks the Column D dropdown value:
    /// - a "monogram" line            -> "Monogram"
    /// - a "text" line, then the Emma line "_X_Y_Emma":
    ///       X only  -> "1 Line",  X and Y -> "2 Line"
    private func lineOption(from lines: [String]) -> String {
        if lines.contains(where: { $0.localizedCaseInsensitiveContains("monogram") }) {
            return "Monogram"
        }
 
        let hasTextLine = lines.contains {
            !$0.localizedCaseInsensitiveContains("Emma") && $0.localizedCaseInsensitiveContains("text")
        }
        guard hasTextLine,
              let emmaLine = lines.first(where: { $0.localizedCaseInsensitiveContains("Emma") }),
              let start = emmaLine.firstIndex(of: "_") else { return "" }
 
        // "_X_Y_Emma" -> ["X", "Y", "Emma"] -> drop "Emma" -> count what's left
        var parts = emmaLine[start...]
            .split(separator: "_")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let last = parts.last, last.localizedCaseInsensitiveContains("Emma") {
            parts.removeLast()
        }
 
        switch parts.count {
        case 0:  return ""
        case 1:  return "1 Line"
        default: return "2 Line"
        }
    }
 
    private func sendToSheet() {
        let rows = buildRows()
        guard !rows.isEmpty else {
            sendStatus = "Nothing to send."
            return
        }
        isSending = true
        sendStatus = nil
 
        Task {
            do {
                try await SheetUploader.send(rows)
                didSend = true
                sendStatus = "Sent \(rows.count) row\(rows.count == 1 ? "" : "s") to the sheet."
            } catch {
                sendStatus = "Couldn't send: \(error.localizedDescription)"
            }
            isSending = false
        }
    }
 
    // MARK: Filter rules (edit these)
 
    /// A line is kept if it contains any of these (case-insensitive).
    private let keywords = ["Emma", "Blanket", "text", "monogram", "Total Order Qt."]
 
    /// A line is also kept if it matches any of these regular expressions.
    /// "OH: SO" followed by 8 digits (spaces after "OH:" and "SO" are tolerated).
    private let patterns = [#"OH:\s*SO\s*\d{8}"#]
 
    private func shouldKeep(_ line: String) -> Bool {
        if keywords.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return patterns.contains { pattern in
            line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
 
    /// Tidies a kept line before it is shown.
    private func clean(_ line: String) -> String {
        // "Emma's Blanket 30x40" -> "Blanket" (keep only the word itself)
        if let range = line.range(of: "Blanket", options: .caseInsensitive) {
            return String(line[range])
        }
 
        var result = line
 
        // "... Total Order Qt. 24" -> "Total Order Qt. 24" (drop everything before it)
        if let range = result.range(of: "Total Order Qt.", options: .caseInsensitive) {
            result = String(result[range.lowerBound...])
        }
 
        // "OH: SO12345678" -> "SO12345678" (drop only the "OH: " part)
        result = result.replacingOccurrences(
            of: #"OH:\s*(?=SO\s*\d{8})"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
 
        return result.trimmingCharacters(in: .whitespaces)
    }
 
    /// Keeps only the lines that match the rules above.
    private func process() {
        var results: [Int: [String]] = [:]
 
        for item in items {
            let lines = item.text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter(shouldKeep)
                .map(clean)
            if !lines.isEmpty {
                results[item.index] = lines
            }
        }
 
        processed = results
        hasProcessed = true
        didSend = false
        sendStatus = nil
    }
}
 
 
 
extension CGImagePropertyOrientation {
    nonisolated init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up:            self = .up
        case .upMirrored:    self = .upMirrored
        case .down:          self = .down
        case .downMirrored:  self = .downMirrored
        case .left:          self = .left
        case .leftMirrored:  self = .leftMirrored
        case .right:         self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default:    self = .up
        }
    }
}
