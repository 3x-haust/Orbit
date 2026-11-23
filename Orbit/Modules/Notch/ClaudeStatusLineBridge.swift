import Darwin
import Foundation

/// Installs a local quota tap while leaving the original Claude status-line command in place.
enum ClaudeStatusLineBridge {
    enum State: Equatable, Sendable {
        case available
        case connected
        case unavailable
    }

    private enum ConfigurationError: Error {
        case unsupported
        case changed
    }

    static func state(in folder: URL) -> State {
        do {
            let (_, settings) = try read(in: folder)
            let command = try statusLine(in: settings)?["command"] as? String
            return command.flatMap { originalCommand(from: $0, in: folder) } == nil ? .available : .connected
        } catch {
            return .unavailable
        }
    }

    static func setConnected(_ connected: Bool, in folder: URL) throws {
        let (original, document) = try read(in: folder)
        var settings = document
        var status = try statusLine(in: settings)
        let command = status?["command"] as? String
        let installed = command.flatMap { originalCommand(from: $0, in: folder) }
        if connected {
            guard installed == nil else { return }
            status = status ?? ["type": "command"]
            status?["command"] = captureCommand(in: folder, forwarding: command)
        } else {
            guard let installed else { return }
            if installed.isEmpty {
                guard status?.count == 2 else { throw ConfigurationError.changed }
                status = nil
            } else {
                status?["command"] = installed
            }
        }
        settings["statusLine"] = status
        var encoded = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        encoded.append(10)
        let (beforeWrite, _) = try read(in: folder)
        guard beforeWrite == original else { throw ConfigurationError.changed }
        let target = folder.appendingPathComponent("settings.json")
        if original == nil {
            try encoded.write(to: target, options: .withoutOverwriting)
        } else {
            try encoded.write(to: target, options: .atomic)
        }
    }

    /// Reading by descriptor avoids opening a replacement symlink or blocking on a pipe.
    private static func read(in folder: URL) throws -> (Data?, [String: Any]) {
        let target = folder.appendingPathComponent("settings.json")
        let descriptor = target.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        if descriptor < 0 {
            if errno == ENOENT, (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                return (nil, [:])
            }
            throw ConfigurationError.unsupported
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        let maximum = 512 * 1024
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maximum,
              let data = try file.read(upToCount: maximum + 1), data.count <= maximum,
              let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationError.unsupported
        }
        return (data, settings)
    }

    private static func statusLine(in settings: [String: Any]) throws -> [String: Any]? {
        guard let raw = settings["statusLine"] else { return nil }
        guard let status = raw as? [String: Any], status["type"] as? String == "command",
              let command = status["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.unsupported
        }
        return status
    }

    private static func originalCommand(from current: String, in folder: URL) -> String? {
        if current == captureCommand(in: folder, forwarding: nil) { return "" }
        let prefix = captureCommand(in: folder, forwarding: "").dropLast(2)
        guard current.hasPrefix(prefix), current.hasSuffix("\n)") else { return nil }
        return String(current.dropFirst(prefix.count).dropLast(2))
    }

    private static func captureCommand(in folder: URL, forwarding command: String?) -> String {
        let script = #"""
        use strict;
        use warnings;
        use Time::HiRes qw(time);
        binmode STDIN;
        binmode STDOUT;
        local $/;
        my $input = <STDIN> // '';
        my ($target, $forward) = @ARGV;
        eval {
            my $data = decode_json($input);
            if (ref($data) eq 'HASH') {
                my %snapshot = (captured_at => time);
                my %windows;
                if (ref($data->{rate_limits}) eq 'HASH') {
                    for my $key ('five_hour', 'seven_day') {
                        my $window = $data->{rate_limits}->{$key};
                        next unless ref($window) eq 'HASH' && defined $window->{used_percentage};
                        $windows{$key} = { used_percentage => $window->{used_percentage}, resets_at => $window->{resets_at} };
                    }
                }
                my $api = $ENV{ANTHROPIC_API_KEY};
                if (%windows && !$api) {
                    $snapshot{rate_limits} = \%windows;
                } elsif (ref($data->{cost}) eq 'HASH' && defined $data->{cost}->{total_cost_usd}) {
                    $snapshot{session_cost_usd} = $data->{cost}->{total_cost_usd};
                    $snapshot{api_key_session} = $api ? JSON::PP::true : JSON::PP::false;
                    $target = dirname($target) . '/orbit-claude-cost.json';
                }
                if (keys(%snapshot) > 1) {
                    my ($file, $temp) = tempfile('.orbit-quota-XXXXXXXX', DIR => dirname($target), UNLINK => 1);
                    print {$file} encode_json(\%snapshot) or die $!;
                    close $file or die $!;
                    rename($temp, $target) or die $!;
                }
            }
        };
        print $input if $forward;
        """#
        let output = folder.appendingPathComponent("orbit-quota.json").path
        let capture = "/usr/bin/perl -MJSON::PP -MFile::Temp=tempfile -MFile::Basename=dirname -e "
            + shellArgument(script) + " -- " + shellArgument(output)
        guard let command else { return capture + " 0" }
        return capture + " 1 | (\n" + command + "\n)"
    }

    private static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
