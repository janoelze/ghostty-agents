import Darwin
import Foundation

/// Identifies coding agents from a surface's foreground process.
enum AgentProcess {
    /// Executable names of known coding agents, mapped to a display name.
    static let knownAgents: [String: String] = [
        "claude": "Claude Code",
        "codex": "Codex",
        "gemini": "Gemini",
        "aider": "Aider",
        "opencode": "OpenCode",
        "amp": "Amp",
        "cursor-agent": "Cursor",
        "goose": "Goose",
        "crush": "Crush",
        "qwen": "Qwen Code",
        "droid": "Droid",
    ]

    /// Shells. A shell in the foreground (that isn't wrapping an agent) means no agent is
    /// running in that surface.
    static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"]

    enum Kind: Equatable {
        case agent(name: String)
        case shell
        case other
    }

    /// Classifies a process by its executable path and arguments. Wrappers such as
    /// `sandbox-exec … claude` or `node …/bin/codex` are recognized because every
    /// argument is checked, not just the first.
    static func classify(pid: Int) -> Kind {
        guard let (path, args) = arguments(of: pid_t(pid)) else { return .other }

        // Native Claude Code installs run from `…/claude/versions/<version>`, so also look
        // at the directory components of the executable path. Agents are checked before
        // shells because wrapper scripts (`bash …/safehouse … claude`) start with a shell.
        let candidates = args.map(basename) + [basename(path)] + path.split(separator: "/").map(String.init)
        for candidate in candidates {
            if let name = knownAgents[candidate] { return .agent(name: name) }
        }

        let first = args.first.map(basename) ?? basename(path)
        if shells.contains(first.trimmingCharacters(in: CharacterSet(charactersIn: "-"))) {
            return .shell
        }

        return .other
    }

    private static func basename(_ s: String) -> String {
        (s as NSString).lastPathComponent
    }

    /// Reads the executable path and argv of a process via `KERN_PROCARGS2`.
    private static func arguments(of pid: pid_t) -> (String, [String])? {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size

        func readString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            let string = String(decoding: buffer[start..<index], as: UTF8.self)
            return string
        }

        guard let path = readString() else { return nil }

        // Skip the NUL padding between the executable path and argv[0].
        while index < size && buffer[index] == 0 { index += 1 }

        var args: [String] = []
        for _ in 0..<argc {
            guard let arg = readString() else { break }
            args.append(arg)
            index += 1
        }

        return (path, args)
    }
}

extension AgentProcess {
    /// When a process started, used to tell a fresh agent apart from stale hook status.
    static func startDate(pid: Int) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
