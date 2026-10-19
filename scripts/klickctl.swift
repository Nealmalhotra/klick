// Drives a running Klick (debug builds) through distributed notifications.
// Usage: klickctl [--channel NAME] <cmd> [key=value ...] [-- file1 file2 ...]
//   cmds: open (x= y= index=page), hover index=N, page index=±1, commit, cancel,
//         run action=<id> (x= y= anchor for editors), settings pane=about|shortcut|credits|license,
//         toast text=..., quit
// Coordinates are AppKit global points (origin bottom-left of main screen).
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var channel: String?
if let i = args.firstIndex(of: "--channel"), args.count > i + 1 {
    channel = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
guard let cmd = args.first else {
    print("usage: klickctl [--channel NAME] <cmd> [key=value ...] [-- files ...]")
    exit(1)
}
var info: [String: String] = ["cmd": cmd]
var files: [String] = []
var afterDashes = false
for arg in args.dropFirst() {
    if arg == "--" { afterDashes = true; continue }
    if afterDashes { files.append(URL(fileURLWithPath: arg).standardizedFileURL.path); continue }
    let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { info[parts[0]] = parts[1] }
}
if !files.isEmpty { info["paths"] = files.joined(separator: "\n") }
let name = channel.map { "io.exastudio.klick.debug.\($0)" } ?? "io.exastudio.klick.debug"
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(name), object: nil, userInfo: info, deliverImmediately: true
)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
