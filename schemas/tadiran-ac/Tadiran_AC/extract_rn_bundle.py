"""
React Native apps bundle their real logic as JS inside the APK assets.
This finds that bundle and searches it for AWS AppSync config, API keys,
Cognito pool IDs, and actual GraphQL query/mutation strings.

Run with: python extract_rn_bundle.py tadiran.apk
"""
import sys
import re
import zipfile
from pathlib import Path

# Where React Native bundles typically live inside an APK
BUNDLE_PATH_CANDIDATES = [
    "assets/index.android.bundle",
    "assets/index.android.bundle.js",
    "assets/app.bundle",
]

KEY_PATTERNS = {
    "AppSync GraphQL URL": re.compile(rb'https://[a-z0-9]+\.appsync-api\.[a-z0-9\-]+\.amazonaws\.com/graphql'),
    "AppSync Realtime URL": re.compile(rb'https://[a-z0-9]+\.appsync-realtime-api\.[a-z0-9\-]+\.amazonaws\.com[^\s"\']*'),
    "x-api-key value": re.compile(rb'x-api-key["\']?\s*[:=]\s*["\']([a-zA-Z0-9\-]{20,})["\']', re.IGNORECASE),
    "da2- API key (AppSync format)": re.compile(rb'da2-[a-z0-9]{26}', re.IGNORECASE),
    "Cognito Identity Pool ID": re.compile(rb'[a-z]{2}-[a-z]+-\d:[a-f0-9\-]{36}'),
    "Cognito User Pool ID": re.compile(rb'[a-z]{2}-[a-z]+-\d_[a-zA-Z0-9]{9}'),
    "Cognito App Client ID": re.compile(rb'"?[Cc]lient[Ii]d"?\s*[:=]\s*["\']?([a-z0-9]{26})["\']?'),
    "aws_appsync_authenticationType": re.compile(rb'aws_appsync_authenticationType["\']?\s*[:=]\s*["\']([A-Z_]+)["\']'),
    "amplifyconfiguration hint": re.compile(rb'aws_appsync_graphqlEndpoint'),
    "GraphQL operation name": re.compile(rb'(query|mutation|subscription)\s+([A-Za-z][A-Za-z0-9_]{2,60})\s*[\(\{]'),
}


def find_bundle(z, names):
    for candidate in BUNDLE_PATH_CANDIDATES:
        if candidate in names:
            return candidate
    # fallback: search for anything under assets/ that's large and js-like
    js_like = [n for n in names if 'assets' in n and ('bundle' in n.lower() or n.endswith('.js'))]
    if js_like:
        # pick the largest - real bundle is usually many MB, others are tiny
        largest = max(js_like, key=lambda n: z.getinfo(n).file_size)
        return largest
    return None


def scan_bundle(apk_path):
    apk_path = Path(apk_path)
    print(f"Opening {apk_path}\n")

    with zipfile.ZipFile(apk_path, 'r') as z:
        names = z.namelist()
        bundle_name = find_bundle(z, names)

        if not bundle_name:
            print("No JS bundle found under assets/. Listing all assets/ files instead:")
            for n in names:
                if n.startswith('assets/'):
                    print(f"  {n}  ({z.getinfo(n).file_size} bytes)")
            print("\nTell me which one looks like the main bundle (usually the biggest .js/.bundle file).")
            return

        info = z.getinfo(bundle_name)
        print(f"Found bundle: {bundle_name} ({info.file_size / 1_000_000:.1f} MB)\n")
        data = z.read(bundle_name)

    print("=" * 70)
    for label, pattern in KEY_PATTERNS.items():
        matches = pattern.findall(data)
        # dedupe, decode
        seen = set()
        clean = []
        for m in matches:
            if isinstance(m, tuple):
                m = m[-1] if m[-1] else m[0]
            try:
                s = m.decode('utf-8', errors='replace') if isinstance(m, bytes) else m
            except Exception:
                continue
            if s not in seen:
                seen.add(s)
                clean.append(s)

        print(f"\n[{label}] - {len(clean)} unique match(es)")
        for s in clean[:30]:
            print(f"    {s}")
        if len(clean) > 30:
            print(f"    ... and {len(clean) - 30} more")

    print("\n" + "=" * 70)
    print("Done. Priority order to report back:")
    print("  1. AppSync GraphQL URL (should match what we already found)")
    print("  2. x-api-key value / da2- key -> this is likely the actual API key")
    print("  3. Cognito Identity/User Pool IDs -> confirms auth mechanism")
    print("  4. GraphQL operation names -> tells us what queries/mutations exist")
    print("     (e.g. 'GetDevice', 'SetTemperature', 'ListUnits' etc.)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python extract_rn_bundle.py <path-to-apk>")
        sys.exit(1)
    scan_bundle(sys.argv[1])
