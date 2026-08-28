// Stubs for the iSH ObjC types used by the PiRuntime bridge files, so the
// Runtime/*.swift trio can be typechecked standalone under Swift 6.
import Foundation

enum ISHShellExecutorError: Int {
    case none = 0
    case processCreationFailed = -1
    case execFailed = -2
    case timeout = -3
    case cancelled = -4
}

@objcMembers
final class ISHShellExecutionResult: NSObject {
    var exitCode: Int = 0
    var pid: Int = 0
    var error: ISHShellExecutorError = .none
    var output: String = ""
    var errorOutput: String = ""
    var duration: TimeInterval = 0
}

typealias ISHShellLineCallback = (String, Bool) -> Void
typealias ISHShellCompletionCallback = (ISHShellExecutionResult) -> Void

final class ISHShellPersistentProcess: NSObject {
    var pid: Int { 0 }
    var stdinWriteFD: Int { -1 }
    func writeData(_ data: Data) -> Bool { true }
    func writeLine(_ line: String) -> Bool { true }
    func terminate() {}
}

typealias ISHShellPersistentLineCallback = (String, Bool) -> Void
typealias ISHShellPersistentExitCallback = (Int, Int) -> Void

@objcMembers
final class ISHShellExecutor: NSObject {
    static func launchPersistentExecutable(_ executable: String,
                                           arguments: [String]?,
                                           environment: [String: String]?,
                                           fsContext: UInt64,
                                           lineCallback: ISHShellPersistentLineCallback?,
                                           exitCallback: ISHShellPersistentExitCallback?) -> ISHShellPersistentProcess? {
        nil
    }
}
