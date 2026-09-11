import CoreFoundation
import Foundation

/// The allowlisted request options; never serialize a client's environment.
struct DialogProbeOptions: Sendable, Equatable {
    let disabled: Bool
    let debug: Bool

    init(environment: [String: String]) {
        disabled = environment[BlockingDialogGate.optOutVariable] == "1"
        debug = environment[BlockingDialogGate.debugVariable] == "1"
    }

    init(jsonValue: Any) throws {
        guard let object = jsonValue as? [String: Any],
              Set(object.keys) == Set(["disabled", "debug"]),
              let disabled = object["disabled"] as? NSNumber,
              let debug = object["debug"] as? NSNumber,
              CFGetTypeID(disabled) == CFBooleanGetTypeID(),
              CFGetTypeID(debug) == CFBooleanGetTypeID() else {
            throw DaemonDispatch.ExecRunScriptError.malformedEnvelope(
                "dialogProbe must contain exactly the boolean fields 'disabled' and 'debug'")
        }
        self.disabled = disabled.boolValue
        self.debug = debug.boolValue
    }

    var dictionary: [String: Bool] { ["disabled": disabled, "debug": debug] }
    var environment: [String: String] {
        [BlockingDialogGate.optOutVariable: disabled ? "1" : "0",
         BlockingDialogGate.debugVariable: debug ? "1" : "0"]
    }
}
