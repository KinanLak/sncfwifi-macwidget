import Foundation

/// Lance spoofy hors du thread UI ; l'élévation couvre la rotation et sa lecture et
/// passe par la boîte de dialogue administrateur de macOS (aucun mot de passe stocké).
final class MACAddressClient {
    enum Result {
        case changed(from: String, to: String)
        case observed(String)
        case pending
        case failed(String)
    }

    enum Verification: Equatable {
        case changed(String)
        case observed(String)
        case unchanged
        case inconclusive
    }

    private struct Command {
        let executable: String
        let path: String
    }

    private let queue = DispatchQueue(label: "fr.sncf.wifi-widget.mac")
    private var pendingCommand: Command?
    private var pendingBefore: String?

    func rotate(completion: @escaping (Result) -> Void) {
        queue.async {
            let result = self.rotateOnBackgroundQueue()
            DispatchQueue.main.async { completion(result) }
        }
    }

    func rotateAndConnect(ssid: String?, completion: @escaping (Result, PortalSessionReport) -> Void) {
        queue.async {
            ConnectionLog.append(["\(ISO8601DateFormatter().string(from: Date())) Demande de reconnexion SNCF"])
            do {
                let command = try self.locateSpoofy()
                guard let executable = Bundle.main.executableURL?.path else {
                    throw PortalError.message("Exécutable de l'app introuvable.")
                }
                self.pendingCommand = nil
                self.pendingBefore = nil
                let shell = [executable, CaptivePortalSession.argument, command.executable, command.path, ssid ?? ""]
                    .map(Self.shellQuote).joined(separator: " ")
                let script = "with timeout of 240 seconds\ndo shell script \"\(self.appleScriptQuote(shell))\" with administrator privileges\nend timeout"
                let output = try self.run("/usr/bin/osascript", ["-e", script], path: command.path)
                guard let line = output.components(separatedBy: .newlines).first(where: { $0.hasPrefix(CaptivePortalSession.reportPrefix) }),
                      let data = Data(base64Encoded: String(line.dropFirst(CaptivePortalSession.reportPrefix.count))) else {
                    throw PortalError.message("Résultat de la reconnexion illisible.")
                }
                let report = try JSONDecoder().decode(PortalSessionReport.self, from: data)
                ConnectionLog.append(report.events)
                let mac: Result = report.macOutput.isEmpty
                    ? .failed(report.error ?? "La rotation n'a pas été exécutée.")
                    : self.result(from: report.macOutput, command: command)
                DispatchQueue.main.async { completion(mac, report) }
            } catch {
                let message = error.localizedDescription
                ConnectionLog.append(["Échec du helper : \(message)"])
                DispatchQueue.main.async {
                    completion(.failed(message), PortalSessionReport(error: message))
                }
            }
        }
    }

    func verify(completion: @escaping (Result) -> Void) {
        queue.async {
            guard let command = self.pendingCommand else {
                DispatchQueue.main.async { completion(.pending) }
                return
            }
            let result: Result
            do {
                result = try self.perform(command, rotate: false)
            } catch {
                // La rotation précédente a réussi : une erreur de lecture ne doit
                // pas être présentée comme un échec de la modification réseau.
                result = .pending
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func rotateOnBackgroundQueue() -> Result {
        do {
            let command = try locateSpoofy()
            pendingCommand = nil
            pendingBefore = nil
            return try perform(command, rotate: true)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func perform(_ command: Command, rotate: Bool) throws -> Result {
        // Une seule autorisation pour lire avant, modifier puis lire après.
        // Une lecture non privilégiée depuis une app peut être masquée par macOS
        // (02:00:00:00:00:00), même lorsque le Terminal voit la vraie adresse.
        let script = Self.verificationScript(executable: command.executable, path: command.path,
                                             rotate: rotate, before: pendingBefore)
        let appleScript = "do shell script \"\(appleScriptQuote(script))\" with administrator privileges"
        let output = try run("/usr/bin/osascript", ["-e", appleScript], path: command.path)
        return result(from: output, command: command)
    }

    private func result(from output: String, command: Command) -> Result {
        let report = Self.parseReport(output)
        let before = report.before
        pendingBefore = before
        pendingCommand = command
        switch report.verification {
        case .changed(let after):
            pendingCommand = nil
            guard let before else { return .observed(after) }
            return .changed(from: before, to: after)
        case .observed(let after):
            pendingCommand = nil
            return .observed(after)
        case .unchanged:
            // Recontrôler aussi au retour dans le panneau après reconnexion.
            return .pending
        case .inconclusive:
            return .pending
        }
    }

    static func isUsableMAC(_ mac: String) -> Bool {
        mac.range(of: #"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"#, options: .regularExpression) != nil
            && !["02:00:00:00:00:00", "00:00:00:00:00:00"].contains(mac.uppercased())
    }

    /// Le script tourne entièrement dans le processus privilégié. Pas de fichier
    /// temporaire root, ni de nouvelle rotation lors d'une simple vérification.
    static func verificationScript(executable: String, path: String, rotate: Bool,
                                   before: String?, attempts: Int = 25, interval: Int = 1) -> String {
        let initial = rotate ? "$(read_mac)" : shellQuote(before ?? "")
        return """
        set -e
        export PATH=\(shellQuote(path))
        export NO_COLOR=1
        export FORCE_COLOR=0
        read_mac() {
            listing=$(\(shellQuote(executable)) list --wifi) || return 1
            printf '%s\\n' "$listing" | /usr/bin/awk '/ on device en0 / { print toupper($NF); exit }'
        }
        before=\(initial)
        printf 'SNCF_MAC_BEFORE=%s\\n' "$before"
        \(rotate ? "\(shellQuote(executable)) randomize en0" : ":")
        candidate=''
        count=0
        attempt=0
        while [ "$attempt" -lt \(attempts) ]; do
            /bin/sleep \(interval)
            after=$(read_mac) || after=''
            printf 'SNCF_MAC_SAMPLE=%s\\n' "$after"
            case "$after" in
                ''|02:00:00:00:00:00|00:00:00:00:00:00|"$before") candidate=''; count=0 ;;
                *)
                    if [ "$candidate" = "$after" ]; then count=$((count + 1)); else count=1; fi
                    candidate="$after"
                    if [ "$count" -ge 3 ]; then break; fi
                    ;;
            esac
            attempt=$((attempt + 1))
        done
        """
    }

    static func parseReport(_ output: String) -> (before: String?, verification: Verification) {
        let lines = output.components(separatedBy: .newlines)
        let beforePrefix = "SNCF_MAC_BEFORE="
        let samplePrefix = "SNCF_MAC_SAMPLE="
        let rawBefore = lines.first(where: { $0.hasPrefix(beforePrefix) }).map { String($0.dropFirst(beforePrefix.count)) }
        let before = rawBefore.flatMap { isUsableMAC($0) ? $0.uppercased() : nil }
        let samples = lines.filter { $0.hasPrefix(samplePrefix) }.map { String($0.dropFirst(samplePrefix.count)) }
        var iterator = samples.makeIterator()
        let verification = confirmChange(before: before, attempts: samples.count,
                                         read: { iterator.next() }, wait: {})
        return (before, verification)
    }

    /// `read` et `wait` sont injectés pour tester les phases transitoires sans
    /// lancer une commande privilégiée ni ralentir les tests.
    static func confirmChange(before: String?, attempts: Int,
                              read: () -> String?, wait: () -> Void) -> Verification {
        var candidate: String?
        var confirmations = 0
        var lastValid: String?
        for _ in 0..<attempts {
            wait()
            guard let mac = read()?.uppercased(), isUsableMAC(mac) else {
                candidate = nil
                confirmations = 0
                continue
            }
            lastValid = mac
            guard mac != before else {
                candidate = nil
                confirmations = 0
                continue
            }
            confirmations = candidate == mac ? confirmations + 1 : 1
            candidate = mac
            if confirmations >= 3 {
                return before == nil ? .observed(mac) : .changed(mac)
            }
        }
        if let before, lastValid == before { return .unchanged }
        return .inconclusive
    }

    /// `list` affiche l'adresse matérielle puis, si elle a été modifiée, « currently
    /// set to … ». Seule cette dernière (l'adresse effective) doit être comparée.
    static func currentMAC(in output: String, device: String) -> String? {
        let address = #"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}"#
        guard let devicePattern = try? NSRegularExpression(pattern: #"\bon device "# + NSRegularExpression.escapedPattern(for: device) + #"\b"#),
              let currentPattern = try? NSRegularExpression(pattern: "currently set to (\(address))", options: [.caseInsensitive]),
              let hardwarePattern = try? NSRegularExpression(pattern: "with MAC address (\(address))", options: [.caseInsensitive])
        else { return nil }

        for line in output.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard devicePattern.firstMatch(in: line, range: range) != nil else { continue }
            for pattern in [currentPattern, hardwarePattern] {
                if let match = pattern.firstMatch(in: line, range: range),
                   let valueRange = Range(match.range(at: 1), in: line) {
                    return String(line[valueRange]).uppercased()
                }
            }
        }
        return nil
    }

    private func locateSpoofy() throws -> Command {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        var nodeDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
        for root in ["\(home)/.local/share/fnm/node-versions", "\(home)/.nvm/versions/node"] {
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: root) {
                nodeDirectories += versions.sorted().reversed().map { "\(root)/\($0)/installation/bin" }
                // nvm place node directement sous <version>/bin.
                nodeDirectories += versions.sorted().reversed().map { "\(root)/\($0)/bin" }
            }
        }
        nodeDirectories += envPath.split(separator: ":").map(String.init)
        let directories = ["\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.local/bin"]
            + nodeDirectories
        guard let executable = directories.map({ "\($0)/spoofy" })
            .first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ClientError.message("spoofy introuvable. Installez-le avec npm install -g spoofy.")
        }

        // L'exécutable npm/bun a un shebang `#!/usr/bin/env node`. Finder ne
        // transmet pas le PATH du shell : retrouver Node aussi pour la commande root.
        let installedAlongsideSpoofy = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        guard let nodeDirectory = ([installedAlongsideSpoofy] + nodeDirectories).first(where: {
            FileManager.default.isExecutableFile(atPath: "\($0)/node")
        }) else {
            throw ClientError.message("Node.js introuvable (requis par spoofy). Installez Node.js pour utiliser cette action.")
        }

        // Les utilitaires de spoofy (networksetup/ifconfig) doivent venir du système,
        // pas d'un répertoire tiers placé devant eux dans le PATH du processus root.
        let path = (["/usr/bin", "/bin", "/usr/sbin", "/sbin", nodeDirectory]).joined(separator: ":")
        return Command(executable: executable, path: path)
    }

    private enum ClientError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    private func run(_ executable: String, _ arguments: [String], path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw ClientError.message("Impossible de lancer spoofy : \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            if text.contains("User canceled") || text.contains("(-128)") {
                throw ClientError.message("Opération annulée.")
            }
            throw ClientError.message(text.isEmpty ? "spoofy a échoué (code \(process.terminationStatus))." : text)
        }
        return text
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
