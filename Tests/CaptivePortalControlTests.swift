import Foundation

@main
struct CaptivePortalControlTests {
    static func main() throws {
        var events: [String] = []
        let control = CaptivePortalControl(register: { ssids in
            events.append(ssids.isEmpty ? "release" : "register")
            if !ssids.isEmpty { precondition(ssids == CaptivePortalSession.knownSSIDs) }
            return true
        }, markOnline: { events.append("online"); return true })
        try control.suppress()
        try control.restore(online: true)
        try control.restore(online: true)
        precondition(events == ["register", "online", "release"])

        events = []
        try control.suppress()
        try control.restore()
        precondition(events == ["register", "release"], "Ne pas annoncer Internet après un échec")

        events = []
        let notificationFailure = CaptivePortalControl(register: { ssids in
            events.append(ssids.isEmpty ? "release" : "register")
            return true
        }, markOnline: { events.append("online"); return false })
        try notificationFailure.suppress()
        do {
            try notificationFailure.restore(online: true)
            preconditionFailure("Échec de notification ignoré")
        } catch {
            precondition(events == ["register", "online", "release"], "Toujours libérer la prise en charge")
        }

        events = []
        let registrationFailure = CaptivePortalControl(register: { _ in events.append("register"); return false })
        do { try registrationFailure.suppress(); preconditionFailure("Inscription refusée ignorée") }
        catch {}
        try registrationFailure.restore()
        precondition(events == ["register"])
        print("CaptivePortalControl : inscription, notification et libération OK")
    }
}
