#!/usr/bin/env python3
"""Sign and notarize a copy of a built Orbit Release app."""

import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def sign_code(code, identity, scratch):
    entitlements = subprocess.check_output(
        ["/usr/bin/codesign", "--display", "--entitlements", ":-", str(code)],
        stderr=subprocess.PIPE,
    )
    command = [
        "/usr/bin/codesign", "--force", "--timestamp", "--options", "runtime",
        "--preserve-metadata=identifier", "--sign", identity,
    ]
    if entitlements:
        values = plistlib.loads(entitlements)
        values.pop("com.apple.security.get-task-allow", None)
        values.pop("get-task-allow", None)
        entitlements_file = scratch / f"{code.name}.entitlements"
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
    components = (
        "MacOS/OrbitFanHelper",
        "Frameworks/OrbitMediaRemote.dylib",
        "PlugIns/OrbitQuickLook.appex",
        "Helpers/TaviInputMethod.app",
    )

    try:
        if source.suffix != ".app":
            raise ValueError("input must be an Orbit.app bundle")
        if source == output or source in output.parents:
            raise ValueError("output must be outside the input app")
        with (source / "Contents/Info.plist").open("rb") as plist:
            if plistlib.load(plist).get("CFBundleIdentifier") != "com.lyu.orbit":
                raise ValueError("input must be an Orbit.app bundle")
        for component in components:
            path = source / "Contents" / component
            if not path.exists():
                raise ValueError(f"Release app is missing Contents/{component}")
            if path.resolve() != path:
                raise ValueError(f"Release app contains an unexpected link at Contents/{component}")

        output.mkdir()
        try:
            with tempfile.TemporaryDirectory(prefix="orbit-notary-", dir=output) as workspace:
                scratch = Path(workspace)
                app = scratch / "Orbit.app"
                subprocess.run(["/usr/bin/ditto", str(source), str(app)], check=True)
                for component in components:
                    sign_code(app / "Contents" / component, args.identity, scratch)
                sign_code(app, args.identity, scratch)
                subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)

                archive = scratch / "Orbit.zip"
                subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
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
                subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
                subprocess.run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(app)], check=True)
                print(app.rename(output / "Orbit.app"))
        finally:
            if not any(output.iterdir()):
                output.rmdir()
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")


if __name__ == "__main__":
    main()
