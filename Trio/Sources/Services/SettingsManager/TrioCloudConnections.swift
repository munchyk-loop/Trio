import CryptoKit
import Foundation

/// Service accounts travel only in private CloudKit payloads, never in exported JSON.
struct TrioCloudConnections: Codable {
    struct Nightscout: Codable {
        let url: String
        let secret: String
        let uploadEnabled: Bool
        let downloadEnabled: Bool
    }

    var nightscout: Nightscout?
    var tidepoolSession: Data?

    func fingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        if let nightscout {
            guard let url = URL(string: nightscout.url), let host = url.host, !host.isEmpty,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, nightscout.secret.count <= 4096
            else { throw BackupError.invalidCloudRecord }
        }
        guard (tidepoolSession?.count ?? 0) <= 64 * 1024 else { throw BackupError.invalidCloudRecord }
    }
}

/// Reuses the encrypted snapshot field, so no CloudKit schema deployment is needed.
struct TrioCloudBackupPayload: Codable {
    let version: Int
    let settings: TrioSettingsBackup
    let connections: TrioCloudConnections?
    let connectionsChecksum: String?
    init(_ snapshot: TrioSettingsBackup) throws {
        version = 2
        settings = snapshot
        connections = snapshot.cloudConnections
        connectionsChecksum = try connections?.fingerprint()
    }

    func snapshot() throws -> TrioSettingsBackup {
        guard version == 2 else { throw BackupError.unsupportedSchema }
        var value = try settings.validated()
        try connections?.validate()
        let expected = try connections?.fingerprint()
        guard connectionsChecksum == expected else {
            throw BackupError.integrityCheckFailed
        }
        value.cloudConnections = connections
        return value
    }
}
