import Carbon
import Foundation

let bundleID = "dev.ensan.inputmethod.iroha"
let legacyBundleIDs = [
    "dev.ensan.inputmethod.azooKeyMac",
    "dev.ensan.inputmethod.azooKey",
]
let inputMode = "com.apple.inputmethod.Japanese"
let targetID = "dev.ensan.inputmethod.iroha.Japanese" as CFString
let filter = [
    kTISPropertyInputSourceID as String: targetID
] as CFDictionary

let hitoolboxDefaults = UserDefaults(suiteName: "com.apple.HIToolbox")
let inputsourcesDefaults = UserDefaults(suiteName: "com.apple.inputsources")
let enabledSources = (hitoolboxDefaults?.array(forKey: "AppleEnabledInputSources") as? [[String: Any]] ?? [])
    .filter { source in
        guard let sourceBundleID = source["Bundle ID"] as? String else {
            return true
        }
        return sourceBundleID != bundleID && !legacyBundleIDs.contains(sourceBundleID)
    }

var enabledThirdPartySources = (inputsourcesDefaults?.array(forKey: "AppleEnabledThirdPartyInputSources") as? [[String: Any]] ?? [])
    .filter { source in
        guard let sourceBundleID = source["Bundle ID"] as? String else {
            return true
        }
        return sourceBundleID != bundleID && !legacyBundleIDs.contains(sourceBundleID)
    }

func containsSource(kind: String, mode: String? = nil) -> Bool {
    enabledThirdPartySources.contains { source in
        guard source["Bundle ID"] as? String == bundleID,
              source["InputSourceKind"] as? String == kind else {
            return false
        }
        if let mode {
            return source["Input Mode"] as? String == mode
        }
        return true
    }
}

if !containsSource(kind: "Input Mode", mode: inputMode) {
    enabledThirdPartySources.append([
        "Bundle ID": bundleID,
        "Input Mode": inputMode,
        "InputSourceKind": "Input Mode",
    ])
}

if !containsSource(kind: "Keyboard Input Method") {
    enabledThirdPartySources.append([
        "Bundle ID": bundleID,
        "InputSourceKind": "Keyboard Input Method",
    ])
}

func writePreference(_ value: Any, key: String, domain: String) {
    CFPreferencesSetValue(
        key as CFString,
        value as CFPropertyList,
        domain as CFString,
        kCFPreferencesCurrentUser,
        kCFPreferencesAnyHost
    )
    CFPreferencesAppSynchronize(domain as CFString)
}

hitoolboxDefaults?.set(enabledSources, forKey: "AppleEnabledInputSources")
inputsourcesDefaults?.set(enabledThirdPartySources, forKey: "AppleEnabledThirdPartyInputSources")
writePreference(enabledSources, key: "AppleEnabledInputSources", domain: "com.apple.HIToolbox")
writePreference(enabledThirdPartySources, key: "AppleEnabledThirdPartyInputSources", domain: "com.apple.inputsources")

let selectedSources = [
    [
        "Bundle ID": "com.apple.PressAndHold",
        "InputSourceKind": "Non Keyboard Input Method",
    ],
    [
        "Bundle ID": bundleID,
        "Input Mode": inputMode,
        "InputSourceKind": "Input Mode",
    ],
    [
        "Bundle ID": bundleID,
        "InputSourceKind": "Keyboard Input Method",
    ],
]
hitoolboxDefaults?.set(selectedSources, forKey: "AppleSelectedInputSources")
writePreference(selectedSources, key: "AppleSelectedInputSources", domain: "com.apple.HIToolbox")
hitoolboxDefaults?.synchronize()
inputsourcesDefaults?.synchronize()

func currentInputSourceID() -> String? {
    guard let selected = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let idPointer = TISGetInputSourceProperty(selected, kTISPropertyInputSourceID) else {
        return nil
    }
    return Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
}

for attempt in 1...20 {
    guard let sourceList = TISCreateInputSourceList(filter, true) else {
        print("Selection attempt \(attempt): TISCreateInputSourceList returned nil")
        Thread.sleep(forTimeInterval: 0.5)
        continue
    }
    let sources = sourceList.takeRetainedValue() as! [TISInputSource]
    if let source = sources.first {
        let enableStatus = TISEnableInputSource(source)
        guard enableStatus == noErr else {
            fputs("TISEnableInputSource failed: \(enableStatus)\n", stderr)
            exit(Int32(enableStatus))
        }

        let status = TISSelectInputSource(source)
        guard status == noErr else {
            fputs("TISSelectInputSource failed: \(status)\n", stderr)
            exit(Int32(status))
        }

        let currentID = currentInputSourceID()
        if currentID == targetID as String {
            print("Selected input source: \(currentID!)")
            exit(0)
        }
        print("Selection attempt \(attempt) returned current input source: \(currentID ?? "nil")")
    } else {
            print("Selection attempt \(attempt): iroha Japanese input source was not found")
    }
    Thread.sleep(forTimeInterval: 0.5)
}

fputs("Could not select iroha Japanese input source; current=\(currentInputSourceID() ?? "nil")\n", stderr)
exit(1)
