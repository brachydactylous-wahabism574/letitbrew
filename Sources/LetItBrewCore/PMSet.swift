import Foundation

public enum PMSet {
    /// Pure parse of `pmset -g` output, separated from the shell-out so it can
    /// be tested directly.
    ///
    /// `pmset -g` prints a `SleepDisabled` line only when the flag is on, so
    /// its absence means sleep is enabled, which is the default. Nil means
    /// there was no output at all to read, or the output couldn't be trusted:
    /// a value other than `0`/`1`, or two `SleepDisabled` lines that disagree.
    public static func parseSleepDisabled(from output: String?) -> Bool? {
        guard let output else { return nil }
        var found: Bool?
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            let value: Bool
            switch fields[1] {
            case "0": value = false
            case "1": value = true
            default: return nil
            }
            if let found, found != value { return nil }
            found = value
        }
        return found ?? false
    }
}
