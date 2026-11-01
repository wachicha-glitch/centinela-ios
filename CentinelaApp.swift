import SwiftUI
import UIKit
import WebKit
import UserNotifications
import LocalAuthentication

// Centinela · contenedor nativo
// Muestra Web/index.html a pantalla completa y le da lo que una web sola no puede:
// guardar en el iPhone, avisos locales, peticiones a tu PC (sin límites del navegador),
// Face ID, vibración, tema claro/oscuro del sistema y abrir enlaces en Safari.
// Sin async/await ni @MainActor para que compile en Xcode 13.2.1 (Swift 5.5) y en versiones nuevas.

@main
struct CentinelaApp: App {
    init() {
        Notifier.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            AppWebView()
                .ignoresSafeArea()
                .background(Color(uiColor: .appPaper))
        }
    }
}

extension UIColor {
    /// Fondo detrás de la página (claro / oscuro). Igual que --bg de la página.
    static let appPaper = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 10 / 255, green: 14 / 255, blue: 21 / 255, alpha: 1)
            : UIColor(red: 236 / 255, green: 239 / 255, blue: 244 / 255, alpha: 1)
    }
}

// MARK: - Vista web

struct AppWebView: UIViewRepresentable {
    func makeCoordinator() -> WebBridge {
        WebBridge()
    }

    func makeUIView(context: Context) -> WKWebView {
        let bridge = context.coordinator

        let controller = WKUserContentController()
        controller.add(bridge, name: "app")
        controller.addUserScript(WKUserScript(source: Store.bootScript(),
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .default()

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .appPaper
        web.scrollView.backgroundColor = .appPaper
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.isScrollEnabled = false   // la página gestiona su propio scroll
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        web.navigationDelegate = bridge
        web.uiDelegate = bridge
        bridge.webView = web
        bridge.observeAppActivation()

        if let url = Bundle.main.url(forResource: "index", withExtension: "html")
            ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Puente página ↔ iPhone
// Mensajes que acepta (desde JS: window.webkit.messageHandlers.app.postMessage({...})):
//   {type:"save", json:"<texto JSON>"}             guarda los datos
//   {type:"schedule", reminders:[{id, at:"YYYY-MM-DDTHH:mm", title, body}]}
//   {type:"requestPermission"}                     responde con window.appPermission(true|false)
//   {type:"test"}                                  aviso de prueba a los 5 s
//   {type:"http", id, method, url, headers, body, timeout}   responde con window.appHttp(id, status, texto)
//   {type:"auth"}                                  Face ID; responde con window.appAuth(true|false)
//   {type:"theme", value:"auto"|"light"|"dark"}    tema de la app (barra de estado incluida)
//   {type:"haptic"}                                vibración suave
// Al volver a la app llama a window.appResync() y, si venía del fondo, a window.appLock().

final class WebBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var webView: WKWebView?
    private var wasInBackground = false
    private var pendingStyle: UIUserInterfaceStyle = .unspecified

    func observeAppActivation() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appBecameActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appEnteredBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
    }

    @objc private func appEnteredBackground() {
        wasInBackground = true
    }

    @objc private func appBecameActive() {
        var js = "window.appResync && window.appResync();"
        if wasInBackground {
            js += "window.appLock && window.appLock();"
            wasInBackground = false
        }
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "save":
            if let json = body["json"] as? String {
                Store.save(json)
            }
        case "schedule":
            if let list = body["reminders"] as? [[String: Any]] {
                Notifier.shared.schedule(list)
            }
        case "requestPermission":
            Notifier.shared.requestPermission { [weak self] granted in
                self?.webView?.evaluateJavaScript("window.appPermission && window.appPermission(\(granted))",
                                                  completionHandler: nil)
            }
        case "test":
            Notifier.shared.sendTest()
        case "http":
            http(body)
        case "auth":
            authenticate()
        case "theme":
            if let value = body["value"] as? String {
                applyTheme(value)
            }
        case "haptic":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        default:
            break
        }
    }

    // MARK: Peticiones a tu PC y a ForexFactory

    private func http(_ body: [String: Any]) {
        guard let id = body["id"] as? String else { return }
        guard let text = body["url"] as? String, let url = URL(string: text) else {
            reply(id, status: 0, text: "Dirección no válida")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = (body["method"] as? String) ?? "GET"
        request.timeoutInterval = (body["timeout"] as? Double) ?? 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let headers = body["headers"] as? [String: Any] {
            for (key, value) in headers {
                if let value = value as? String {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
        }
        if let payload = body["body"] as? String, !payload.isEmpty, request.httpMethod != "GET" {
            request.httpBody = payload.data(using: .utf8)
        }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            var status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var answer = ""
            if let data = data {
                answer = String(data: data, encoding: .utf8) ?? ""
            }
            if let error = error {
                status = 0
                answer = error.localizedDescription
            }
            DispatchQueue.main.async {
                self?.reply(id, status: status, text: answer)
            }
        }.resume()
    }

    private func reply(_ id: String, status: Int, text: String) {
        let js = "window.appHttp && window.appHttp(\(JS.string(id)), \(status), \(JS.string(text)))"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: Face ID

    private func authenticate() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            sendAuth(true)   // sin código ni Face ID configurados: no bloqueamos
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Desbloquear Centinela") { [weak self] ok, _ in
            DispatchQueue.main.async {
                self?.sendAuth(ok)
            }
        }
    }

    private func sendAuth(_ ok: Bool) {
        webView?.evaluateJavaScript("window.appAuth && window.appAuth(\(ok))", completionHandler: nil)
    }

    // MARK: Tema

    private func applyTheme(_ value: String) {
        let style: UIUserInterfaceStyle = value == "dark" ? .dark : (value == "light" ? .light : .unspecified)
        pendingStyle = style
        webView?.overrideUserInterfaceStyle = style
        webView?.window?.overrideUserInterfaceStyle = style
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.window?.overrideUserInterfaceStyle = pendingStyle
    }

    // MARK: Enlaces: se abren en Safari

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "tel"].contains(scheme) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return nil
    }
}

// MARK: - Texto seguro para JavaScript

enum JS {
    static func string(_ text: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [text]),
           let literal = String(data: data, encoding: .utf8) {
            return "\(literal)[0]"
        }
        return "\"\""
    }
}

// MARK: - Guardado en el iPhone (Documents/datos.json)

enum Store {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("datos.json")
    }

    static func save(_ json: String) {
        guard let data = json.data(using: .utf8) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Se ejecuta antes que la página: window.__NATIVE__ = {platform:'ios', raw:'<json guardado>' | null}
    static func bootScript() -> String {
        var raw = "null"
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8) {
            raw = JS.string(text)
        }
        return "window.__NATIVE__ = { platform: 'ios', raw: \(raw) };"
    }
}

// MARK: - Notificaciones locales

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// iOS guarda como mucho 64 avisos pendientes por app; dejamos margen.
    private static let maxScheduled = 60
    private static let testID = "aviso-de-prueba"

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func configure() {
        center.delegate = self
    }

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Sustituye todos los avisos programados por los 60 más próximos de la lista.
    func schedule(_ list: [[String: Any]]) {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = .current
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm"

        let now = Date()
        var items: [(id: String, date: Date, title: String, body: String)] = []
        for item in list {
            guard let id = item["id"] as? String,
                  let at = item["at"] as? String,
                  let date = parser.date(from: at),
                  date > now else { continue }
            let title = item["title"] as? String ?? ""
            let body = item["body"] as? String ?? ""
            items.append((id: id, date: date, title: title, body: body))
        }
        items.sort { $0.date < $1.date }
        let chosen = Array(items.prefix(Self.maxScheduled))
        let testID = Self.testID

        let center = self.center
        center.getPendingNotificationRequests { pending in
            let old = pending.map { $0.identifier }.filter { $0 != testID }
            center.removePendingNotificationRequests(withIdentifiers: old)
            let calendar = Calendar.current
            for item in chosen {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger),
                           withCompletionHandler: nil)
            }
        }
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "Los avisos funcionan"
        content.body = "Así te llegarán los recordatorios de Centinela."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.testID, content: content, trigger: trigger),
                   withCompletionHandler: nil)
    }

    /// Mostrar el aviso aunque la app esté abierta.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
