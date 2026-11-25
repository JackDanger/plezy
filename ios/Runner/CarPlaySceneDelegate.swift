import CarPlay
import Flutter
import UIKit

/// The CarPlay scene: a tab bar of lists, and the system Now Playing screen.
///
/// The lists are native templates filled from Dart over `com.plezy/carplay`
/// (see `lib/services/carplay_bridge.dart`). Each row carries an id Dart made;
/// it goes back to Dart to list what is under it or to play it. Now Playing
/// needs nothing from here: it reads the same `MPNowPlayingInfoCenter` and
/// remote commands as the lock screen.
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    CarPlayController.shared.connect(interfaceController)
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    CarPlayController.shared.disconnect()
  }
}

/// Owns the channel to Dart and the car's template stack. A singleton because
/// the Flutter engine and the CarPlay scene arrive separately, in either order.
final class CarPlayController {
  static let shared = CarPlayController()

  private var channel: FlutterMethodChannel?
  private var interfaceController: CPInterfaceController?
  /// Dart's bridge is up: it starts with a profile session, after the engine.
  private var dartReady = false
  private let imageSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 15
    config.urlCache = URLCache(memoryCapacity: 8 << 20, diskCapacity: 32 << 20)
    return URLSession(configuration: config)
  }()

  /// Called once the Flutter engine exists.
  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.plezy/carplay", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "ready" {
        self?.dartReady = true
        self?.showRoot()
      }
      result(nil)
    }
    self.channel = channel
  }

  func connect(_ interfaceController: CPInterfaceController) {
    self.interfaceController = interfaceController
    showRoot()
  }

  func disconnect() {
    interfaceController = nil
  }

  // MARK: - Templates

  private func showRoot() {
    guard let interfaceController else { return }
    guard let channel, dartReady else {
      interfaceController.setRootTemplate(Self.waitingTemplate(), animated: false, completion: nil)
      return
    }
    channel.invokeMethod("tabs", arguments: nil) { [weak self] result in
      guard let self, let tabs = result as? [[String: String]], !tabs.isEmpty else { return }
      let templates: [CPTemplate] = tabs.prefix(CPTabBarTemplate.maximumTabCount).map { tab in
        let list = self.listTemplate(id: tab["id"] ?? "", title: tab["title"] ?? "")
        list.tabTitle = tab["title"]
        list.tabImage = tab["systemImage"].flatMap { UIImage(systemName: $0) }
        return list
      }
      self.interfaceController?.setRootTemplate(CPTabBarTemplate(templates: templates), animated: false, completion: nil)
    }
  }

  /// Shown until the app has signed in: the car cannot start that itself.
  private static func waitingTemplate() -> CPListTemplate {
    let item = CPListItem(text: "Open Plezy on your iPhone", detailText: "Plezy connects to your server from there")
    item.isEnabled = false
    return CPListTemplate(title: "Plezy", sections: [CPListSection(items: [item])])
  }

  private func listTemplate(id: String, title: String) -> CPListTemplate {
    let template = CPListTemplate(title: title, sections: [])
    template.emptyViewTitleVariants = ["Loading…"]
    load(id: id, into: template)
    return template
  }

  private func load(id: String, into template: CPListTemplate) {
    channel?.invokeMethod("browse", arguments: ["id": id]) { [weak self, weak template] result in
      guard let self, let template else { return }
      guard let reply = result as? [String: Any], let rows = reply["items"] as? [[String: Any]] else {
        template.emptyViewTitleVariants = ["Couldn't load this"]
        template.updateSections([])
        return
      }
      let items = rows.prefix(CPListTemplate.maximumItemCount).map { self.listItem($0) }
      template.emptyViewTitleVariants = ["Nothing here"]
      template.updateSections([CPListSection(items: Array(items))])
    }
  }

  private func listItem(_ row: [String: Any]) -> CPListItem {
    let id = row["id"] as? String ?? ""
    let title = row["title"] as? String ?? ""
    let symbol = (row["systemImage"] as? String).flatMap { UIImage(systemName: $0) }
    let item = CPListItem(text: title, detailText: row["subtitle"] as? String, image: symbol)
    let browsable = row["browsable"] as? Bool == true
    if browsable { item.accessoryType = .disclosureIndicator }
    if let image = row["image"] as? String, let url = URL(string: image) {
      loadImage(url) { [weak item] in item?.setImage($0) }
    }
    item.handler = { [weak self] _, completion in
      guard let self else { return completion() }
      if browsable {
        self.interfaceController?.pushTemplate(self.listTemplate(id: id, title: title), animated: true) { _, _ in
          completion()
        }
      } else {
        self.play(id: id, completion: completion)
      }
    }
    return item
  }

  private func play(id: String, completion: @escaping () -> Void) {
    channel?.invokeMethod("play", arguments: ["id": id]) { [weak self] result in
      defer { completion() }
      guard let self, let interfaceController = self.interfaceController else { return }
      if let problem = result as? String {
        let alert = CPAlertTemplate(
          titleVariants: [problem],
          actions: [CPAlertAction(title: "OK", style: .cancel) { _ in interfaceController.dismissTemplate(animated: true, completion: nil) }]
        )
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
        return
      }
      let nowPlaying = CPNowPlayingTemplate.shared
      if interfaceController.topTemplate !== nowPlaying {
        interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
      }
    }
  }

  private func loadImage(_ url: URL, apply: @escaping (UIImage) -> Void) {
    imageSession.dataTask(with: url) { data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async { apply(image) }
    }.resume()
  }
}
