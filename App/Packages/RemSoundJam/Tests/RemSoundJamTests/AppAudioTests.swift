import Foundation
import XCTest

@testable import RemSoundJam

/// Sending chosen applications: which sound processes are an application's, and the two lists Windows shows.
final class AppAudioTests: XCTestCase {
    let apps: Set<String> = ["com.google.Chrome", "com.spotify.client", "us.zoom.xos", "com.apple.Safari"]

    func testAHelpersSoundIsItsApplicationsAndOnlyAWholeBundleNameCounts() {
        XCTAssertEqual(AppAudio.owner(of: "com.google.Chrome.helper", among: apps), "com.google.Chrome")
        XCTAssertEqual(AppAudio.owner(of: "com.google.Chrome.helper.Renderer", among: apps), "com.google.Chrome")
        XCTAssertEqual(AppAudio.owner(of: "com.spotify.client", among: apps), "com.spotify.client")
        XCTAssertEqual(AppAudio.owner(of: "com.google.Chromecast", among: apps), "com.google.Chromecast",
                       "a longer name is not a helper: only the name and a dot")
        XCTAssertEqual(AppAudio.owner(of: "com.apple.WebKit.GPU", among: apps), "com.apple.WebKit.GPU",
                       "a process shared by many applications shows as itself")
        XCTAssertEqual(AppAudio.owner(of: "com.a.b.c", among: ["com.a", "com.a.b"]), "com.a.b", "the nearest application")
    }

    func testTheChosenApplicationsProcessesAreCapturedAndNoOneElses() {
        let all: [(id: UInt32, bundleID: String)] = [
            (10, "com.google.Chrome"), (11, "com.google.Chrome.helper"), (12, "com.spotify.client"),
            (13, "com.spotify.client.helper"), (14, "us.zoom.xos"), (15, ""), (16, "com.google.Chromecast"),
        ]
        XCTAssertEqual(AppAudio.processes(for: ["com.google.Chrome", "com.spotify.client"], in: all), [10, 11, 12, 13])
        XCTAssertEqual(AppAudio.processes(for: ["us.zoom.xos"], in: all), [14])
        XCTAssertEqual(AppAudio.processes(for: [], in: all), [])
        XCTAssertEqual(AppAudio.processes(for: ["com.apple.Music"], in: all), [], "not running: nothing to capture yet")
    }

    func testTheListsAreWindowsActiveByNameThenChosenNotRunningAndRememberedLessTheChosen() {
        let names = ["com.google.Chrome": "Google Chrome", "com.spotify.client": "Spotify", "us.zoom.xos": "zoom.us",
                     "com.apple.Music": "Music"]
        let (active, remembered) = AppAudio.lists(
            processes: ["com.spotify.client.helper", "com.google.Chrome.helper", "us.zoom.xos", "com.spotify.client"],
            apps: apps, names: names, chosen: ["com.spotify.client", "com.apple.Music"],
            remembered: ["us.zoom.xos", "com.spotify.client", "com.apple.Music", "org.videolan.vlc", "us.zoom.xos"])
        XCTAssertEqual(active.map(\.row), ["Google Chrome, unchecked", "Spotify, checked", "zoom.us, unchecked",
                                           "Music (not running), checked"],
                       "running by name, each once however many helpers; then a chosen one not running, so it can be unticked")
        XCTAssertEqual(remembered.map(\.row), ["org.videolan.vlc (not running), unchecked", "zoom.us, unchecked"],
                       "the chosen are not repeated here, nor anything twice")
        XCTAssertEqual(AppAudio.toggled("us.zoom.xos", in: ["com.spotify.client"]), ["com.spotify.client", "us.zoom.xos"])
        XCTAssertEqual(AppAudio.toggled("com.spotify.client", in: ["com.spotify.client", "us.zoom.xos"]), ["us.zoom.xos"])
    }
}
