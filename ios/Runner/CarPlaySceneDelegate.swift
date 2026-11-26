import CarPlay
import Flutter
import MediaPlayer
import UIKit

/// The CarPlay scene: a tab bar of lists, and the system Now Playing screen.
///
/// The lists are native templates filled from Dart over `com.plezy/carplay`
/// (see `lib/services/carplay_bridge.dart`). Each row carries an id Dart made;
/// it goes back to Dart to list what is under it or to play it. Now Playing
/// reads the same `MPNowPlayingInfoCenter` and remote commands as the lock
/// screen; its extra buttons (shuffle, repeat, radio, Up Next, the artist)
/// call into Dart too.
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
final class CarPlayController: NSObject {
  static let shared = CarPlayController()

  /// A tab's list is fetched again when it comes back after this long, so
  /// the mixes and recently played keep up with the day.
  private static let staleAfter: TimeInterval = 10 * 60
  private static let upNextId = "queue"

  private var channel: FlutterMethodChannel?
  private var interfaceController: CPInterfaceController?
  /// Dart's bridge is up: it starts with a profile session, after the engine.
  private var dartReady = false
  private var nowPlayingConfigured = false
  private var state = NowPlayingState()
  /// Track rows on screen, to mark the one playing as it changes.
  private var trackItems: [(key: String, item: WeakItem)] = []

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
      switch call.method {
      case "ready":
        self?.dartReady = true
        self?.showRoot()
      case "nowPlaying":
        self?.apply(NowPlayingState(call.arguments))
      default:
        break
      }
      result(nil)
    }
    self.channel = channel
  }

  func connect(_ interfaceController: CPInterfaceController) {
    self.interfaceController = interfaceController
    interfaceController.delegate = self
    configureNowPlaying()
    showRoot()
  }

  func disconnect() {
    interfaceController = nil
    trackItems.removeAll()
  }

  // MARK: - Root

  private func showRoot() {
    guard let interfaceController else { return }
    guard let channel, dartReady else {
      interfaceController.setRootTemplate(Self.waitingTemplate(), animated: false, completion: nil)
      return
    }
    channel.invokeMethod("nowPlaying", arguments: nil) { [weak self] result in
      self?.apply(NowPlayingState(result))
    }
    channel.invokeMethod("tabs", arguments: nil) { [weak self] result in
      guard let self, let tabs = result as? [[String: String]], !tabs.isEmpty else { return }
      let templates: [CPTemplate] = tabs.prefix(CPTabBarTemplate.maximumTabCount).map { tab in
        let list = self.listTemplate(id: tab["id"] ?? "", title: tab["title"] ?? "")
        list.tabTitle = tab["title"]
        list.tabImage = tab["systemImage"].flatMap { UIImage(systemName: $0) }
        return list
      }
      self.interfaceController?.setRootTemplate(
        CPTabBarTemplate(templates: templates), animated: false, completion: nil)
    }
  }

  /// Shown until the app has signed in: the car cannot start that itself.
  private static func waitingTemplate() -> CPListTemplate {
    let item = CPListItem(
      text: "Open Plezy on your iPhone", detailText: "Your music shows up here once it has connected")
    item.isEnabled = false
    item.setImage(UIImage(systemName: "iphone"))
    return CPListTemplate(title: "Plezy", sections: [CPListSection(items: [item])])
  }

  // MARK: - Lists

  private func listTemplate(id: String, title: String) -> CPListTemplate {
    let template = CPListTemplate(title: title, sections: [])
    template.emptyViewTitleVariants = ["Loading…"]
    template.userInfo = ListInfo(id: id)
    load(template)
    return template
  }

  private func load(_ template: CPListTemplate) {
    guard let info = template.userInfo as? ListInfo else { return }
    info.loadedAt = Date()
    channel?.invokeMethod("browse", arguments: ["id": info.id]) { [weak self, weak template] result in
      guard let self, let template else { return }
      guard let reply = result as? [String: Any], let sections = reply["sections"] as? [[String: Any]] else {
        info.hadRows = false
        template.emptyViewTitleVariants = ["Couldn't load this"]
        template.emptyViewSubtitleVariants = ["Check that your server is online"]
        template.updateSections([])
        return
      }
      var budget = CPListTemplate.maximumItemCount
      let listSections: [CPListSection] = sections.compactMap { section in
        let rows = (section["items"] as? [[String: Any]] ?? []).prefix(max(budget, 0))
        budget -= rows.count
        guard !rows.isEmpty else { return nil }
        let items = rows.map { self.listItem($0) }
        return CPListSection(items: items, header: section["header"] as? String, sectionIndexTitle: nil)
      }
      info.hadRows = !listSections.isEmpty
      template.emptyViewTitleVariants = [reply["emptyTitle"] as? String ?? "Nothing here"]
      template.emptyViewSubtitleVariants = []
      template.updateSections(listSections)
      self.markPlaying()
    }
  }

  private func listItem(_ row: [String: Any]) -> CPListTemplateItem {
    if row["type"] as? String == "imageRow" { return imageRow(row) }
    let id = row["id"] as? String ?? ""
    let title = row["title"] as? String ?? ""
    let symbol = (row["systemImage"] as? String).flatMap { UIImage(systemName: $0) }
    let item = CPListItem(text: title, detailText: row["subtitle"] as? String, image: symbol)
    let browsable = row["browsable"] as? Bool == true
    if browsable { item.accessoryType = .disclosureIndicator }
    if let image = row["image"] as? String, let url = URL(string: image) {
      loadImage(url) { [weak item] in item?.setImage($0) }
    }
    if let key = row["trackKey"] as? String {
      item.playingIndicatorLocation = .trailing
      item.isPlaying = key == state.trackKey
      trackItems.append((key, WeakItem(item)))
    }
    item.handler = { [weak self] _, completion in
      guard let self else { return completion() }
      if browsable {
        self.push(id: id, title: title, completion: completion)
      } else {
        self.play(id: id, completion: completion)
      }
    }
    return item
  }

  /// A strip of covers: a tap on one plays it, a tap on the title lists them
  /// all.
  private func imageRow(_ row: [String: Any]) -> CPListTemplateItem {
    let title = row["title"] as? String ?? ""
    let covers = (row["images"] as? [[String: Any]] ?? []).prefix(CPMaximumNumberOfGridImages)
    let placeholder = Self.placeholder
    let item: CPListImageRowItem
    if #available(iOS 26.0, *) {
      let elements = covers.map {
        CPListImageRowItemRowElement(
          image: placeholder, title: $0["title"] as? String, subtitle: $0["subtitle"] as? String)
      }
      item = CPListImageRowItem(text: title, elements: elements, allowsMultipleLines: false)
    } else if #available(iOS 17.4, *) {
      item = CPListImageRowItem(
        text: title,
        images: covers.map { _ in placeholder },
        imageTitles: covers.map { $0["title"] as? String ?? "" }
      )
    } else {
      item = CPListImageRowItem(text: title, images: covers.map { _ in placeholder })
    }
    var images = covers.map { _ in placeholder }
    for (index, cover) in covers.enumerated() {
      guard let image = cover["image"] as? String, let url = URL(string: image) else { continue }
      loadImage(url) { [weak item] loaded in
        guard let item else { return }
        if #available(iOS 26.0, *) {
          // Elements are objects the row keeps: change one, hand them back.
          let elements = item.elements
          guard elements.indices.contains(index) else { return }
          elements[index].image = loaded
          item.elements = elements
        } else {
          images[index] = loaded
          item.update(images)
        }
      }
    }
    let ids = covers.map { $0["id"] as? String ?? "" }
    item.listImageRowHandler = { [weak self] _, index, completion in
      guard let self, ids.indices.contains(index) else { return completion() }
      self.play(id: ids[index], completion: completion)
    }
    if let id = row["id"] as? String {
      item.handler = { [weak self] _, completion in
        guard let self else { return completion() }
        self.push(id: id, title: title, completion: completion)
      }
    }
    return item
  }

  private static let placeholder: UIImage = {
    let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .light)
    return UIImage(systemName: "music.note", withConfiguration: config) ?? UIImage()
  }()

  private func push(id: String, title: String, completion: @escaping () -> Void) {
    guard let interfaceController else { return completion() }
    interfaceController.pushTemplate(listTemplate(id: id, title: title), animated: true) { _, _ in completion() }
  }

  // MARK: - Playing

  private func play(id: String, completion: @escaping () -> Void) {
    invokeForProblem("play", arguments: ["id": id]) { [weak self] problem in
      defer { completion() }
      guard let self else { return }
      if let problem { return self.alert(problem) }
      self.showNowPlaying()
    }
  }

  /// Calls [method], whose answer is null or a problem to show.
  private func invokeForProblem(_ method: String, arguments: Any?, then: @escaping (String?) -> Void) {
    guard let channel else { return then("Open Plezy on your iPhone") }
    channel.invokeMethod(method, arguments: arguments) { result in
      if let problem = result as? String { return then(problem) }
      if result is FlutterError || (result as AnyObject) === FlutterMethodNotImplemented {
        return then("Open Plezy on your iPhone")
      }
      then(nil)
    }
  }

  /// Now Playing on top: back to it when it is already in the stack (as
  /// under Up Next), pushed otherwise.
  private func showNowPlaying() {
    guard let interfaceController else { return }
    let nowPlaying = CPNowPlayingTemplate.shared
    if interfaceController.topTemplate === nowPlaying { return }
    if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
      interfaceController.pop(to: nowPlaying, animated: true, completion: nil)
    } else {
      interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
    }
  }

  private func alert(_ message: String) {
    guard let interfaceController, interfaceController.presentedTemplate == nil else { return }
    let alert = CPAlertTemplate(
      titleVariants: [message],
      actions: [
        CPAlertAction(title: "OK", style: .cancel) { [weak interfaceController] _ in
          interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
      ]
    )
    interfaceController.presentTemplate(alert, animated: true, completion: nil)
  }

  // MARK: - Now Playing

  private func configureNowPlaying() {
    guard !nowPlayingConfigured else { return }
    nowPlayingConfigured = true
    let nowPlaying = CPNowPlayingTemplate.shared
    nowPlaying.add(self)
    nowPlaying.upNextTitle = "Up Next"
    nowPlaying.isUpNextButtonEnabled = true
    updateNowPlayingButtons()
  }

  private func apply(_ new: NowPlayingState) {
    let old = state
    state = new
    if old.trackKey != new.trackKey { markPlaying() }
    if old != new { updateNowPlayingButtons() }
  }

  private func updateNowPlayingButtons() {
    guard nowPlayingConfigured else { return }
    // The system draws shuffle and repeat from what the app reports here.
    let commands = MPRemoteCommandCenter.shared()
    commands.changeShuffleModeCommand.currentShuffleType = state.shuffled ? .items : .off
    commands.changeRepeatModeCommand.currentRepeatType =
      switch state.repeatMode {
      case "all": .all
      case "one": .one
      default: .off
      }

    let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
      self?.channel?.invokeMethod("toggleShuffle", arguments: nil)
    }
    let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
      self?.channel?.invokeMethod("cycleRepeat", arguments: nil)
    }
    var buttons: [CPNowPlayingButton] = [shuffle, repeatButton]
    if state.radio, let image = UIImage(systemName: "dot.radiowaves.left.and.right") {
      buttons.append(CPNowPlayingImageButton(image: image) { [weak self] _ in self?.startRadio() })
    }
    let nowPlaying = CPNowPlayingTemplate.shared
    nowPlaying.updateNowPlayingButtons(buttons)
    nowPlaying.isAlbumArtistButtonEnabled = state.artist
  }

  /// A station seeded by the playing song.
  private func startRadio() {
    invokeForProblem("radio", arguments: nil) { [weak self] problem in
      if let problem { self?.alert(problem) }
    }
  }

  private func markPlaying() {
    trackItems.removeAll { $0.item.value == nil }
    for (key, weakItem) in trackItems {
      weakItem.value?.isPlaying = key == state.trackKey
    }
  }

  private func loadImage(_ url: URL, apply: @escaping (UIImage) -> Void) {
    imageSession.dataTask(with: url) { data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async { apply(image) }
    }.resume()
  }
}

extension CarPlayController: CPInterfaceControllerDelegate {
  /// Lists that came up empty (the server was still connecting) or have gone
  /// stale are fetched again as they come back into view. Up Next always is:
  /// the queue moves on while it is hidden.
  func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
    guard let list = aTemplate as? CPListTemplate, let info = list.userInfo as? ListInfo else { return }
    let stale = Date().timeIntervalSince(info.loadedAt) > Self.staleAfter
    if info.id == Self.upNextId || !info.hadRows || stale {
      // A list that just loaded is already fresh.
      if Date().timeIntervalSince(info.loadedAt) > 1 { load(list) }
    }
  }
}

extension CarPlayController: CPNowPlayingTemplateObserver {
  func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    push(id: Self.upNextId, title: "Up Next") {}
  }

  func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    channel?.invokeMethod("currentArtist", arguments: nil) { [weak self] result in
      guard let self, let artist = result as? [String: String], let id = artist["id"] else { return }
      self.push(id: id, title: artist["title"] ?? "") {}
    }
  }
}

/// What a list was made from, so it can be fetched again.
private final class ListInfo {
  let id: String
  var loadedAt = Date()
  var hadRows = false

  init(id: String) { self.id = id }
}

private final class WeakItem {
  weak var value: CPListItem?
  init(_ value: CPListItem) { self.value = value }
}

/// The playing session as Dart reports it (`CarPlayBridge.nowPlaying`).
private struct NowPlayingState: Equatable {
  var trackKey: String?
  var shuffled = false
  var repeatMode = "off"
  var radio = false
  var artist = false

  init() {}

  init(_ arguments: Any?) {
    guard let map = arguments as? [String: Any] else { return }
    trackKey = map["trackKey"] as? String
    shuffled = map["shuffled"] as? Bool ?? false
    repeatMode = map["repeat"] as? String ?? "off"
    radio = map["radio"] as? Bool ?? false
    artist = map["artist"] as? Bool ?? false
  }
}
