#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="$PROJECT_DIR/.build/core-verification"
mkdir -p "$CHECK_DIR/module-cache"

# Command Line Tools omit XCTest. Reuse the XCTest cases with a tiny assertion
# adapter so the exact same cases remain runnable without installing Xcode.
python3 - "$PROJECT_DIR" "$CHECK_DIR" <<'PYTHON'
import pathlib
import re
import sys

project = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
tests = (project / 'Tests/BTCPriceCoreTests/OKXClientTests.swift').read_text()
tests = tests.replace('import XCTest\n', '').replace('@testable import BTCPriceCore\n', '')
cases = re.findall(r'    func (test\w+)\(\)( throws)?', tests)
if not cases:
    raise SystemExit('No core test cases found')

adapter = r'''
import Foundation

private var failures = 0
private var assertions = 0
private var currentTest = ""
class XCTestCase {}
private enum VerificationError: Error { case unwrapFailed }

private func fail(_ message: String, file: StaticString, line: UInt) {
    failures += 1
    print("FAIL \(currentTest) at \(file):\(line): \(message)")
}

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T,
    file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1
    if actual != expected { fail("\(actual) != \(expected)", file: file, line: line) }
}

func XCTAssertEqual(_ actual: Double, _ expected: Double, accuracy: Double,
    file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1
    if !actual.isFinite || abs(actual - expected) > accuracy {
        fail("\(actual) != \(expected) +/- \(accuracy)", file: file, line: line)
    }
}

func XCTAssertNil<T>(_ actual: T?, file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1
    if let actual { fail("Expected nil, got \(actual)", file: file, line: line) }
}

func XCTAssertFalse(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1
    if actual { fail("Expected false", file: file, line: line) }
}

func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    assertions += 1
    guard let value else {
        fail("Expected non-nil", file: file, line: line)
        throw VerificationError.unwrapFailed
    }
    return value
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
    file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void) {
    assertions += 1
    do {
        _ = try expression()
        fail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

private func run(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    let previousFailures = failures
    do { try body() }
    catch { fail("Unexpected error: \(error)", file: #filePath, line: #line) }
    if previousFailures == failures { print("PASS \(name)") }
}
'''
runner = '\nlet suite = OKXClientTests()\n'
runner += '\n'.join(f'run("{name}") {{ {"try " if throwing else ""}suite.{name}() }}' for name, throwing in cases)
runner += f'\nprint("\\nStandalone assertion verification: {len(cases)} cases, \\(assertions) assertions, \\(failures) failures.")\n'
runner += 'exit(failures == 0 ? 0 : 1)\n'
(output / 'main.swift').write_text(adapter + tests + runner)
PYTHON

swiftc \
  -module-cache-path "$CHECK_DIR/module-cache" \
  -target "$(uname -m)-apple-macosx13.0" \
  "$PROJECT_DIR/Sources/BTCPriceCore/OKXClient.swift" \
  "$CHECK_DIR/main.swift" \
  -o "$CHECK_DIR/verify-core"

"$CHECK_DIR/verify-core"
