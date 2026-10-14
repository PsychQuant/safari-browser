/// The one place the program learns which build it is (#278).
///
/// This tracked file holds a placeholder. `make build` rewrites it through
/// `scripts/stamp-version.sh` for the duration of the compile and puts the
/// placeholder back afterwards, so a plain `swift build` or `swift test`
/// reports `unknown` rather than failing.
enum BuildVersion { static let value = "unknown" }
