import Foundation
import os.log

/// Le helper écrit aussi dans le journal système, visible pendant l'opération.
/// L'app conserve ensuite les événements dans son dossier utilisateur (jamais
/// d'écriture root dans un chemin fourni par l'utilisateur).
final class ConnectionTrace {
    private let lock = NSLock()
    private var messages: [String] = []
    private let log = OSLog(subsystem: "fr.sncf.wifi-widget", category: "Connection")

    func record(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)"
        lock.lock()
        messages.append(line)
        lock.unlock()
        os_log("%{public}@", log: log, type: .default, line)
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

enum ConnectionLog {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SNCFWifi/connection.log")
    }
    private static let lock = NSLock()

    static func append(_ lines: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let file = fileURL
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let size = attributes[.size] as? NSNumber, size.intValue > 1_000_000 {
                let previous = file.deletingPathExtension().appendingPathExtension("previous.log")
                try? FileManager.default.removeItem(at: previous)
                try FileManager.default.moveItem(at: file, to: previous)
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        } catch {
            NSLog("Journal de connexion : %@", error.localizedDescription)
        }
    }
}
