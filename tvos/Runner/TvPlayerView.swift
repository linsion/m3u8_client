import AVFoundation
import AVKit
import SwiftUI

struct TvPlayerModalView: View {
  @EnvironmentObject var appState: TvAppState
  let request: TvPlaybackRequest

  var body: some View {
    TvAVPlayerContainer(
      request: request,
      onProgress: { pos, dur in
        guard !request.isLive,
              let detail = request.vodDetail,
              request.playGroupIndex < detail.playGroups.count else { return }
        let group = detail.playGroups[request.playGroupIndex]
        guard request.episodeIndex < group.episodes.count else { return }
        let ep = group.episodes[request.episodeIndex]
        appState.recordPlaybackProgress(
          source: request.vodSource,
          detail: detail,
          groupName: group.name,
          episodeTitle: ep.title,
          position: pos,
          duration: dur
        )
      },
      onFinished: {
        guard !request.isLive,
              let source = request.vodSource,
              let detail = request.vodDetail,
              request.playGroupIndex < detail.playGroups.count else { return }
        let group = detail.playGroups[request.playGroupIndex]
        let nextIndex = request.episodeIndex + 1
        if nextIndex < group.episodes.count {
          Task {
            await appState.startEpisodePlayback(
              source: source,
              detail: detail,
              groupIndex: request.playGroupIndex,
              episodeIndex: nextIndex
            )
          }
        }
      }
    )
    .ignoresSafeArea()
  }
}

struct TvAVPlayerContainer: UIViewControllerRepresentable {
  let request: TvPlaybackRequest
  let onProgress: (Double, Double) -> Void
  let onFinished: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onProgress: onProgress, onFinished: onFinished)
  }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.showsPlaybackControls = true
    context.coordinator.configurePlayer(for: request, in: controller)
    return controller
  }

  func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
    if context.coordinator.currentRequestId != request.id {
      context.coordinator.configurePlayer(for: request, in: uiViewController)
    }
  }

  static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
    coordinator.cleanup()
    uiViewController.player?.pause()
    uiViewController.player = nil
  }

  final class Coordinator: NSObject {
    var currentRequestId: UUID?
    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var didFallbackToProxy = false
    private let onProgress: (Double, Double) -> Void
    private let onFinished: () -> Void

    init(onProgress: @escaping (Double, Double) -> Void, onFinished: @escaping () -> Void) {
      self.onProgress = onProgress
      self.onFinished = onFinished
    }

    func configurePlayer(for request: TvPlaybackRequest, in controller: AVPlayerViewController) {
      cleanup()
      currentRequestId = request.id
      didFallbackToProxy = false
      loadStream(
        urlStr: request.streamUrl,
        headers: request.headers,
        request: request,
        controller: controller
      )
    }

    private func loadStream(
      urlStr: String,
      headers: [String: String],
      request: TvPlaybackRequest,
      controller: AVPlayerViewController
    ) {
      guard let url = URL(string: urlStr) else { return }

      var options: [String: Any] = [:]
      if !headers.isEmpty && !url.isFileURL {
        options["AVURLAssetHTTPHeaderFieldsKey"] = headers
      }
      let asset = AVURLAsset(url: url, options: options)
      let item = AVPlayerItem(asset: asset)

      let titleMeta = AVMutableMetadataItem()
      titleMeta.identifier = .commonIdentifierTitle
      titleMeta.value = request.title as NSString
      titleMeta.extendedLanguageTag = "und"

      let subMeta = AVMutableMetadataItem()
      subMeta.identifier = .commonIdentifierDescription
      subMeta.value = request.subtitle as NSString
      subMeta.extendedLanguageTag = "und"
      item.externalMetadata = [titleMeta, subMeta]

      let avPlayer: AVPlayer
      if let existing = controller.player {
        existing.replaceCurrentItem(with: item)
        avPlayer = existing
      } else {
        avPlayer = AVPlayer(playerItem: item)
        controller.player = avPlayer
      }
      self.player = avPlayer

      statusObservation = item.observe(\.status, options: [.new]) { [weak self, weak avPlayer, weak controller] observedItem, _ in
        guard let self = self else { return }
        switch observedItem.status {
        case .readyToPlay:
          if request.resumeSeconds > 5 && !request.isLive {
            let target = CMTime(seconds: request.resumeSeconds, preferredTimescale: 600)
            avPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
          }
          avPlayer?.play()
        case .failed:
          if !self.didFallbackToProxy,
             !request.backupProxyUrl.isEmpty,
             request.backupProxyUrl != urlStr,
             let controller = controller {
            self.didFallbackToProxy = true
            DispatchQueue.main.async {
              self.loadStream(
                urlStr: request.backupProxyUrl,
                headers: request.headers,
                request: request,
                controller: controller
              )
            }
          }
        default:
          break
        }
      }

      let interval = CMTime(seconds: 5, preferredTimescale: 600)
      timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak avPlayer] time in
        guard let self = self, let player = avPlayer, let currentItem = player.currentItem else { return }
        let sec = CMTimeGetSeconds(time)
        let dur = CMTimeGetSeconds(currentItem.duration)
        if sec.isFinite && sec > 0 {
          self.onProgress(sec, dur.isFinite && dur > 0 ? dur : 0)
        }
      }

      endObserver = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime,
        object: item,
        queue: .main
      ) { [weak self] _ in
        self?.onFinished()
      }

      avPlayer.play()
    }

    func cleanup() {
      statusObservation?.invalidate()
      statusObservation = nil
      if let obs = timeObserver, let player = player {
        player.removeTimeObserver(obs)
      }
      timeObserver = nil
      if let endObs = endObserver {
        NotificationCenter.default.removeObserver(endObs)
      }
      endObserver = nil
    }

    deinit {
      cleanup()
    }
  }
}
