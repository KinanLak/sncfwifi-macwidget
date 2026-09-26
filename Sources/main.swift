import Cocoa
import CoreLocation

if CommandLine.arguments.dropFirst().first == CaptivePortalSession.argument {
    guard CommandLine.arguments.count == 5 else { exit(2) }
    let report = CaptivePortalSession.run(spoofy: CommandLine.arguments[2], path: CommandLine.arguments[3],
                                          ssid: CommandLine.arguments[4].isEmpty ? nil : CommandLine.arguments[4])
    if let data = try? JSONEncoder().encode(report) {
        print(CaptivePortalSession.reportPrefix + data.base64EncodedString())
        exit(0)
    }
    exit(1)
}

// Si la permission localisation n'est pas encore accordée, démarrer en mode .regular
// (icône Dock visible) pour que macOS puisse présenter la dialog TCC d'autorisation.
// MenuBarController repasse en .accessory dès que la réponse est reçue.
let app = NSApplication.shared
if CLLocationManager().authorizationStatus == .notDetermined {
    app.setActivationPolicy(.regular)
} else {
    app.setActivationPolicy(.accessory)
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
