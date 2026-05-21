import Foundation

let targetHomePath = ProcessInfo.processInfo.environment["TARGET_HOME"]
let home = targetHomePath.map(URL.init(fileURLWithPath:)) ?? FileManager.default.homeDirectoryForCurrentUser
let inputsourcesURL = home.appendingPathComponent("Library/Preferences/com.apple.inputsources.plist")
let hitoolboxURL = home.appendingPathComponent("Library/Preferences/com.apple.HIToolbox.plist")

let irohaBundleID = "dev.ensan.inputmethod.iroha"
let legacyBundleIDs: Set<String> = [
    "dev.ensan.inputmethod.azooKeyMac",
    "dev.ensan.inputmethod.azooKey",
]
let inputMode = "com.apple.inputmethod.Japanese"

func loadPlist(_ url: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return [:]
    }
    let data = try Data(contentsOf: url)
    return try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] ?? [:]
}

func savePlist(_ plist: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    try data.write(to: url, options: .atomic)
}

func filteredSources(_ sources: [[String: Any]]) -> [[String: Any]] {
    var seen = Set<String>()
    return sources.filter { source in
        guard let bundleID = source["Bundle ID"] as? String else {
            let key = source
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "|")
            return seen.insert(key).inserted
        }
        guard bundleID != irohaBundleID && !legacyBundleIDs.contains(bundleID) else {
            return false
        }
        let key = [
            source["InputSourceKind"] as? String ?? "",
            bundleID,
            source["Input Mode"] as? String ?? "",
        ].joined(separator: "|")
        return seen.insert(key).inserted
    }
}

func source(bundleID: String, inputMode: String? = nil, kind: String) -> [String: Any] {
    var item: [String: Any] = [
        "Bundle ID": bundleID,
        "InputSourceKind": kind,
    ]
    if let inputMode {
        item["Input Mode"] = inputMode
    }
    return item
}

var inputsources = try loadPlist(inputsourcesURL)
var thirdParty = filteredSources(inputsources["AppleEnabledThirdPartyInputSources"] as? [[String: Any]] ?? [])
thirdParty.append(source(bundleID: irohaBundleID, inputMode: inputMode, kind: "Input Mode"))
thirdParty.append(source(bundleID: irohaBundleID, kind: "Keyboard Input Method"))
inputsources["AppleEnabledThirdPartyInputSources"] = thirdParty
try savePlist(inputsources, to: inputsourcesURL)

var hitoolbox = try loadPlist(hitoolboxURL)
hitoolbox["AppleEnabledInputSources"] = filteredSources(hitoolbox["AppleEnabledInputSources"] as? [[String: Any]] ?? [])
hitoolbox["AppleInputSourceHistory"] = filteredSources(hitoolbox["AppleInputSourceHistory"] as? [[String: Any]] ?? [])
hitoolbox["AppleSelectedInputSources"] = [
    source(bundleID: "com.apple.PressAndHold", kind: "Non Keyboard Input Method"),
    source(bundleID: irohaBundleID, inputMode: inputMode, kind: "Input Mode"),
]
hitoolbox["AppleInputSourceHistory"] = [
    source(bundleID: irohaBundleID, inputMode: inputMode, kind: "Input Mode"),
]
try savePlist(hitoolbox, to: hitoolboxURL)

print("Updated input source preferences for iroha.")
