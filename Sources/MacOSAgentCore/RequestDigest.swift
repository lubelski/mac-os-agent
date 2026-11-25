import CryptoKit
import Foundation

/// Short digests of what a request sent, in the order the model reads it: the tool list first,
/// then each input item. Two requests share a cached prefix only as far as their digests agree,
/// so comparing one request's digests with the next one's says where the prefix changed.
///
/// A digest is taken over an item's encoded bytes, sorted keys and all, which are the bytes in
/// the request body. It holds no content and cannot be turned back into any.
public enum RequestDigest {
    /// The digest of the tool list, then one per input item.
    public static func make(tools: JSONValue?, input: [JSONValue]) -> [String] {
        [digest(tools ?? .array([]))] + input.map(digest)
    }

    /// Where `current` stops starting with `previous`: the index of the first digest that
    /// differs, or of the first one `current` lacks. Nil when `previous` is a prefix of
    /// `current`, which is the case the prompt cache needs.
    public static func firstDifference(previous: [String], current: [String]) -> Int? {
        for index in previous.indices {
            guard index < current.count, previous[index] == current[index] else { return index }
        }
        return nil
    }

    static func digest(_ value: JSONValue) -> String {
        let hash = SHA256.hash(data: Data(value.encodedString().utf8))
        return hash.prefix(3).map { String(format: "%02x", $0) }.joined()
    }
}

/// Which Mac and which build wrote a usage line, since the agent runs on more than one Mac and
/// the lines from each are compared. It names nothing personal: the first characters of the
/// installation id, the hardware model, and the app's version.
public struct UsageDevice: Sendable, Equatable {
    /// The first 8 characters of the installation id, which is the same for every launch of
    /// this copy of the app's data folder.
    public var device: String
    /// The hardware model, such as `Mac15,3`, which tells a laptop from a desktop.
    public var machine: String
    /// The app's version and build, such as `0.12 (52)`.
    public var build: String

    public init(device: String, machine: String, build: String) {
        self.device = device
        self.machine = machine
        self.build = build
    }

    /// This Mac, read once.
    public static let thisMac = UsageDevice(
        device: String(AgentPaths.installationID().uuidString.lowercased().prefix(8)),
        machine: hardwareModel(),
        build: appBuild())

    static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func appBuild(_ bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
