import Foundation

@main
struct SNCFPortalClientTests {
    static func main() throws {
        let captive = Data(#"{"active":true,"status_code":200,"service_class":9}"#.utf8)
        let online = Data(#"{"active":true,"status_code":200,"service_class":5}"#.utf8)
        let modified = Data(#"{"ok":true,"status":200,"json":{"status_code":200}}"#.utf8)
        let registered = Data(#"{"success":true}"#.utf8)
        let internet = Data("<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>".utf8)
        let captiveStatus = try JSONDecoder().decode(SNCFPortalClient.Status.self, from: captive)
        let onlineStatus = try JSONDecoder().decode(SNCFPortalClient.Status.self, from: online)
        precondition(!captiveStatus.authorized)
        precondition(onlineStatus.authorized)

        var requests: [URLRequest] = []
        var responses = [captive, modified, registered, online, internet].makeIterator()
        let client = SNCFPortalClient(transport: { request in
            requests.append(request)
            guard let data = responses.next() else { throw URLError(.badServerResponse) }
            return data
        })
        defer { client.close() }
        try client.connect(rejoin: { preconditionFailure("Aucune réassociation nécessaire") }, wait: {})
        precondition(requests.map { $0.url!.lastPathComponent } == ["status", "modify", "registry", "status", "success.html"])
        precondition(requests.map { $0.httpMethod! } == ["GET", "POST", "POST", "GET", "GET"])
        precondition(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        let modifyBody = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
        precondition(modifyBody["serviceClass"] as? Int == 5)
        let registryBody = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
        precondition(registryBody["reference"] as? String == "AUTO-LOGIN-PROFILE-ID")
        precondition(registryBody["travelClass"] as? Int == 2)

        // Un HTTP 200 transportant un refus applicatif doit arrêter la séquence.
        var rejectedRequests = 0
        let rejected = SNCFPortalClient(transport: { _ in
            rejectedRequests += 1
            return Data(#"{"ok":true,"status":200,"json":{"status_code":403}}"#.utf8)
        })
        defer { rejected.close() }
        do { try rejected.authorize(); preconditionFailure("Le refus a été ignoré") }
        catch { precondition(rejectedRequests == 1) }

        let conflict = Data(#"{"ok":false,"status":409,"json":{"status_code":409}}"#.utf8)
        var repeatedResponses = [conflict, online, registered].makeIterator()
        let repeated = SNCFPortalClient(transport: { _ in repeatedResponses.next()! })
        defer { repeated.close() }
        try repeated.authorize()
        var conflictingResponses = [conflict, captive].makeIterator()
        let conflicting = SNCFPortalClient(transport: { _ in conflictingResponses.next()! })
        defer { conflicting.close() }
        do { try conflicting.authorize(); preconditionFailure("409 sans accès Internet accepté") }
        catch {}

        // Réseau encore absent : réassociation, puis même séquence d'autorisation.
        var retryResponses = [captive, modified, registered, online, internet].makeIterator()
        var attempts = 0
        var rejoined = 0
        let reconnecting = SNCFPortalClient(transport: { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return retryResponses.next()!
        })
        defer { reconnecting.close() }
        try reconnecting.connect(rejoin: { rejoined += 1 }, wait: {})
        precondition(rejoined == 1)

        let intercepted = SNCFPortalClient(transport: { _ in Data("<html>Veuillez vous connecter</html>".utf8) })
        defer { intercepted.close() }
        precondition(!intercepted.internetIsReachable())

        // Régression réelle : pas de grant après changement de MAC. Ne pas
        // attendre indéfiniment un 200 sur status : créer la session nous-mêmes.
        let missing = Data(#"{"status_code":404,"status_description":"identifier 00:11:22:33:44:55 does not have any (in)active grants"}"#.utf8)
        var freshRequests: [URLRequest] = []
        var freshResponses = [Data(#"{"grantId":"new-test-grant"}"#.utf8), online, conflict, online, registered, online, internet].makeIterator()
        let fresh = SNCFPortalClient(transport: { request in
            freshRequests.append(request)
            if freshRequests.count == 1 {
                throw PortalHTTPError(request: request, statusCode: 404, body: missing, location: "")
            }
            return freshResponses.next()!
        })
        defer { fresh.close() }
        try fresh.connect(rejoin: { preconditionFailure("Le 404 ne justifie pas une réassociation Wi-Fi") }, wait: {})
        precondition(freshRequests.map { $0.url!.lastPathComponent } == ["status", "auto", "status", "modify", "status", "registry", "status", "success.html"])
        let activation = try JSONSerialization.jsonObject(with: freshRequests[1].httpBody!) as! [String: Any]
        precondition(activation["without21NetConnection"] as? Bool == false)
        let freshRegistry = try JSONSerialization.jsonObject(with: freshRequests[5].httpBody!) as! [String: Any]
        precondition(freshRegistry["grantId"] as? String == "new-test-grant")
        precondition(freshRegistry["authenticationType"] as? String == "auto")

        let wrong404 = SNCFPortalClient(transport: { request in
            throw PortalHTTPError(request: request, statusCode: 404, body: Data("<html>Not found</html>".utf8), location: "")
        })
        defer { wrong404.close() }
        do { _ = try wrong404.statusOrUnregistered(); preconditionFailure("Un 404 générique n'est pas un grant absent") }
        catch {}
        print("SNCFPortalClient : autorisation, refus, reconnexion et accès Internet OK")
    }
}
