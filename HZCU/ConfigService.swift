import Foundation

struct ConfigRefreshResult {
    let keyProfiles: [KeyProfile]
    let normalizedCookie: String?
}

enum ConfigServiceError: Error, LocalizedError {
    case invalidResponse
    case emptyKeyList
    case malformedPayload

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "后台返回数据异常"
        case .emptyKeyList:
            return "当前账号没有可用门锁配置"
        case .malformedPayload:
            return "后台数据格式错误"
        }
    }
}

final class ConfigService {
    private let session: URLSession
    private let tlsDelegate: ConfigTLSDelegate?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.tlsDelegate = nil
        } else {
            let delegate = ConfigTLSDelegate()
            self.tlsDelegate = delegate
            self.session = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )
        }
    }

    func refresh(loginName: String, cookie: String) async throws -> ConfigRefreshResult {
        let loginURL = "https://csmy.hzcu.edu.cn/csmy/bsframe/business//AppUser!appLogin.do"
        let keyURL = "https://csmy.hzcu.edu.cn/csmy/bsframe/business/AppLockGrant!appPullDownKeyInfoList.do"

        let loginPayload: [String: Any] = ["loginname": loginName]
        let loginJSON = try await post(url: loginURL, headers: buildHeaders(cookie: cookie), body: loginPayload)
        let appInfo = loginJSON["appinfo"] as? [String: Any]
        let updatedCookie = extractCookie(from: loginJSON) ?? normalizedCookie(cookie)

        let keyPayload: [String: Any] = [
            "statusstr": "0;1;2;3;4;5",
            "page": 1,
            "order": "order by keyinfoid desc",
            "rows": 20
        ]
        let keyJSON = try await post(url: keyURL, headers: buildHeaders(cookie: updatedCookie), body: keyPayload)

        guard let result = keyJSON["result"] as? String,
              result.lowercased() == "success" else {
            throw ConfigServiceError.invalidResponse
        }

        guard let list = keyJSON["list"] as? [[String: Any]], !list.isEmpty else {
            throw ConfigServiceError.emptyKeyList
        }

        var profiles: [KeyProfile] = []
        for map in list {
            guard let keyID = map["keyid"] as? String,
                  let bluetoothID = map["bluetoothid"] as? String else {
                continue
            }

            let expire = map["expiretime"] as? String ?? ""
            let create = map["createtime"] as? String ?? ""
            let label = preferredLabel(item: map, appInfo: appInfo, bluetoothID: bluetoothID)
            let hardVersion = map["hardVersion"] as? String ?? "2.1.xy.N18.220428"
            let serverAddress = map["serverAddress"] as? String ?? "csmy.hzcu.edu.cn"

            profiles.append(
                KeyProfile(
                    label: label,
                    keyID: keyID.lowercased(),
                    bluetoothID: bluetoothID,
                    expireTime: expire,
                    createTime: create,
                    hardVersion: hardVersion,
                    adminFlag: toUInt16(map["adminFlag"]),
                    isReverse: toUInt16(map["isReverse"]),
                    delayRestore: toUInt16(map["delayRestore"]),
                    motorOpen: toUInt16(map["motorOpen"]),
                    motorClose: toUInt16(map["motorClose"]),
                    openReverseType: toUInt16(map["openReverseType"]),
                    serverAddress: serverAddress,
                    cookie: updatedCookie
                )
            )
        }

        if profiles.isEmpty {
            throw ConfigServiceError.malformedPayload
        }

        return ConfigRefreshResult(keyProfiles: profiles, normalizedCookie: updatedCookie)
    }

    private func post(url: String, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        guard let endpoint = URL(string: url) else {
            throw ConfigServiceError.invalidResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await requestData(request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw ConfigServiceError.invalidResponse
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw ConfigServiceError.invalidResponse
        }
        return dict
    }

    private func requestData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: ConfigServiceError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }

    private func buildHeaders(cookie: String) -> [String: String] {
        var headers: [String: String] = ["Content-Type": "application/json"]
        let value = normalizedCookie(cookie)
        if !value.isEmpty {
            headers["Cookie"] = "JSESSIONID=\(value)"
        }
        return headers
    }

    private func normalizedCookie(_ cookie: String) -> String {
        let raw = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.replacingOccurrences(of: "JSESSIONID=", with: "", options: [.caseInsensitive])
    }

    private func extractCookie(from dict: [String: Any]) -> String? {
        let candidates = ["jsessionid", "JSESSIONID", "sessionId", "sessionid", "cookie"]
        for key in candidates {
            if let val = dict[key] as? String, !val.isEmpty {
                return normalizedCookie(val)
            }
        }
        return nil
    }

    private func toUInt16(_ raw: Any?) -> UInt16 {
        if let val = raw as? UInt16 { return val }
        if let val = raw as? Int { return UInt16(clamping: val) }
        if let val = raw as? String, let intVal = Int(val) { return UInt16(clamping: intVal) }
        return 0
    }

    private func preferredLabel(item: [String: Any], appInfo: [String: Any]?, bluetoothID: String) -> String {
        let itemRoomCode = nonEmptyString(item["roomcode"])
        let appRoomCode = nonEmptyString(appInfo?["roomcode"])

        let building = nonEmptyString(item["buildingname"]) ?? nonEmptyString(appInfo?["buildingname"])
        let room = itemRoomCode ?? appRoomCode

        let directCandidates: [String?] = [
            nonEmptyString(item["label"]),
            nonEmptyString(item["remark"]),
            nonEmptyString(item["roomname"]),
            itemRoomCode,
            appRoomCode,
            nonEmptyString(item["houseaddress"]),
            nonEmptyString(appInfo?["houseaddress"])
        ]

        if let building, let room {
            return "\(building)-\(room)"
        }

        for candidate in directCandidates {
            if let candidate {
                return candidate
            }
        }

        return bluetoothID
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class ConfigTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }
}
