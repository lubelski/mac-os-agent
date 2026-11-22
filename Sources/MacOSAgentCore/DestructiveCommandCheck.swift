import Foundation

/// Decides whether a shell command needs the person's go-ahead before it runs.
///
/// Two things can ask for it, and either one is enough:
/// - The model marks the call as destructive. The tool schema requires it to say.
/// - The command matches one of the patterns below. The list is deliberately broad, so a
///   command that might delete, overwrite, uninstall, stop, or change system settings asks
///   first even when the model said it would not.
public enum DestructiveCommandCheck {
    struct Rule: Sendable {
        let pattern: String
        let reason: String
    }

    // A word at the start of a command: at the very start, or after a separator, a pipe,
    // `sudo`, `xargs`, `env`, or an opening parenthesis or backtick.
    private static let commandStart = #"(?:^|[;&|(`]|\$\(|\b(?:sudo|xargs|env|exec|nohup|time)\s+)\s*"#

    static let rules: [Rule] = [
        Rule(pattern: #"\bsudo\b"#, reason: "runs as administrator"),
        Rule(pattern: commandStart + #"(?:rm|rmdir|unlink|srm|shred|trash)\b"#, reason: "deletes files"),
        Rule(pattern: commandStart + #"(?:mv|dd|truncate|ditto|rsync)\b"#, reason: "can overwrite files"),
        Rule(pattern: commandStart + #"cp\s+(?:-\w*\s+)*-\w*f"#, reason: "can overwrite files"),
        Rule(pattern: #"\bfind\b.*\s-(?:delete|exec|execdir|ok)\b"#, reason: "acts on every file it finds"),
        Rule(pattern: commandStart + #"(?:chmod|chown|chgrp|chflags|xattr|setfacl)\b"#, reason: "changes file permissions or attributes"),
        Rule(pattern: commandStart + #"(?:kill|killall|pkill)\b"#, reason: "stops running processes"),
        Rule(pattern: commandStart + #"(?:shutdown|reboot|halt)\b"#, reason: "restarts or shuts down the Mac"),
        Rule(pattern: #"\bpmset\b.*\b(?:sleepnow|restoredefaults|schedule)\b"#, reason: "changes power state"),
        Rule(pattern: #"\b(?:diskutil|hdiutil|asr|fdesetup|newfs_\w+|mkfs\w*|csrutil|nvram|bless)\b"#, reason: "changes disks or startup settings"),
        Rule(pattern: #"\btmutil\s+(?:delete|disable|removeexclusion|thinlocalsnapshots)\b"#, reason: "changes Time Machine"),
        Rule(pattern: #"\blaunchctl\s+(?:unload|remove|bootout|disable|kill)\b"#, reason: "stops system services"),
        Rule(pattern: #"\bdefaults\s+(?:-\S+\s+)*delete\b"#, reason: "deletes settings"),
        Rule(pattern: #"\b(?:brew|port|pip3?|npm|gem|mas)\s+(?:\S+\s+)*(?:uninstall|remove|rm|zap|cleanup|autoremove)\b"#, reason: "uninstalls software"),
        Rule(pattern: #"\bgit\s+(?:\S+\s+)*(?:reset\s+--hard|clean\s+-\w*f|push\s+(?:\S+\s+)*--force|branch\s+-D)\b"#, reason: "discards git history or changes"),
        Rule(pattern: #"\bosascript\b.*\b(?:delete|empty|erase|quit|shut ?down|restart|log out)\b"#, reason: "scripts an app to delete or quit"),
        Rule(pattern: #"\b(?:security)\s+(?:delete|remove)"#, reason: "changes the Keychain"),
        Rule(pattern: #"\b(?:networksetup|scutil|systemsetup|spctl|dscl|sysadminctl|softwareupdate|profiles)\b"#, reason: "changes system settings"),
        Rule(pattern: #"\bsqlite3\b.*\b(?:delete|drop|update|insert)\b"#, reason: "changes a database"),
        Rule(pattern: #"\bcurl\b.*\|\s*(?:ba|z)?sh\b"#, reason: "runs a downloaded script"),
        // `>` that writes over a file. `>>` appends and `>&`, `2>&1`, and `> /dev/null` are left alone.
        Rule(pattern: #"(?<![>&0-9])[0-9]?>\|?(?![>&])\s*(?!/dev/null\b)[^\s&]"#, reason: "overwrites a file"),
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.map { rule in
        // The patterns are constants, so a failure here is a programming error.
        (try! NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]), rule.reason)
    }

    /// The reason a command needs a go-ahead, or nil when it can run without one.
    public static func reasonToConfirm(command: String, markedDestructive: Bool) -> String? {
        if let reason = patternReason(command) { return reason }
        return markedDestructive ? "marked as destructive" : nil
    }

    /// The reason the first matching pattern gives, or nil when none match.
    public static func patternReason(_ command: String) -> String? {
        let range = NSRange(command.startIndex..., in: command)
        for (expression, reason) in compiled where expression.firstMatch(in: command, range: range) != nil {
            return reason
        }
        return nil
    }
}
