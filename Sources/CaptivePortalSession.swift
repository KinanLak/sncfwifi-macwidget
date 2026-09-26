import Foundation
import SystemConfiguration
import SystemConfiguration.CaptiveNetwork

struct PortalSessionReport: Codable {
    var macOutput = ""
    var connected = false
    var error: String?
    var events: [String] = []
}

/// Enregistre temporairement ce processus comme gestionnaire de connexion des
/// SSID SNCF. L'API macOS supprime la Web Sheet pour ces réseaux ; l'inscription
/// disparaît aussi à la sortie du processus, même en cas d'arrêt inattendu.
/// Ne pas écrire `com.apple.captive.control/Active` : ce réglage n'est lu qu'au
/// démarrage du service sur les versions récentes de macOS.
final class CaptivePortalControl {
    private var suppressed = false
    private let register: ([String]) -> Bool
    private let markOnline: () -> Bool

    init(register: @escaping ([String]) -> Bool = { CNSetSupportedSSIDs($0 as CFArray) },
         markOnline: @escaping () -> Bool = { CNMarkPortalOnline("en0" as CFString) }) {
        self.register = register
        self.markOnline = markOnline
    }

    func suppress() throws {
        guard register(CaptivePortalSession.knownSSIDs) else {
            throw PortalError.message("macOS n'a pas accepté la prise en charge du portail SNCF par l'app.")
        }
        suppressed = true
    }

    func restore(online: Bool = false) throws {
        guard suppressed else { return }
        // Annoncer le résultat avant de rendre la main à macOS : sinon il peut
        // encore croire le réseau captif au moment où l'inscription disparaît.
        let notified = !online || markOnline()
        let released = register([])
        suppressed = false
        guard notified, released else {
            throw PortalError.message("macOS n'a pas confirmé la libération de la prise en charge du portail captif.")
        }
    }
}

/// Même exécutable, mode CLI lancé avec les droits administrateur avant toute
/// initialisation AppKit : une autorisation pour toute la reconnexion.
enum CaptivePortalSession {
    static let argument = "--sncf-reconnect"
    static let reportPrefix = "SNCF_PORTAL_REPORT="
    static let knownSSIDs = ["_SNCF_WIFI_INOUI", "OUIFI", "SNCF_WIFI_INTERCITES", "WIFI_SNCF"]

    static func run(spoofy: String, path: String, ssid: String?) -> PortalSessionReport {
        var report = PortalSessionReport()
        let trace = ConnectionTrace()
        trace.record("Début reconnexion SNCF")
        let client = SNCFPortalClient(trace: trace.record)
        defer { client.close() }
        var control: CaptivePortalControl?
        do {
            guard geteuid() == 0 else { throw PortalError.message("Cette action nécessite les droits administrateur.") }
            // Valider le réseau AVANT de désactiver CNA ou modifier une adresse.
            _ = try client.statusOrUnregistered()
            control = CaptivePortalControl()
            try control?.suppress()
            trace.record("Prise en charge du portail captif enregistrée")

            let script = MACAddressClient.verificationScript(executable: spoofy, path: path, rotate: true, before: nil)
            report.macOutput = try runCommand("/bin/sh", ["-c", script], timeout: 60)
            trace.record("Rotation terminée : \(report.macOutput.replacingOccurrences(of: "\n", with: " ; "))")
            try client.connect(rejoin: {
                // spoofy peut laisser en0 désassociée. Rejoindre le SSID courant si
                // disponible, sinon les réseaux SNCF mémorisés (aucun mot de passe).
                let candidates: [String]
                if let ssid, knownSSIDs.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
                    candidates = [ssid]
                } else {
                    let preferred = (try? runCommand("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", "en0"])) ?? ""
                    let saved = preferred.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { name in knownSSIDs.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
                    candidates = saved.isEmpty ? [knownSSIDs[0]] : saved
                }
                for candidate in candidates {
                    trace.record("Réassociation à un réseau SNCF mémorisé")
                    _ = try? runCommand("/usr/sbin/networksetup", ["-setairportnetwork", "en0", candidate], timeout: 12)
                    if (try? client.status()) != nil { break }
                }
            })
            report.connected = true
        } catch {
            report.error = error.localizedDescription
            trace.record("Erreur : \(error.localizedDescription)")
        }
        // Y compris en cas d'échec de spoofy, du DHCP, de l'API ou du test Internet.
        do { try control?.restore(online: report.connected) }
        catch { report.error = [report.error, error.localizedDescription].compactMap { $0 }.joined(separator: " ") }
        trace.record("Fin : connected=\(report.connected), erreur=\(report.error ?? "aucune")")
        report.events = trace.events
        return report
    }

    static func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let timer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw PortalError.message(output.isEmpty ? "La commande \(URL(fileURLWithPath: executable).lastPathComponent) a échoué." : output)
        }
        return output
    }
}
