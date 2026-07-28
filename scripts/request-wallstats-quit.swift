import AppKit
import Darwin
import Foundation

private let bundleIdentifier = "com.memorici.wallstats"
private let applications = NSRunningApplication.runningApplications(
    withBundleIdentifier: bundleIdentifier
)
private let failures = applications.filter { application in
    !application.isTerminated && !application.terminate()
}

if !failures.isEmpty {
    let processIdentifiers = failures.map { String($0.processIdentifier) }.joined(separator: ", ")
    FileHandle.standardError.write(Data(
        "request-wallstats-quit: normal termination was rejected by PIDs \(processIdentifiers)\n".utf8
    ))
    exit(EXIT_FAILURE)
}

print("Requested graceful termination of \(applications.count) Wallstats process(es).")
