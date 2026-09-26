import Foundation

enum PortalError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

struct PortalHTTPError: LocalizedError {
    let request: URLRequest
    let statusCode: Int
    let body: Data
    let location: String

    var isMissingGrant: Bool {
        guard statusCode == 404, request.httpMethod == "GET",
              request.url?.path == "/router/api/connection/status",
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["status_code"] as? Int == 404,
              let description = json["status_description"] as? String else { return false }
        return description.contains("does not have any") && description.contains("grants")
    }

    var errorDescription: String? {
        "\(request.httpMethod ?? "GET") \(request.url?.path ?? "") : HTTP \(statusCode)\(location)."
    }
}

/// API observée dans les HAR : la classe 9 est captive même avec active=true.
/// Sessions éphémères : aucun cookie ou identifiant du HAR n'est rejoué.
final class SNCFPortalClient: NSObject, URLSessionTaskDelegate {
    struct Status: Decodable {
        let active: Bool
        let status_code: Int
        let service_class: Int

        var authorized: Bool { active && status_code == 200 && service_class == 5 }
    }

    typealias Transport = (URLRequest) throws -> Data
    private var injectedTransport: Transport?
    private let trace: (String) -> Void
    private var activationGrantID = ""
    private var didActivate = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(trace: @escaping (String) -> Void = { _ in }, transport: Transport? = nil) {
        injectedTransport = transport
        self.trace = trace
        super.init()
    }

    func close() { session.invalidateAndCancel() }

    func status() throws -> Status {
        let status = try JSONDecoder().decode(Status.self, from: request(path: "status"))
        trace("État : active=\(status.active), code=\(status.status_code), classe=\(status.service_class)")
        return status
    }

    /// Une MAC neuve n'a pas encore de grant : le routeur répond 404 avec ce
    /// message précis. Un 404 HTML / proxy / autre API reste une vraie erreur.
    func statusOrUnregistered() throws -> Status? {
        do { return try status() }
        catch let error as PortalHTTPError where error.isMissingGrant {
            trace("Aucune session pour cette MAC : activation nécessaire")
            return nil
        }
    }

    private func activate() throws {
        // Première connexion : chemin utilisé par le bouton du portail, avant
        // les deux appels modify/registry visibles dans les HAR d'une session existante.
        let data = try request(path: "activate/auto", body: ["without21NetConnection": false])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PortalError.message("Réponse d'activation SNCF illisible.")
        }
        if let ok = json["success"] as? Bool, !ok {
            throw PortalError.message("Le portail SNCF a refusé la création de session.")
        }
        activationGrantID = json["grantId"] as? String ?? ""
        didActivate = true
        trace("Demande de création de session envoyée")
        // Vérifier le grant créé plutôt que se fier seulement au HTTP 200.
        guard try statusOrUnregistered() != nil else {
            throw PortalError.message("Le portail n'a pas encore créé la session de connexion.")
        }
    }

    func authorize() throws {
        struct Modification: Decodable {
            struct Details: Decodable { let status_code: Int }
            let ok: Bool
            let status: Int
            let json: Details
        }
        let modification = try JSONDecoder().decode(Modification.self,
            from: request(path: "modify", body: ["serviceClass": 5]))
        let modified = modification.ok && modification.status == 200 && modification.json.status_code == 200
        // Une tentative précédente peut avoir réussi malgré une réponse perdue.
        // Le routeur renvoie alors HTTP 200 avec un statut interne 409. Vérifier
        // l'état courant plutôt que de traiter ce cas idempotent comme un refus.
        var alreadyAuthorized = false
        if modification.status == 409, modification.json.status_code == 409 {
            alreadyAuthorized = try status().authorized
        }
        guard modified || alreadyAuthorized else {
            throw PortalError.message("Le portail SNCF a refusé l'autorisation Internet.")
        }

        struct Registration: Decodable { let success: Bool }
        let registration = try JSONDecoder().decode(Registration.self,
            from: request(path: "registry", body: [
                "reference": "AUTO-LOGIN-PROFILE-ID", "name": "", "grant_delay": "0",
                "authenticationType": didActivate ? "auto" : "", "grantId": activationGrantID, "travelClass": 2
            ]))
        guard registration.success else {
            throw PortalError.message("Le portail SNCF n'a pas enregistré la connexion.")
        }
    }

    /// La réussite exige aussi une réponse HTTPS extérieure au portail local.
    /// Cela ne dépend ni de l'affichage de la page CGU ni de la fenêtre captive.
    func internetIsReachable() -> Bool {
        var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let data = try? send(request), let html = String(data: data, encoding: .utf8) else { return false }
        return html.contains("<TITLE>Success</TITLE>") && html.contains("<BODY>Success</BODY>")
    }

    func connect(timeout: TimeInterval = 90, rejoin: () -> Void,
                 wait: () -> Void = { Thread.sleep(forTimeInterval: 2) }) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var registered = false
        var lastError = "Le Wi-Fi SNCF n'est pas encore joignable."
        var didRejoin = false
        var attempt = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            attempt += 1
            trace("Tentative d'autorisation \(attempt), registered=\(registered)")
            do {
                let current = try statusOrUnregistered()
                if current == nil {
                    registered = false
                    try activate()
                }
                if !registered {
                    try authorize()
                    registered = true
                } else if current?.authorized == true, internetIsReachable() {
                    return
                }
                lastError = "Le portail n'a pas encore confirmé l'accès Internet."
            } catch {
                lastError = error.localizedDescription
                trace("Échec de la tentative : \(lastError)")
                if !didRejoin, error is URLError {
                    didRejoin = true
                    rejoin()
                }
            }
            wait()
        }
        throw PortalError.message("Connexion automatique non confirmée : \(lastError)")
    }

    private func request(path: String, body: [String: Any]? = nil) throws -> Data {
        var request = URLRequest(url: URL(string: "https://wifi.sncf/router/api/connection/\(path)")!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://wifi.sncf", forHTTPHeaderField: "Origin")
        request.setValue("https://wifi.sncf/en/activity", forHTTPHeaderField: "Referer")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try send(request)
    }

    /// Appelé uniquement depuis la file de travail / le helper CLI, jamais depuis l'UI.
    private func send(_ request: URLRequest) throws -> Data {
        let label = "\(request.httpMethod ?? "GET") \(request.url?.host ?? "")\(request.url?.path ?? "")"
        trace(label)
        if let injectedTransport { return try injectedTransport(request) }
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(URLError(.timedOut))
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                self.trace("\(label) : \((error as NSError).domain)/\((error as NSError).code) \(error.localizedDescription)")
                result = .failure(error)
                return
            }
            guard let response = response as? HTTPURLResponse, let data else {
                result = .failure(PortalError.message("Réponse HTTP absente pour \(label)."))
                return
            }
            let location = response.value(forHTTPHeaderField: "Location")
                .flatMap { URL(string: $0, relativeTo: request.url) }
                .map { " → \($0.host ?? "")\($0.path)" } ?? ""
            self.trace("\(label) : HTTP \(response.statusCode), \(data.count) octets\(location)")
            // Champs de diagnostic uniquement : ne jamais journaliser cookies,
            // identifiants de session ou corps HTML du portail.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let details = (json["json"] as? [String: Any]) ?? json
                let fields = ["ok", "success", "status", "status_code", "status_description"]
                    .compactMap { key in details[key].map { "\(key)=\($0)" } }
                if !fields.isEmpty { self.trace(fields.joined(separator: ", ")) }
            }
            guard response.statusCode == 200 else {
                result = .failure(PortalHTTPError(request: request, statusCode: response.statusCode, body: data, location: location))
                return
            }
            result = .success(data)
        }
        task.resume()
        done.wait()
        return try result.get()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Un portail ou changement de réseau ne doit pas déplacer nos POST ailleurs.
        completionHandler(nil)
    }
}
