import Foundation

private let driveUploadUrl = "https://www.googleapis.com/upload/drive/v3/files"

enum DriveChunkResult {
    case incomplete(next: Int64)
    case complete(fileId: String)
}

private struct DriveFile: Decodable {
    let id: String
}

private struct DriveFileList: Decodable {
    let files: [DriveFile]
}

final class DriveApi: Sendable {
    private let wifiSession = daysSession(allowCellular: false, resource: 900)
    private let anySession = daysSession(allowCellular: true, resource: 900)

    private var session: URLSession {
        DaysPrefs.isWifiOnly ? wifiSession : anySession
    }

    private func send(_ request: URLRequest, body: Data?) async throws -> (HTTPURLResponse, Data) {
        var request = request
        request.setValue("Bearer \(try await driveAuth.accessToken())", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = if let body {
                try await session.upload(for: request, from: body)
            } else {
                try await session.data(for: request)
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
        switch response.statusCode {
        case 401:
            driveAuth.invalidateAccessToken()
            throw DriveError.retryable("http 401")
        case 404, 410:
            throw DriveError.sessionGone
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
                  total: Int64?) async throws -> DriveChunkResult
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
        let (response, responseData) = try await send(request, body: data)
        return try parseChunkResponse(response, responseData)
    }

    func queryStatus(uploadUrl: String, total: Int64?) async throws -> DriveChunkResult {
        try await putChunk(uploadUrl: uploadUrl, data: Data(), offset: 0, total: total)
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
        let boundary = "dais\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "\(driveUploadUrl)?uploadType=multipart&fields=id")!)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let metadata = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "parents": [folderId],
            "mimeType": "application/json",
        ])
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(content)
        body.append(Data("\r\n--\(boundary)--".utf8))
        let (response, data) = try await send(request, body: body)
        try check(response, data, ok: [200, 201])
        return try JSONDecoder().decode(DriveFile.self, from: data).id
    }

    func updateJson(fileId: String, content: Data) async throws {
        var request = URLRequest(url: URL(string: "\(driveUploadUrl)/\(fileId)?uploadType=media")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (response, data) = try await send(request, body: content)
        try check(response, data, ok: [200])
    }
}
