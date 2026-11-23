#!/usr/bin/env python3
"""Sign and notarize a copy of a built Orbit Release app."""

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


BUNDLE_SUFFIXES = {".app", ".appex", ".bundle", ".framework", ".plugin", ".xpc"}
MACH_O_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}


def bundle_executable(bundle):
    if bundle.suffix == ".framework":
        info = bundle / "Resources/Info.plist"
        executable_dir = bundle
    elif (bundle / "Contents").is_dir():
        info = bundle / "Contents/Info.plist"
        executable_dir = bundle / "Contents/MacOS"
    else:
        info = bundle / "Info.plist"
        executable_dir = bundle

    if not info.is_file():
        return None
    if bundle not in info.resolve().parents:
        raise ValueError(f"Info.plist points outside {bundle.name}")
    with info.open("rb") as plist:
        metadata = plistlib.load(plist)
    executable = metadata.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        return None
    binary = (executable_dir / executable).resolve()
    if bundle not in binary.parents:
        raise ValueError(f"Executable points outside {bundle.name}")
    if binary.is_file():
        return binary
    raise ValueError(f"Missing executable declared by {bundle.name}: {executable}")


def is_mach_o(path):
    with path.open("rb") as binary:
        if binary.read(4) not in MACH_O_MAGICS:
            return False
    kind = subprocess.check_output(["/usr/bin/file", "-b", str(path)], text=True)
    return kind.startswith("Mach-O")


def signing_order(app):
    main_executable = bundle_executable(app)
    if main_executable is None or not is_mach_o(main_executable):
        raise ValueError("input must be a macOS .app with a Mach-O executable")

    bundles = {app: main_executable}
    binaries = set()
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.suffix in BUNDLE_SUFFIXES and path.is_dir():
            executable = bundle_executable(path)
            if executable is not None:
                bundles[path] = executable
        elif path.is_file() and is_mach_o(path):
            binaries.add(path)

    # Sign bundle executables through their bundle so the resource seal is included.
    targets = binaries.difference(bundles.values()) | bundles.keys()
    return sorted(targets, key=lambda path: (-len(path.parts), str(path)))


def sign_code(code, identity, scratch):
    current = subprocess.run(
        ["/usr/bin/codesign", "--display", "--entitlements", ":-", str(code)],
        capture_output=True,
    )
    command = [
        "/usr/bin/codesign", "--force", "--timestamp", "--options", "runtime",
        "--sign", identity,
    ]
    if current.returncode == 0:
        command.append("--preserve-metadata=identifier")
    elif b"code object is not signed at all" not in current.stderr:
        current.check_returncode()
    if current.stdout:
        values = plistlib.loads(current.stdout)
        values.pop("com.apple.security.get-task-allow", None)
        values.pop("get-task-allow", None)
        entitlements_file = scratch / "entitlements.plist"
        entitlements_file.write_bytes(plistlib.dumps(values))
        command.extend(["--entitlements", str(entitlements_file), "--generate-entitlement-der"])
    subprocess.run([*command, str(code)], check=True)

    details = subprocess.run(
        ["/usr/bin/codesign", "--display", "--verbose=4", str(code)],
        check=True, capture_output=True, text=True,
    ).stderr.splitlines()
    if not any(line.startswith("Authority=Developer ID Application:") for line in details):
        raise ValueError(f"{code.name} must be signed with a Developer ID Application identity")
    if not any(line.startswith("Timestamp=") for line in details):
        raise ValueError(f"{code.name} is missing a secure timestamp")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="built Release Orbit.app")
    parser.add_argument("output_dir", type=Path, help="new directory for the notarized Orbit.app")
    parser.add_argument("--identity", required=True, help="Developer ID Application identity or certificate hash")
    parser.add_argument("--keychain-profile", required=True, help="profile saved with notarytool store-credentials")
    args = parser.parse_args()

    source = args.app.resolve()
    output = args.output_dir.resolve()

    try:
        if source.suffix != ".app":
            raise ValueError("input must be an Orbit.app bundle")
        if source == output or source in output.parents:
            raise ValueError("output must be outside the input app")
        output.mkdir()
        try:
            with tempfile.TemporaryDirectory(prefix="orbit-notary-", dir=output) as workspace:
                scratch = Path(workspace)
                app = scratch / "Orbit.app"
                subprocess.run(["/usr/bin/ditto", str(source), str(app)], check=True)
                for code in signing_order(app):
                    sign_code(code, args.identity, scratch)
                verify_signature = ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app)]
                subprocess.run(verify_signature, check=True)

                archive = scratch / "Orbit.zip"
                subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
                submission = subprocess.run([
                    "/usr/bin/xcrun", "notarytool", "submit", str(archive),
                    "--keychain-profile", args.keychain_profile, "--wait",
                    "--no-s3-acceleration", "--output-format", "json",
                ], stdout=subprocess.PIPE, text=True)
                result = json.loads(submission.stdout) if submission.stdout.strip() else {}
                if result.get("id") and result.get("status"):
                    print(f"Apple notarization: {result['status']} (submission {result['id']})", flush=True)
                    if result["status"] != "Accepted":
                        raise ValueError(f"Review submission {result['id']} with xcrun notarytool log")
                submission.check_returncode()
                if result.get("status") != "Accepted":
                    raise ValueError("Apple did not return an accepted notarization result")
                subprocess.run(["/usr/bin/xcrun", "stapler", "staple", str(app)], check=True)
                subprocess.run(["/usr/bin/xcrun", "stapler", "validate", str(app)], check=True)
                subprocess.run(verify_signature, check=True)
                subprocess.run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], check=True)
                print(app.rename(output / "Orbit.app"))
        finally:
            if not any(output.iterdir()):
                output.rmdir()
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")


if __name__ == "__main__":
    main()
