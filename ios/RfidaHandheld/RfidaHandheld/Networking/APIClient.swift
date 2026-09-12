import Foundation

enum APIError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case server(status: Int, message: String?)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "後台伺服器網址未設定或格式錯誤,請到「設定」檢查。"
        case .invalidResponse: return "伺服器回應格式錯誤。"
        case .server(let status, let message): return "伺服器錯誤(\(status)):\(message ?? "未知錯誤")"
        case .decoding: return "資料解析失敗。"
        case .transport(let error): return "網絡連線失敗:\(error.localizedDescription)"
        }
    }
}

private struct EmptyResponse: Decodable {}

/// 對接 Flask + SQLite 後台伺服器(方案書4.2:業務邏輯一律經WiFi打去後台,
/// BLE淨係負責傳送EPC)。API路徑為建議合約,實際後台實作時可對照 docs/API_CONTRACT.md 調整。
actor APIClient {
    static let shared = APIClient()

    private let session = URLSession(configuration: .default)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var baseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: SettingsKey.backendBaseURL),
              let url = URL(string: raw) else { return nil }
        return url
    }

    /// 示範模式(設定內嘅開關):開啟後所有API改用 DemoDataProvider 嘅假資料,
    /// 唔會發出任何網絡請求,方便冇後台伺服器/冇實機都可以完整示範。
    private var isDemoMode: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.demoMode)
    }

    func fetchEquipment() async throws -> [Equipment] {
        if isDemoMode { return await DemoDataProvider.shared.fetchEquipment() }
        return try await get("/api/equipment")
    }

    func fetchStaff() async throws -> [Staff] {
        if isDemoMode { return await DemoDataProvider.shared.fetchStaff() }
        return try await get("/api/staff")
    }

    func fetchOpenJobs() async throws -> [Job] {
        if isDemoMode { return await DemoDataProvider.shared.fetchOpenJobs() }
        return try await get("/api/jobs?status=open")
    }

    /// 情景3(返office前清點)用:取得某個Job出Job時嘅「應有清單」,俾App做清單比對。
    func fetchExpectedItems(jobId: Int) async throws -> [MovementItem] {
        if isDemoMode { return await DemoDataProvider.shared.fetchExpectedItems(jobId: jobId) }
        return try await get("/api/jobs/\(jobId)/expected-items")
    }

    /// 情景1(錄入新標籤):將EPC同器材資料配對登記。
    func registerTag(epc: String, name: String, category: String, serialNumber: String?) async throws -> Equipment {
        if isDemoMode {
            return await DemoDataProvider.shared.registerTag(epc: epc, name: name, category: category, serialNumber: serialNumber)
        }
        struct Body: Encodable {
            var epc: String
            var name: String
            var category: String
            var serialNumber: String?
        }
        return try await post("/api/equipment/register", body: Body(epc: epc, name: name, category: category, serialNumber: serialNumber))
    }

    /// 情景2(出發前登記)/ 情景3(返office前清點)共用:提交出/入紀錄。
    func submitMovement(_ submission: MovementSubmission) async throws {
        if isDemoMode { return await DemoDataProvider.shared.submitMovement(submission) }
        let _: EmptyResponse = try await post("/api/movements", body: submission)
    }

    /// 情景4(定期盤點):提交一個盤點批次嘅結果。
    func submitInventory(_ submission: InventorySubmission) async throws {
        if isDemoMode { return await DemoDataProvider.shared.submitInventory(submission) }
        let _: EmptyResponse = try await post("/api/inventory-sessions", body: submission)
    }

    // MARK: - Core

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let baseURL else { throw APIError.invalidBaseURL }
        let request = try buildRequest(base: baseURL, path: path)
        return try await perform(request)
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        guard let baseURL else { throw APIError.invalidBaseURL }
        var request = try buildRequest(base: baseURL, path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await perform(request)
    }

    private func buildRequest(base: URL, path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: base) else { throw APIError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: http.statusCode, message: String(data: data, encoding: .utf8))
        }

        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
