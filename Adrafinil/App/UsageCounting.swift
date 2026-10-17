import AdrafinilShared
import Digoxin
import Foundation
import OSLog

/// How many people use Adrafinil, and Adrafinil's own crashes, through Digoxin at the tier the
/// person chose (``tier``).
///
/// A check-in carries the versions, the chip family, the memory class, the language, the count
/// of days used in the last week, and the two properties in ``properties()``. It names no agent
/// and nothing that was worked on.
nonisolated enum UsageCounting {
    static let app = "adrafinil"

    /// Production for a release build. A Debug build reports to a Digoxin on this Mac, or to
    /// the one `ADRAFINIL_DIGOXIN_URL` names.
    static let baseURL: URL = {
        #if DEBUG
            ProcessInfo.processInfo.environment["ADRAFINIL_DIGOXIN_URL"].flatMap(URL.init(string:))
                ?? URL(string: "http://127.0.0.1:9130/api/digoxin")!
        #else
            URL(string: "https://kagerou.glass/api/digoxin")!
        #endif
    }()

    private static let log = Logger(subsystem: AdrafinilConstants.appBundleID, category: "usage-counting")

    static let client = Digoxin(configuration: .init(
        app: app,
        baseURL: baseURL,
        storageDirectory: AdrafinilConstants.appSupportURL,
        propertiesProvider: { properties() },
        log: { log.info("\($0, privacy: .public)") },
    ))

    /// The two keys the server keeps for this app; any other key is dropped there.
    /// `closedLid` is whether this Mac has a lid, so holds carry through a closed one.
    /// `agentKinds7d` is how many kinds of agent held an assertion in the last 7 days,
    /// a count only: which kinds stays on this Mac (``AgentKindsSeen``).
    static func properties() -> [String: TelemetryValue] {
        [
            "closedLid": .bool(DeviceCapabilities.current.hasLid),
            "agentKinds7d": .int(AgentKindsSeen.countInLastWeek()),
        ]
    }

    /// At launch: applies the stored tier, sends the reports of crashes since the last look, and
    /// counts the day.
    static func start() {
        Task.detached(name: "Usage counting at launch") {
            await client.setTier(tier ?? .off)
            await submitOwnCrashes()
            await client.recordUse()
        }
    }

    /// The popover opened: counts the day, and sends a crash that happened while the app stayed up.
    static func noteUse() {
        Task.detached(name: "Usage counting on use") {
            await submitOwnCrashes()
            await client.recordUse()
        }
    }

    /// The person's choice, from the question card or Settings.
    static func choose(_ newTier: ConsentTier) {
        let previous = tier
        tier = newTier
        // Crashes before the choice are not the choice's to send.
        if newTier == .crashReports, previous != .crashReports {
            ownCrashesCheckedAt = Date()
        }
        log.info("chose \(newTier.rawValue, privacy: .public)")
        Task.detached(name: "Apply the usage counting tier") {
            await client.setTier(newTier)
            if newTier != .off { await client.recordUse() }
        }
    }

    /// One report per crash of the app, the daemon or the helper since the last look, at the
    /// crash-reports tier; the look moves forward at every tier, so turning reports on later
    /// sends nothing from before.
    private static func submitOwnCrashes() async {
        let now = Date()
        let since = ownCrashesCheckedAt
        ownCrashesCheckedAt = now
        guard tier == .crashReports, let since else { return }
        let found = OwnCrashReports.processNames.flatMap {
            DiagnosticReports.reports(forProcess: $0, after: since)
        }
        for report in OwnCrashReports.ours(found, identity: .running) {
            await client.submitCrashReport(files: [report])
        }
    }

    // MARK: - Stored choice

    /// The Digoxin tier the person chose; `nil` until they have been asked, which is what makes
    /// the question appear once.
    static var tier: ConsentTier? {
        get { UserDefaults.standard.string(forKey: tierKey).flatMap(ConsentTier.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: tierKey) }
    }

    static let tierKey = "usageCounting"

    /// When the crash reports of the app, the daemon and the helper were last looked for:
    /// reports written after it are the ones not yet sent.
    static var ownCrashesCheckedAt: Date? {
        get { UserDefaults.standard.object(forKey: "usageCountingCrashesCheckedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "usageCountingCrashesCheckedAt") }
    }
}

// MARK: - Agent kinds seen

/// Which kinds of agent held an assertion lately, kept on this Mac so a check-in can carry
/// their number. The record itself never leaves: only ``countInLastWeek()`` is sent.
nonisolated enum AgentKindsSeen {
    private static let key = "usageCountingAgentKindsSeen"
    private static let window: TimeInterval = 7 * 24 * 3_600
    /// A kind stamped this recently is not stamped again, so a live popover (one status every
    /// 5 s) does not rewrite the defaults on every tick.
    private static let restampAfter: TimeInterval = 3_600

    /// Stamps every agent kind among `assertions` with `now`.
    static func note(_ assertions: [Assertion], now: Date = Date()) {
        let kinds = Set(assertions.compactMap { AgentKind(rawValue: $0.tool) })
        guard !kinds.isEmpty else { return }
        var seen = stored()
        let stale = kinds.filter { now.timeIntervalSince(seen[$0.rawValue] ?? .distantPast) > restampAfter }
        guard !stale.isEmpty else { return }
        for kind in stale {
            seen[kind.rawValue] = now
        }
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
        UserDefaults.standard.set(seen, forKey: key)
    }

    /// How many distinct kinds held an assertion in the last 7 days.
    static func countInLastWeek(now: Date = Date()) -> Int {
        stored().values.count { now.timeIntervalSince($0) < window }
    }

    private static func stored() -> [String: Date] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Date]) ?? [:]
    }
}

// MARK: - Yesterday's count

/// Yesterday's count of Macs that counted themselves in, from the service's one public route,
/// fetched once per process. A failure shows nothing and is tried again an hour later.
actor ActiveCount {
    static let shared = ActiveCount()

    private var cached: Int?
    private var failedAt: Date?
    private static let retryAfter: TimeInterval = 3_600

    private struct Response: Decodable {
        var app: String
        var day: String
        var active: Int
    }

    func value() async -> Int? {
        if let cached { return cached }
        if let failedAt, Date().timeIntervalSince(failedAt) < Self.retryAfter { return nil }
        let url = UsageCounting.baseURL.appending(path: "v1/\(UsageCounting.app)/active")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let count = try JSONDecoder().decode(Response.self, from: data).active
            cached = count
            return count
        } catch {
            failedAt = Date()
            return nil
        }
    }
}

// MARK: - Own crash reports

/// Which of the crash reports macOS wrote belong to this copy of Adrafinil.
///
/// A Debug build and the installed app share the bundle identifier and run under the same
/// process names, and macOS writes `procPath` with the home folder masked (`/Users/USER/…`), so
/// neither tells them apart. The header line's `slice_uuid` does: every crash names the UUID
/// of the image that crashed, and each build's images have their own.
nonisolated enum OwnCrashReports {
    /// The app, the user daemon inside it, and the privileged helper. The helper runs as root,
    /// so macOS writes its reports under `/Library/Logs`, where ``DiagnosticReports`` does not
    /// look; its name is here for the day it does.
    static let processNames = ["Adrafinil", "AdrafinilDaemon", "AdrafinilHelper"]

    /// `bug_type` of a crash. A hang or a spin is written under other types.
    static let crashBugType = "309"

    /// What this copy's crashes carry in their header line.
    struct Identity: Equatable {
        /// The Mach-O UUIDs of the app, the daemon and the helper, uppercase.
        var imageUUIDs: Set<String>

        static var running: Identity {
            let bundle = Bundle.main.bundleURL
            let daemon = bundle.appending(path: "Contents/Library/LaunchAgents/AdrafinilDaemon")
            let helper = bundle.appending(path: "Contents/Library/LaunchDaemons/AdrafinilHelper")
            return Identity(imageUUIDs: Set(
                [MachOIdentity.ofThisProcess, MachOIdentity.ofFile(daemon), MachOIdentity.ofFile(helper)]
                    .compactMap(\.self),
            ))
        }
    }

    /// The crashes among `reports` that are this copy's.
    static func ours(_ reports: [URL], identity: Identity) -> [URL] {
        reports.filter { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return isCrash(data, of: identity)
        }
    }

    /// Whether an `.ips` file (a JSON header line, then the JSON body) is a crash of an image
    /// `identity` names.
    static func isCrash(_ ips: Data, of identity: Identity) -> Bool {
        let line = ips.prefix { $0 != UInt8(ascii: "\n") }
        guard let header = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              header["bug_type"] as? String == crashBugType,
              let uuid = header["slice_uuid"] as? String
        else { return false }
        return identity.imageUUIDs.contains(uuid.uppercased())
    }
}
