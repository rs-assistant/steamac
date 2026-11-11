import Darwin
import Foundation

enum StreamSelfTest {
    /// `networkOnly` (--selftest-stream-net): the LAN filter, pairing window, HTTP limits and the
    /// HTTP/pairing check on loopback; no screen capture or hardware encoding, so CI's macOS VMs
    /// can run it.
    static func run(networkOnly: Bool = false) -> Never {
        let all: [(String, () -> [String])] = [
            ("LAN filter", LANNetworks.selfCheck),
            ("pairing window", StreamPairingWindow.selfCheck),
            ("HTTP connection limits", StreamHTTPLimits.selfCheck),
            ("HTTP and pairing", StreamHTTPServer.selfCheck),
            ("control", StreamControl.selfCheck),
            ("RTSP", StreamRTSP.selfCheck),
            ("input", StreamInput.selfCheck),
            ("capture", StreamCapture.selfCheck),
            ("video", StreamVideoStream.selfCheck),
            ("audio", StreamAudioStream.selfCheck),
        ]
        let network: Set<String> = ["LAN filter", "pairing window", "HTTP connection limits", "HTTP and pairing"]
        let components = networkOnly ? all.filter { network.contains($0.0) } : all
        var failures = 0
        for (name, run) in components {
            let errors = run()
            print("stream selftest: \(errors.isEmpty ? "PASS" : "FAIL") \(name)")
            for error in errors { print("stream selftest: FAIL \(name): \(error)") }
            failures += errors.count
        }
        print("stream selftest: \(components.count) components, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
