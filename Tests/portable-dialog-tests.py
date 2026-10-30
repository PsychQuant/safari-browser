#!/usr/bin/env python3
"""Run a portable dialog subset against the real Swift sources.

This is NOT a macOS build or AX acceptance test. macOS-facing bridge/provider,
session, daemon and trace boundaries are inert support types; scanners, worker,
observation, command decisions, parser, renderers and tests are production code.
Requires Swift 6 and git/network access for swift-argument-parser 1.5.0, or an
existing checkout passed as --argument-parser. Native validation: make test.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--swift', default='swift', help='Swift 6 executable')
parser.add_argument('--argument-parser', type=Path, help='Local swift-argument-parser checkout')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
workspace = tempfile.TemporaryDirectory(prefix='safari-portable-dialog-')
pkg = Path(workspace.name)
(pkg/'Sources/SafariBrowser').mkdir(parents=True,exist_ok=True)
(pkg/'Tests/SafariBrowserTests').mkdir(parents=True,exist_ok=True)
def block(text, start):
    i=text.index(start); j=text.index('{',i); depth=1; k=j+1
    while depth:
        depth += (text[k]=='{')-(text[k]=='}'); k+=1
    return text[i:k]
bridge=(repo/'Sources/SafariBrowser/SafariBridge.swift').read_text()
provider=(repo/'Sources/SafariBrowser/Utilities/BoundedDialogProbe.swift').read_text()
support='import Foundation\n'+block(provider,'protocol DialogProbeProvider')+'\nenum DialogProbeReadError: Error { case unavailable, accessibilityDenied }\nenum SafariBridge {\n'
for name in ['struct BlockingDialog:', 'enum DialogScan:', 'enum DialogPressOutcome:']:
    support+=block(bridge,name)+'\n'
support+='}\nstruct GUISession {\n enum State { case available, locked, unavailable }\n let read: () -> [String: Bool]\n init(_ read: @escaping () -> [String: Bool]) { self.read = read }\n var state: State { read()["CGSSessionScreenIsLocked"] == true ? .locked : .available }\n}\n'
(pkg/'Sources/SafariBrowser/Support.swift').write_text(support)
for f in ['DialogTreeScanner.swift','DialogMessageText.swift']:
    shutil.copy(repo/'Sources/SafariBrowser/Utilities'/f,pkg/'Sources/SafariBrowser'/f)
for f in ['DialogTreeScannerTests.swift','ScopedDialogInspectionTests.swift']:
    shutil.copy(repo/'Tests/SafariBrowserTests'/f,pkg/'Tests/SafariBrowserTests'/f)
src=pkg/'Sources/SafariBrowser'
# Compile the real command/policy and observation code against inert OS boundaries.
for f in ['WindowDialogObservation.swift','GlobalDialogProbe.swift','BoundedAXWorker.swift','TerminalText.swift']:
 shutil.copy(repo/'Sources/SafariBrowser/Utilities'/f,src/f)
(src/'DialogCommand.swift').write_text((repo/'Sources/SafariBrowser/Commands/DialogCommand.swift').read_text().replace('import ApplicationServices\n',''))
warn=(repo/'Sources/SafariBrowser/Utilities/BlockingDialogGate.swift').read_text()
(src/'Warning.swift').write_text('import Foundation\n'+block(warn,'enum BlockingDialogWarning'))
errors=(repo/'Sources/SafariBrowser/Utilities/Errors.swift').read_text()
cases=errors[errors.index('    case noBlockingDialog'):errors.index('    case downloadFailed')]
messages=errors[errors.index('        case .dialogInspectionIncomplete:'):errors.index('        case .elementNotFound(let selector):')]
(src/'Errors.swift').write_text('import Foundation\nenum SafariBrowserError: Error, LocalizedError {\n'+cases+'''
case guiSessionLocked, guiSessionUnavailable
case accessibilityRequired(flag: String)
var errorDescription: String? { switch self {
'''+messages+'''\ndefault: return "unavailable OS boundary"
} } }''')
support=(src/'Support.swift').read_text()
support=support.replace('struct GUISession {','struct GUISession: @unchecked Sendable {\n static var live: GUISession { .init { [:] } }')
support+='''
extension SafariBridge {
 static func observeBlockingDialogs(windowID: Int? = nil) -> WindowDialogObservation { fatalError("live AX must not be reached") }
 static func pressDialogButton(expectedWindowID: Int? = nil, windowID: Int? = nil, deciding: (BlockingDialog) -> Int?) -> DialogPressOutcome { fatalError("live AX must not be reached") }
}
struct PerformanceTrace {
 enum Span { case axWait, axInspect }
 @TaskLocal static var context: Int? = nil
 static func span<T>(_ span: Span, _ operation: () -> T) -> T { operation() }
}
struct DaemonRequestContext: Sendable {
 static let current: Self? = nil
 var dialogProbeDisabled: Bool = false
}
struct BlockingDialogGate {
 static let optOutVariable = "SAFARI_BROWSER_NO_DIALOG_PROBE"
 enum WindowKey { case id(Int); var humanDescription: String { "window" } }
}
struct AXDialogProbeProvider: DialogProbeProvider {
 func windows(timeout: Float) throws -> [Int] { throw DialogProbeReadError.unavailable }
 func windowID(_ node: Int, timeout: Float) throws -> Int { throw DialogProbeReadError.unavailable }
 func role(_ node: Int, timeout: Float) throws -> String { throw DialogProbeReadError.unavailable }
 func subrole(_ node: Int, timeout: Float) throws -> String? { throw DialogProbeReadError.unavailable }
 func children(_ node: Int, timeout: Float) throws -> [Int] { throw DialogProbeReadError.unavailable }
 func valueIsSettable(_ node: Int, timeout: Float) throws -> Bool? { throw DialogProbeReadError.unavailable }
 func text(_ node: Int, timeout: Float) throws -> String? { throw DialogProbeReadError.unavailable }
 func buttonTitle(_ node: Int, timeout: Float) throws -> String? { throw DialogProbeReadError.unavailable }
}
'''
(src/'Support.swift').write_text(support)
for f in ['ScopedDialogCommandTests.swift','DialogCommandTests.swift','DialogExpectationTests.swift']:
 shutil.copy(repo/'Tests/SafariBrowserTests'/f,pkg/'Tests/SafariBrowserTests'/f)

import json
if args.argument_parser:
    dependency = '.package(path: ' + json.dumps(str(args.argument_parser.resolve())) + ')'
    package_name = args.argument_parser.resolve().name
else:
    dependency = '.package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0")'
    package_name = 'swift-argument-parser'
(pkg/'Package.swift').write_text(
    '// swift-tools-version:6.0\nimport PackageDescription\n'
    + 'let package = Package(name: "PortableDialogTests", dependencies: [' + dependency + '], '
    + 'targets: [.target(name: "SafariBrowser", dependencies: [.product(name: "ArgumentParser", package: '
    + json.dumps(package_name) + ')]), .testTarget(name: "SafariBrowserTests", dependencies: ["SafariBrowser"])])\n')
print('Portable subset only; macOS bridge/provider and live Safari are NOT exercised.', flush=True)
result = subprocess.call([args.swift, 'test', '-j', '1', '--package-path', str(pkg)])
workspace.cleanup()
raise SystemExit(result)
