import Foundation
import Darwin
import PetCore
import PetSources

setbuf(stdout, nil)

struct SourceCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func sourceCheck(_ condition: @autoclosure () throws -> Bool, _ message: String = "check failed") throws {
    guard try condition() else { throw SourceCheckFailure(message) }
}
func sourceRejects(_ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw SourceCheckFailure("invalid input accepted")
}
let checks = messagesChecks() + kakaoChecks() + notificationChecks() + contactReadersChecks()
var failed = 0
for (name, run) in checks {
    do { try run(); print("PASS \(name)") }
    catch { failed += 1; print("FAIL \(name): \(error)") }
}
print("\(checks.count - failed)/\(checks.count) PetSources check groups passed")
exit(failed == 0 ? 0 : 1)
