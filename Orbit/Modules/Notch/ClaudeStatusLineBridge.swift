import CryptoKit
import Darwin
import Foundation

/// Installs a local quota tap while leaving the original Claude status-line command in place.
enum ClaudeStatusLineBridge {
    enum State: Equatable, Sendable {
        case available
        case connected
        case needsUpdate
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
            guard let connection = command.flatMap(installedConnection) else { return .available }
            return connection.isCurrent(in: folder) ? .connected : .needsUpdate
        } catch {
            return .unavailable
        }
    }

    static func setConnected(_ connected: Bool, in folder: URL) throws {
        let (original, document) = try read(in: folder)
        var settings = document
        var status = try statusLine(in: settings)
        let command = status?["command"] as? String
        let installed = command.flatMap(installedConnection)
        if connected {
            if installed?.isCurrent(in: folder) == true { return }
            let originalCommand = installed.map(\.original) ?? command
            status = status ?? ["type": "command"]
            status?["command"] = captureCommand(in: folder, forwarding: originalCommand)
        } else {
            guard let installed else { return }
            if let originalCommand = installed.original {
                status?["command"] = originalCommand
            } else {
                guard status?.count == 2 else { throw ConfigurationError.changed }
                status = nil
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

    private struct Connection {
        let target: String
        let original: String?
        let currentVersion: Bool

        func isCurrent(in folder: URL) -> Bool {
            currentVersion && target == ClaudeStatusLineBridge.targetArgument(in: folder)
        }
    }

    private static let interpreter = "/usr/bin/perl -MJSON::PP -MFile::Temp=tempfile -MFile::Basename=dirname -e "
    private static let signature = "# Orbit Claude status line v5"
    // SHA-256 fingerprints of the two unversioned bridge commands.
    private static let legacyScriptHashes: Set<String> = [
        "8f80c08b1949f6bdd235230e2f8710eadb4c9477d99e90dc27299f82ea5f9d5d",
        "e504e2677498b76890a182647e90bb9b457868f29d74f9a0c2b9a040ed31f75e",
    ]

    private static func installedConnection(_ command: String) -> Connection? {
        guard command.hasPrefix(interpreter), let separator = command.range(of: " -- ") else { return nil }
        let script = command[command.index(command.startIndex, offsetBy: interpreter.count)..<separator.lowerBound]
        let currentVersion = script.hasPrefix("'" + signature + "\n")
        if !currentVersion && !["v2", "v3", "v4"].contains(where: { script.hasPrefix("'# Orbit Claude status line " + $0 + "\n") }) {
            let hash = SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
            guard legacyScriptHashes.contains(hash) else { return nil }
        }

        let rest = command[separator.upperBound...]
        let pipeline = "' 1 | (\n"
        if let forwarding = rest.range(of: pipeline), rest.hasSuffix("\n)") {
            let target = rest[...forwarding.lowerBound]
            return Connection(target: String(target), original: String(rest[forwarding.upperBound...].dropLast(2)),
                              currentVersion: currentVersion)
        }
        guard rest.hasSuffix("' 0") else { return nil }
        return Connection(target: String(rest.dropLast(2)), original: nil, currentVersion: currentVersion)
    }

    private static func targetArgument(in folder: URL) -> String {
        shellArgument(folder.appendingPathComponent("orbit-quota.json").path)
    }

    private static func captureCommand(in folder: URL, forwarding command: String?) -> String {
        let script = signature + "\n" + #"""
        use strict;
        use warnings;
        use Time::HiRes qw(time sleep);
        use IO::Select;
        use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_NOFOLLOW O_NONBLOCK LOCK_EX LOCK_NB);
        use POSIX qw(WNOHANG);
        binmode STDIN;
        binmode STDOUT;
        local $/;
        my $input = <STDIN> // '';
        my ($target, $forward) = @ARGV;
        if ($forward) {
            print $input;
            open STDOUT, '>', '/dev/null' or die $!;
        }

        sub auth_status {
            my ($as_text) = @_;
            my @candidates = ('claude');
            push @candidates, "$ENV{HOME}/.local/bin/claude" if defined $ENV{HOME};
            push @candidates, '/opt/homebrew/bin/claude', '/usr/local/bin/claude';
            pipe(my $read, my $write) or return 0;
            my $pid = fork();
            return 0 unless defined $pid;
            if (!$pid) {
                close $read;
                open STDIN, '<', '/dev/null' or POSIX::_exit(1);
                open STDOUT, '>&', $write or POSIX::_exit(1);
                open STDERR, '>', '/dev/null' or POSIX::_exit(1);
                close $write;
                # Inherit the session environment, including an absent CLAUDE_CONFIG_DIR.
                local $ENV{LC_ALL} = 'C' if $as_text;
                my @args = ('auth', 'status');
                push @args, '--text' if $as_text;
                for my $cli (@candidates) {
                    next if $cli ne 'claude' && !-x $cli;
                    exec {$cli} $cli, @args;
                }
                POSIX::_exit(1);
            }
            close $write;
            my $selector = IO::Select->new($read);
            my ($response, $eof) = ('', 0);
            my $deadline = time + 1.25;
            while (length($response) < 32768) {
                my $left = $deadline - time;
                last if $left <= 0 || !$selector->can_read($left);
                my $length = sysread($read, my $chunk, 4096);
                last unless defined $length;
                if (!$length) { $eof = 1; last; }
                $response .= $chunk;
            }
            close $read;
            if (waitpid($pid, WNOHANG) == 0) {
                kill 'KILL', $pid;
                waitpid($pid, 0);
            }
            return $eof ? $response : undef;
        }

        sub api_billed_auth {
            my $response = auth_status(0);
            my $status = eval { decode_json($response // '') };
            return 0 unless ref($status) eq 'HASH' && $status->{loggedIn};
            my $method = $status->{authMethod} // '';
            return 1 if $method =~ /\Aapi_key(?:_helper)?\z/;
            return 0 unless $method eq 'oauth_token' && ($status->{apiProvider} // '') eq 'firstParty';
            # Subscription setup-token and SDK token-fd sessions can report the same JSON method.
            return 0 if grep { defined $ENV{$_} && length $ENV{$_} }
                qw(CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR CLAUDE_CODE_OAUTH_TOKEN_FD);
            my $text = auth_status(1) // '';
            my ($first) = split /\r?\n/, $text;
            my @source = split / \xC2\xB7 /, ($first // '');
            return @source == 3 && $source[0] =~ /\AProfile: [^\r\n]+\z/
                && $source[1] eq 'user_oauth' && $source[2] =~ /\Aprofile [^\r\n]+\z/;
        }

        sub read_snapshot {
            my ($path) = @_;
            return eval {
                sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or die $!;
                die unless -f $file;
                my $bytes = read($file, my $json, 8192);
                close $file;
                decode_json($json) if $bytes;
            };
        }

        sub publish_snapshot {
            my ($path, $snapshot) = @_;
            sysopen(my $lock, $path . '.lock', O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0600) or return;
            return unless -f $lock;
            my $until = time + 0.1;
            while (!flock($lock, LOCK_EX | LOCK_NB)) {
                return if time >= $until;
                sleep 0.01;
            }
            my $previous = read_snapshot($path);
            my $captured = ref($previous) eq 'HASH' ? $previous->{captured_at} : undef;
            return if defined $captured && $captured =~ /\A[0-9]+(?:\.[0-9]+)?\z/
                && $captured > $snapshot->{captured_at} && $captured <= time + 60;
            my ($file, $temp) = tempfile('.orbit-quota-XXXXXXXX', DIR => dirname($path), UNLINK => 1);
            print {$file} encode_json($snapshot) or die $!;
            close $file or die $!;
            rename($temp, $path) or die $!;
        }

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
                if (%windows) {
                    $snapshot{rate_limits} = \%windows;
                } elsif (ref($data->{cost}) eq 'HASH' && defined $data->{cost}->{total_cost_usd}) {
                    my $folder = dirname($target);
                    $target = $folder . '/orbit-claude-cost.json';
                    my $session = $data->{session_id} // '';
                    my $previous = read_snapshot($target);
                    my $checked = time;
                    my $api;
                    if (length($session) && ref($previous) eq 'HASH' && ($previous->{session_id} // '') eq $session
                        && ($previous->{auth_checked_at} // 0) > $checked - 60
                        && $previous->{auth_checked_at} <= $checked) {
                        $checked = $previous->{auth_checked_at};
                        $api = $previous->{api_key_session};
                    } else {
                        $api = api_billed_auth();
                    }
                    $snapshot{session_cost_usd} = $data->{cost}->{total_cost_usd};
                    $snapshot{session_id} = $session;
                    $snapshot{auth_checked_at} = $checked;
                    $snapshot{api_key_session} = $api ? JSON::PP::true : JSON::PP::false;
                }
                publish_snapshot($target, \%snapshot) if keys(%snapshot) > 1;
            }
        };
        """#
        let capture = interpreter + shellArgument(script) + " -- " + targetArgument(in: folder)
        guard let command else { return capture + " 0" }
        return capture + " 1 | (\n" + command + "\n)"
    }

    private static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
