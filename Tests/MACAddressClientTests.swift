import Foundation

@main
struct MACAddressClientTests {
    static func main() throws {
        let original = "F0:2F:4B:06:5E:E7"
        let first = "00:16:3E:25:C6:22"
        let second = "08:00:27:11:22:33"
        let before = """
        - Ethernet on device en4 with MAC address 11:22:33:44:55:66
        - Wi-Fi on device en0 with MAC address \(original) currently set to \(first)
        - Bluetooth on device en1 with MAC address 66:55:44:33:22:11
        """
        let after = "- Wi-Fi on device en0 with MAC address \(original) currently set to \(second)"

        precondition(MACAddressClient.currentMAC(in: before, device: "en0") == first)
        precondition(MACAddressClient.currentMAC(in: after, device: "en0") == second)
        precondition(MACAddressClient.currentMAC(in: before, device: "en4") == "11:22:33:44:55:66")
        precondition(MACAddressClient.currentMAC(in: "- Wi-Fi on device en0 with MAC address \(original)", device: "en0") == original)
        precondition(MACAddressClient.currentMAC(in: "- Wi-Fi on device en01 with MAC address \(original)", device: "en0") == nil)
        precondition(MACAddressClient.currentMAC(in: "- Wi-Fi on device en0", device: "en0") == nil)
        precondition(!MACAddressClient.isUsableMAC("02:00:00:00:00:00"))

        func verify(_ readings: [String?]) -> MACAddressClient.Verification {
            var iterator = readings.makeIterator()
            return MACAddressClient.confirmChange(before: first, attempts: readings.count,
                                                  read: { iterator.next() ?? nil }, wait: {})
        }
        precondition(verify(["02:00:00:00:00:00", first, second, second, second]) == .changed(second))
        precondition(verify(["02:00:00:00:00:00", nil, second, first, second, second, second]) == .changed(second))
        precondition(verify([first, "02:00:00:00:00:00", first]) == .unchanged)
        precondition(verify(["02:00:00:00:00:00", nil, second]) == .inconclusive)
        var provisional = ["02:00:00:00:00:00", second, second, second].makeIterator()
        precondition(MACAddressClient.confirmChange(before: nil, attempts: 4,
                                                    read: { provisional.next() ?? nil }, wait: {}) == .observed(second))
        precondition(MACAddressClient.confirmChange(before: nil, attempts: 2,
                                                    read: { "02:00:00:00:00:00" }, wait: {}) == .inconclusive)

        // Exécuter le vrai script de coordination avec un faux spoofy, sans sudo
        // ni modification réseau. Couvre aussi espaces/apostrophes dans son chemin.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake spoofy's cli")
        try """
        #!/bin/sh
        if [ "$1" = randomize ]; then
            [ "$2" = en0 ] || exit 10
            [ ! -f fail ] || exit 17
            touch rotated
            exit 0
        fi
        [ "$1" = list ] && [ "$2" = --wifi ] || exit 11
        count=0
        if [ -f count ]; then count=$(cat count); fi
        count=$((count + 1))
        printf '%s' "$count" > count
        mac=\(first)
        if [ -f rotated ]; then
            if [ "$count" -lt 4 ]; then mac=02:00:00:00:00:00; else mac=\(second); fi
        fi
        printf '%s\\n' "- Wi-Fi on device en0 with MAC address \(original) currently set to $mac"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        func runScript(rotate: Bool, attempts: Int = 8) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.currentDirectoryURL = directory
            process.arguments = ["-c", MACAddressClient.verificationScript(executable: executable.path,
                path: "/usr/bin:/bin:/usr/sbin:/sbin", rotate: rotate, before: first, attempts: attempts, interval: 0)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        let rotation = try runScript(rotate: true)
        precondition(rotation.0 == 0)
        let report = MACAddressClient.parseReport(rotation.1)
        precondition(report.before == first && report.verification == .changed(second))
        // osascript remplace les LF par des CR dans le résultat de do shell script.
        precondition(MACAddressClient.parseReport(rotation.1.replacingOccurrences(of: "\n", with: "\r")).verification == .changed(second))

        try FileManager.default.removeItem(at: directory.appendingPathComponent("rotated"))
        let verification = try runScript(rotate: false)
        precondition(verification.0 == 0)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("rotated").path))
        precondition(MACAddressClient.parseReport(verification.1).verification == .unchanged)

        try Data().write(to: directory.appendingPathComponent("fail"))
        let failure = try runScript(rotate: true)
        precondition(failure.0 == 17)
        precondition(!failure.1.contains("SNCF_MAC_SAMPLE="))

        // On peut aussi lui passer la sortie réelle de `spoofy list` sur stdin.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let output = String(data: input, encoding: .utf8), !output.isEmpty {
            precondition(MACAddressClient.currentMAC(in: output, device: "en0") != nil)
        }
        print("MACAddressClient : parsing, vérification et script de rotation OK")
    }
}
