import Foundation

private let driveUploadUrl = "https://www.googleapis.com/upload/drive/v3/files"

enum DriveChunkResult {
    case incomplete(next: Int64)
    case complete(fileId: String)
}

private final class DriveProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: @Sendable (Int64) -> Void

    init(_ handler: @escaping @Sendable (Int64) -> Void) {
        self.handler = handler
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didSendBodyData _: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend _: Int64)
    {
        handler(totalBytesSent)
    }
}

private struct DriveFile: Decodable {
    let id: String
    let name: String?
}

private struct DriveFileList: Decodable {
    let files: [DriveFile]
}

final class DriveApi: Sendable {
    private let wifiSession = daysSession(allowCellular: false, resource: 1800)
    private let anySession = daysSession(allowCellular: true, resource: 1800)

    private var session: URLSession {
        DaysPrefs.isWifiOnly ? wifiSession : anySession
    }

    private func send(_ request: URLRequest, body: Data?,
                      progress: (@Sendable (Int64) -> Void)? = nil,
                      background: Bool = false,
                      lane: Int = 0) async throws -> (HTTPURLResponse, Data) {
        var request = request
        request.setValue("Bearer \(try await driveAuth.accessToken())", forHTTPHeaderField: "Authorization")
        do {
            let data: Data
            let response: URLResponse
            if let body, background {
                (response, data) = try await DaysBackgroundUploader.shared.upload(
                    request, data: body, lane: lane, wifiOnly: DaysPrefs.isWifiOnly, progress: progress
                )
            } else if let body {
                (data, response) = try await session.upload(
                    for: request, from: body, delegate: progress.map { DriveProgressDelegate($0) }
                )
            } else {
                (data, response) = try await session.data(for: request)
            }
            guard let response = response as? HTTPURLResponse else {
                throw DriveError.retryable("no http response")
            }
            return (response, data)
        } catch let error as DriveError {
            throw error
        } catch {
            throw DriveError.retryable(error.localizedDescription)
        }
    }

    private func check(_ response: HTTPURLResponse, _ data: Data, ok: Set<Int>) throws {
        if ok.contains(response.statusCode) {
            return
        }
        let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
        daysLog("http \(response.statusCode) \(response.url?.path ?? "") \(text.replacingOccurrences(of: "\n", with: " "))")
        switch response.statusCode {
        case 401:
            driveAuth.invalidateAccessToken()
            throw DriveError.retryable("http 401")
        case 404, 410:
            throw DriveError.sessionGone
        case 403 where text.contains("storageQuotaExceeded"):
            throw DriveError.retryable("storageQuotaExceeded")
        case 403, 408, 429, 500 ... 599:
            throw DriveError.retryable("http \(response.statusCode) \(text)")
        default:
            throw DriveError.fatal("http \(response.statusCode) \(text)")
        }
    }

    func userEmail() async -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/about")!
        components.queryItems = [URLQueryItem(name: "fields", value: "user(emailAddress)")]
        guard let (response, data) = try? await send(URLRequest(url: components.url!), body: nil),
              response.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return (object["user"] as? [String: Any])?["emailAddress"] as? String
    }

    func findOrCreateFolder(name: String, parentId: String) async throws -> String {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let query = "mimeType='application/vnd.google-apps.folder' and name='\(name)' "
            + "and '\(parentId)' in parents and trashed=false"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "orderBy", value: "createdTime"),
            URLQueryItem(name: "pageSize", value: "5"),
        ]
        let (response, data) = try await send(URLRequest(url: components.url!), body: nil)
        try check(response, data, ok: [200])
        if let folder = try JSONDecoder().decode(DriveFileList.self, from: data).files.first {
            return folder.id
        }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentId],
        ]
        let body = try JSONSerialization.data(withJSONObject: metadata)
        let (createResponse, createData) = try await send(request, body: body)
        try check(createResponse, createData, ok: [200, 201])
        return try JSONDecoder().decode(DriveFile.self, from: createData).id
    }

    func startResumable(name: String, folderId: String, mimeType: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(driveUploadUrl)?uploadType=resumable&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")
        let metadata: [String: Any] = ["name": name, "parents": [folderId], "mimeType": mimeType]
        let body = try JSONSerialization.data(withJSONObject: metadata)
        let (response, data) = try await send(request, body: body)
        try check(response, data, ok: [200])
        guard let location = response.value(forHTTPHeaderField: "Location") else {
            throw DriveError.retryable("no upload location")
        }
        return location
    }

    func putChunk(uploadUrl: String,
                  data: Data,
                  offset: Int64,
                  total: Int64?,
                  lane: Int = 0,
                  progress: (@Sendable (Int64) -> Void)? = nil) async throws -> DriveChunkResult
    {
        guard let url = URL(string: uploadUrl) else {
            throw DriveError.sessionGone
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let totalString = total.map { String($0) } ?? "*"
        if data.isEmpty {
            request.setValue("bytes */\(totalString)", forHTTPHeaderField: "Content-Range")
        } else {
            let last = offset + Int64(data.count) - 1
            request.setValue("bytes \(offset)-\(last)/\(totalString)", forHTTPHeaderField: "Content-Range")
        }
        let (response, responseData) = try await send(request, body: data, progress: progress, background: true, lane: lane)
        return try parseChunkResponse(response, responseData)
    }

    func queryStatus(uploadUrl: String, total: Int64?, lane: Int = 0) async throws -> DriveChunkResult {
        try await putChunk(uploadUrl: uploadUrl, data: Data(), offset: 0, total: total, lane: lane)
    }

    private func parseChunkResponse(_ response: HTTPURLResponse, _ data: Data) throws -> DriveChunkResult {
        if response.statusCode == 308 {
            guard let range = response.value(forHTTPHeaderField: "Range"),
                  let last = range.split(separator: "-").last,
                  let last = Int64(last)
            else {
                return .incomplete(next: 0)
            }
            return .incomplete(next: last + 1)
        }
        try check(response, data, ok: [200, 201])
        return .complete(fileId: try JSONDecoder().decode(DriveFile.self, from: data).id)
    }

    func createJson(name: String, folderId: String, content: Data) async throws -> String {
        try await createFile(name: name, folderId: folderId, content: content, mimeType: "application/json")
    }

    func createFile(name: String, folderId: String, content: Data, mimeType: String) async throws -> String {
        let boundary = "dais\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "\(driveUploadUrl)?uploadType=multipart&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let metadata = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "parents": [folderId],
            "mimeType": mimeType,
        ])
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(content)
        body.append(Data("\r\n--\(boundary)--".utf8))
        let (response, data) = try await send(request, body: body)
        try check(response, data, ok: [200, 201])
        return try JSONDecoder().decode(DriveFile.self, from: data).id
    }

    func updateJson(fileId: String, content: Data) async throws {
        try await updateMedia(fileId: fileId, content: content, mimeType: "application/json")
    }

    func updateMedia(fileId: String, content: Data, mimeType: String) async throws {
        var request = URLRequest(url: URL(string: "\(driveUploadUrl)/\(fileId)?uploadType=media")!)
        request.httpMethod = "PATCH"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let (response, data) = try await send(request, body: content)
        try check(response, data, ok: [200])
    }

    func findFile(name: String, folderId: String) async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let query = "name='\(name)' and '\(folderId)' in parents and trashed=false"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "orderBy", value: "createdTime"),
            URLQueryItem(name: "pageSize", value: "5"),
        ]
        let (response, data) = try await send(URLRequest(url: components.url!), body: nil)
        try check(response, data, ok: [200])
        return try JSONDecoder().decode(DriveFileList.self, from: data).files.first?.id
    }

    func listFiles(prefix: String, folderId: String) async throws -> [(id: String, name: String)] {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let query = "name contains '\(prefix)' and '\(folderId)' in parents and trashed=false"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "50"),
        ]
        let (response, data) = try await send(URLRequest(url: components.url!), body: nil)
        try check(response, data, ok: [200])
        return try JSONDecoder().decode(DriveFileList.self, from: data).files.compactMap { file in
            file.name.flatMap { $0.hasPrefix(prefix) ? (file.id, $0) : nil }
        }
    }

    func findAnywhere(name: String) async throws -> (id: String, size: Int64)? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "name='\(name)' and trashed=false"),
            URLQueryItem(name: "fields", value: "files(id,size)"),
            URLQueryItem(name: "pageSize", value: "5"),
        ]
        let (response, data) = try await send(URLRequest(url: components.url!), body: nil)
        try check(response, data, ok: [200])
        let files = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["files"] as? [[String: Any]] ?? []
        return files.compactMap { file in
            (file["id"] as? String).map { ($0, Int64(file["size"] as? String ?? "") ?? 0) }
        }.max { $0.1 < $1.1 }
    }

    func downloadMedia(fileId: String) async throws -> Data {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!
        let (response, data) = try await send(URLRequest(url: url), body: nil)
        try check(response, data, ok: [200])
        return data
    }
}
