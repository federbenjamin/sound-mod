import Foundation

/// The echoes stemmix still expects of its own actions: each own action expects one event of its kind by a
/// deadline, and a matching event inside the window is stemmix's own, not the user's. Oldest first.
struct PendingEchoes<Key: Equatable>: Equatable {
  private var entries: [Entry] = []

  private struct Entry: Equatable {
    let key: Key
    let until: TimeInterval
  }

  var isEmpty: Bool { entries.isEmpty }

  mutating func expect(_ key: Key, until: TimeInterval) {
    entries.append(Entry(key: key, until: until))
  }

  /// Whether `key`'s event at `now` is an expected echo; consumes the oldest one when it is.
  mutating func claim(_ key: Key, at now: TimeInterval) -> Bool {
    entries.removeAll { $0.until < now }
    guard let index = entries.firstIndex(where: { $0.key == key }) else { return false }
    entries.remove(at: index)
    return true
  }

  func isPending(_ key: Key, at now: TimeInterval) -> Bool {
    entries.contains { $0.key == key && $0.until >= now }
  }

  /// Drops the echoes whose window has passed and returns their keys, oldest first.
  mutating func expire(at now: TimeInterval) -> [Key] {
    let expired = entries.filter { $0.until < now }.map(\.key)
    entries.removeAll { $0.until < now }
    return expired
  }
}
