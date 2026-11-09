//
//  SheetUploader.swift
//  Scanner
//
//  Created by Mikel on 11/8/26.
//


import Foundation
import GoogleSignIn
import UIKit

struct SheetRow: Codable, Sendable {
    let so: String      // goes in column C
    let option: String
    let qty: String     // goes in column E
}

enum SheetError: LocalizedError {
    case noWindow
    case notSignedIn
    case badResponse
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .noWindow:           return "Couldn't show the Google sign-in screen."
        case .notSignedIn:        return "Google sign-in didn't complete."
        case .badResponse:        return "Unexpected response from Google."
        case .api(let code, let message): return "Google Sheets error \(code): \(message)"
        }
    }
}

@MainActor
enum SheetUploader {

    // MARK: Configuration (fill these in)

    /// iOS OAuth client ID from Google Cloud Console (ends in .apps.googleusercontent.com)
    static let clientID = "198589844416-na7b6afajcb38ncrdcmtqddduv7s5k9f.apps.googleusercontent.com"
    static let spreadsheetID = "1567HDar-cXrHJkd3Jb1WPt6V7xLviQyPVi3w6DrterQ"
    static let sheetName = "Sheet1"        // the tab name
    static let firstRow = 2                // first data row (use 1 if there is no header)

    private static let scope = "https://www.googleapis.com/auth/spreadsheets"

    // MARK: Public

 
    /// Writes each row's SO number to column C and Order Qt. to column E,
    /// in the first rows where both C and E are empty.
    static func send(_ rows: [SheetRow]) async throws {
        let token = try await accessToken()
        let slots = try await findEmptyRows(count: rows.count, token: token)
        try await write(rows, to: slots, token: token)

        // Mark where this batch starts: the first row that has an SO number.
        // Best effort: the data is already saved, so a formatting failure isn't an error.
        if let firstSORow = zip(rows, slots).first(where: { !$0.0.so.isEmpty })?.1 {
            try? await highlight(row: firstSORow, token: token)
        }
    }
 
    static func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }
 
    // MARK: Sign-in
 
    private static func accessToken() async throws -> String {
        let signIn = GIDSignIn.sharedInstance
        signIn.configuration = GIDConfiguration(clientID: clientID)
 
        var user = signIn.currentUser
        if user == nil, signIn.hasPreviousSignIn() {
            user = try? await signIn.restorePreviousSignIn()
        }
        if user == nil {
            guard let presenter = topViewController() else { throw SheetError.noWindow }
            let result = try await signIn.signIn(withPresenting: presenter,
                                                 hint: nil,
                                                 additionalScopes: [scope])
            user = result.user
        }
        guard var current = user else { throw SheetError.notSignedIn }
 
        // Make sure the Sheets scope was granted (e.g. user signed in before it was added).
        if !(current.grantedScopes ?? []).contains(scope) {
            guard let presenter = topViewController() else { throw SheetError.noWindow }
            let result = try await current.addScopes([scope], presenting: presenter)
            current = result.user
        }
 
        current = try await current.refreshTokensIfNeeded()
        return current.accessToken.tokenString
    }
 
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
 
    // MARK: Sheets REST calls
 
    private static var quotedSheet: String {
        "'" + sheetName.replacingOccurrences(of: "'", with: "''") + "'"
    }
 
    private static var baseURL: String {
        "https://sheets.googleapis.com/v4/spreadsheets/\(spreadsheetID)"
    }
 
    private struct ValuesResponse: Decodable { let values: [[String]]? }
    private struct ValueRange: Encodable { let range: String; let values: [[String]] }
    private struct BatchBody: Encodable { let valueInputOption: String; let data: [ValueRange] }
    private struct APIError: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }
 
    /// Reads columns C:E and returns the first `count` row numbers where C and E are both empty.
    private static func findEmptyRows(count: Int, token: String) async throws -> [Int] {
        let range = "\(quotedSheet)!C:E"
        guard let encoded = range.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/values/\(encoded)") else {
            throw SheetError.badResponse
        }
 
        let data = try await call(url, method: "GET", body: nil, token: token)
        let existing = try JSONDecoder().decode(ValuesResponse.self, from: data).values ?? []
 
        var slots: [Int] = []
        var row = firstRow
        while slots.count < count {
            // `existing` starts at row 1; trailing empty rows are not returned.
            let cells = row - 1 < existing.count ? existing[row - 1] : []
            let c = cells.indices.contains(0) ? cells[0] : ""
            let e = cells.indices.contains(2) ? cells[2] : ""
            if c.trimmingCharacters(in: .whitespaces).isEmpty,
               e.trimmingCharacters(in: .whitespaces).isEmpty {
                slots.append(row)
            }
            row += 1
        }
        return slots
    }
 
    /// Writes columns B (date), C, D and E of each slot row; everything else is untouched.
    private static func write(_ rows: [SheetRow], to slots: [Int], token: String) async throws {
        // Date entered, e.g. "2026-11-08" (Sheets reads this as a date with USER_ENTERED)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
 
        var data: [ValueRange] = []
        for (row, slot) in zip(rows, slots) {
            data.append(ValueRange(range: "\(quotedSheet)!B\(slot)", values: [[today]]))
            if !row.so.isEmpty     { data.append(ValueRange(range: "\(quotedSheet)!C\(slot)", values: [[row.so]])) }
            if !row.option.isEmpty { data.append(ValueRange(range: "\(quotedSheet)!D\(slot)", values: [[row.option]])) }
            if !row.qty.isEmpty    { data.append(ValueRange(range: "\(quotedSheet)!E\(slot)", values: [[row.qty]])) }
        }
        guard !data.isEmpty, let url = URL(string: "\(baseURL)/values:batchUpdate") else { return }
 
        let body = try JSONEncoder().encode(BatchBody(valueInputOption: "USER_ENTERED", data: data))
        _ = try await call(url, method: "POST", body: body, token: token)
    }
 
    // MARK: Formatting

    private struct SheetsMeta: Decodable {
        struct Sheet: Decodable {
            struct Props: Decodable { let sheetId: Int; let title: String }
            let properties: Props
        }
        let sheets: [Sheet]
    }

    /// Formatting requests need the tab's numeric ID, not its name.
    private static func tabID(token: String) async throws -> Int {
        guard let url = URL(string: "\(baseURL)?fields=sheets.properties(sheetId,title)") else {
            throw SheetError.badResponse
        }
        let data = try await call(url, method: "GET", body: nil, token: token)
        let meta = try JSONDecoder().decode(SheetsMeta.self, from: data)
        guard let match = meta.sheets.first(where: { $0.properties.title == sheetName }) else {
            throw SheetError.api(404, "Tab \"\(sheetName)\" not found")
        }
        return match.properties.sheetId
    }

    /// Colors the Column C cell of `row` green.
    private static func highlight(row: Int, token: String) async throws {
        let tab = try await tabID(token: token)
        let request: [String: Any] = [
            "requests": [[
                "repeatCell": [
                    "range": [
                        "sheetId": tab,
                        "startRowIndex": row - 1,      // zero-based, end exclusive
                        "endRowIndex": row,
                        "startColumnIndex": 2,         // column C
                        "endColumnIndex": 3
                    ],
                    "cell": [
                        "userEnteredFormat": [
                            "backgroundColor": ["red": 0, "green": 1, "blue": 0]
                        ]
                    ],
                    "fields": "userEnteredFormat.backgroundColor"
                ]
            ]]
        ]
        guard let url = URL(string: "\(baseURL):batchUpdate") else { throw SheetError.badResponse }
        let body = try JSONSerialization.data(withJSONObject: request)
        _ = try await call(url, method: "POST", body: body, token: token)
    }
    
    private static func call(_ url: URL, method: String, body: Data?, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
 
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SheetError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message ?? "Request failed"
            throw SheetError.api(http.statusCode, message)
        }
        return data
    }
}
 
