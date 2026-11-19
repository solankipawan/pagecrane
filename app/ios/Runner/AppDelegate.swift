import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    excludeDocumentsFromBackup()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PagecraneOpenPdf") {
      OpenPdfHandler.register(with: registrar)
    }
  }

  /// Scanned documents (IDs, tax and medical papers) stay on this iPhone: keep the
  /// library folder out of iCloud / computer backups. Same path as Dart's
  /// getApplicationDocumentsDirectory() + "/PDFit" (see DocRepository).
  private func excludeDocumentsFromBackup() {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    else { return }
    var dir = docs.appendingPathComponent("PDFit", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
  }
}

/// "Open in Pagecrane": a PDF shared or opened from Files, Mail, Safari… arrives as a
/// file URL (opened in place, security-scoped). It is validated and copied into
/// tmp/incoming, then reported on `pagecrane/open` — the same protocol as Android's
/// MainActivity (`opened` event; a cold start's file is collected with `takePending`).
final class OpenPdfHandler: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate {
  private static let maxBytes = 200 * 1024 * 1024
  private var channel: FlutterMethodChannel?
  private var pending: [String: Any]?
  private let io = DispatchQueue(label: "pagecrane.open-pdf")

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = OpenPdfHandler()
    let channel = FlutterMethodChannel(name: "pagecrane/open", binaryMessenger: registrar.messenger())
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addSceneDelegate(instance)
    registrar.addApplicationDelegate(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "takePending" {
      result(pending)
      pending = nil
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  // Cold start: the URL comes with the scene connection.
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    guard let contexts = connectionOptions?.urlContexts else { return false }
    return open(contexts)
  }

  // Already running.
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    open(URLContexts)
  }

  private func open(_ contexts: Set<UIOpenURLContext>) -> Bool {
    guard let url = contexts.map(\.url).first(where: { $0.isFileURL }) else { return false }
    io.async { [weak self] in
      let event: [String: Any]
      do {
        let (path, name) = try Self.copyIncoming(url)
        event = ["path": path, "name": name]
      } catch let e as IncomingPdfError {
        event = ["error": e.message]
      } catch {
        event = ["error": "Couldn’t open this file."]
      }
      DispatchQueue.main.async { self?.deliver(event) }
    }
    return true
  }

  private func deliver(_ event: [String: Any]) {
    // Dart may not be listening yet on a cold start: keep it for takePending.
    pending = event
    channel?.invokeMethod("opened", arguments: event) { [weak self] result in
      if result is FlutterError || (result as? NSObject) === FlutterMethodNotImplemented { return }
      if let p = self?.pending, NSDictionary(dictionary: p).isEqual(to: event) { self?.pending = nil }
    }
  }

  private struct IncomingPdfError: Error { let message: String }

  /// Untrusted input: only file URLs from outside our own data, at most 200 MB,
  /// must start with "%PDF-"; the shown name is sanitised and never used as a path.
  private static func copyIncoming(_ url: URL) throws -> (String, String) {
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    let src = url.standardizedFileURL.resolvingSymlinksInPath().path
    let inbox = home + "/Documents/Inbox/"
    if src.hasPrefix(home + "/") && !src.hasPrefix(inbox) {
      throw IncomingPdfError(message: "This file can’t be opened from here.")
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("incoming", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // Keep only the latest few opened files.
    if let old = try? fm.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
      let sorted = old.sorted {
        let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return a < b
      }
      sorted.dropLast(4).forEach { try? fm.removeItem(at: $0) }
    }

    let out = dir.appendingPathComponent(UUID().uuidString + ".pdf")
    guard let input = InputStream(url: url) else {
      throw IncomingPdfError(message: "Couldn’t read this file.")
    }
    guard fm.createFile(atPath: out.path, contents: nil),
          let output = try? FileHandle(forWritingTo: out) else {
      throw IncomingPdfError(message: "Couldn’t open this file.")
    }
    input.open()
    var total = 0
    do {
      defer { input.close(); try? output.close() }
      var buf = [UInt8](repeating: 0, count: 64 * 1024)
      var first = true
      while true {
        let n = input.read(&buf, maxLength: buf.count)
        if n < 0 { throw IncomingPdfError(message: "Couldn’t read this file.") }
        if n == 0 { break }
        if first {
          first = false
          let head = String(decoding: buf[0..<min(n, 1024)], as: UTF8.self)
          if !head.contains("%PDF-") { throw IncomingPdfError(message: "This file isn’t a PDF.") }
        }
        total += n
        if total > maxBytes {
          throw IncomingPdfError(message: "This PDF is too large to open (over 200 MB).")
        }
        try output.write(contentsOf: Data(buf[0..<n]))
      }
      if total == 0 { throw IncomingPdfError(message: "This file is empty.") }
    } catch {
      try? fm.removeItem(at: out)
      throw error
    }
    // A copy iOS placed in our Inbox (older "Open in" flows) is no longer needed.
    if src.hasPrefix(inbox) { try? fm.removeItem(at: url) }
    return (out.path, displayName(url))
  }

  private static func displayName(_ url: URL) -> String {
    var name = url.deletingPathExtension().lastPathComponent
    if name.isEmpty { name = "Document" }
    let bad = CharacterSet.controlCharacters
      .union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}/\\:*?\"<>|"))
    let clean = name.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
      .trimmingCharacters(in: .whitespaces)
    let short = String(clean.prefix(120))
    return short.isEmpty ? "Document" : short
  }
}
