import SwiftUI

/// Uploads and downloads for one host: up to three at once, the rest queued,
/// each with progress and cancel. Callers await the outcome.
@MainActor @Observable
final class Transfers {
  static let concurrent = 3

  struct Item: Identifiable {
    let id = UUID()
    var name: String
    var upload: Bool
    var progress: Double = 0
    var running = false
    var failure: String?
  }

  typealias Work = @MainActor (_ progress: @escaping @MainActor (Double) -> Void) async throws -> Void

  private(set) var items: [Item] = []
  @ObservationIgnored private var work: [UUID: Work] = [:]
  @ObservationIgnored private var waiting: [UUID: CheckedContinuation<Result<Void, RemoteFSError>, Never>] = [:]
  @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

  /// Queues `work` and returns once it finished, failed or was cancelled.
  func run(_ name: String, upload: Bool, _ work: @escaping Work) async throws {
    let item = Item(name: name, upload: upload)
    let result = await withCheckedContinuation { continuation in
      items.append(item)
      self.work[item.id] = work
      waiting[item.id] = continuation
      pump()
    }
    try result.get()
  }

  func cancel(_ id: UUID) {
    if let task = tasks[id] {
      task.cancel()
    } else {
      finish(id, .failure(.cancelled))
    }
  }

  /// A failed row stays until dismissed.
  func dismiss(_ id: UUID) {
    items.removeAll { $0.id == id }
  }

  private func pump() {
    while items.filter(\.running).count < Self.concurrent,
          let next = items.firstIndex(where: { !$0.running && $0.failure == nil && work[$0.id] != nil }) {
      let id = items[next].id
      items[next].running = true
      guard let job = work.removeValue(forKey: id) else { continue }
      tasks[id] = Task { [weak self] in
        let result: Result<Void, RemoteFSError>
        do {
          try await job { [weak self] fraction in self?.setProgress(id, fraction) }
          result = .success(())
        } catch let error as RemoteFSError {
          result = .failure(error)
        } catch {
          result = .failure(.failed(error.localizedDescription))
        }
        self?.finish(id, result)
      }
    }
  }

  private func setProgress(_ id: UUID, _ fraction: Double) {
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    items[i].progress = fraction
  }

  private func finish(_ id: UUID, _ result: Result<Void, RemoteFSError>) {
    tasks[id] = nil
    work[id] = nil
    if case .failure(let error) = result, error != .cancelled, let i = items.firstIndex(where: { $0.id == id }) {
      items[i].running = false
      items[i].failure = error.message
    } else {
      items.removeAll { $0.id == id }
    }
    waiting.removeValue(forKey: id)?.resume(returning: result)
    pump()
  }
}

/// The transfers strip under the list: one hairline row per transfer.
struct TransfersStrip: View {
  let transfers: Transfers

  var body: some View {
    if !transfers.items.isEmpty {
      VStack(spacing: 0) {
        ForEach(transfers.items) { item in
          row(item)
          if item.id != transfers.items.last?.id { Helm.line.frame(height: 1) }
        }
      }
      .background(Helm.bg.opacity(0.92))
      .overlay(alignment: .top) { Helm.line2.frame(height: 1) }
      .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private func row(_ item: Transfers.Item) -> some View {
    HStack(spacing: 10) {
      Image(systemName: item.upload ? "arrow.up" : "arrow.down")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(item.failure == nil ? Helm.fg2 : Helm.bad)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text(item.name).font(Helm.sans(13, .medium)).foregroundStyle(Helm.fg).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 8)
          if let failure = item.failure {
            Text(failure).font(Helm.mono(11)).foregroundStyle(Helm.bad).lineLimit(1)
          } else {
            Text(item.running ? "\(Int((item.progress * 100).rounded()))%" : "Waiting")
              .font(Helm.mono(11)).foregroundStyle(Helm.muted)
          }
        }
        if item.failure == nil {
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule().fill(Helm.line2)
              Capsule().fill(Helm.fg2).frame(width: max(2, geo.size.width * item.progress))
            }
          }
          .frame(height: 2)
        }
      }
      Button {
        if item.failure != nil { transfers.dismiss(item.id) } else { transfers.cancel(item.id) }
      } label: {
        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Helm.muted)
          .frame(width: 30, height: 30).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(item.failure == nil ? "Cancel \(item.name)" : "Dismiss")
    }
    .padding(.leading, 16)
    .padding(.trailing, 8)
    .frame(height: 48)
  }
}
