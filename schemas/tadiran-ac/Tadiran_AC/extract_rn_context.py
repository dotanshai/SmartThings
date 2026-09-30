"""
Broader search: find AWS config keywords anywhere in the bundle and print
surrounding context, since exact key names/formats can vary and strict
regexes may miss them in minified JS.

Run with: python extract_rn_context.py tadiran.apk
"""
import sys
import zipfile
from pathlib import Path

BUNDLE_PATH = "assets/index.android.bundle"

# Keywords to hunt for, with how much context to show around each hit
KEYWORDS = [
    "graphqlEndpoint",
    "aws_appsync",
    "appsync",
    "IdentityPoolId",
    "identityPoolId",
    "UserPoolId",
    "userPoolId",
    "PoolId",
    "aws_user_pools",
    "aws_cognito",
    "AWS_IAM",
    "API_KEY",
    "apiKey",
    "authenticationType",
    "aws_project_region",
    "IotEndpoint",
    "iotEndpoint",
    "shadow",
    "eu-west-1",
    "eu-central-1",
]

CONTEXT_CHARS = 150
MAX_HITS_PER_KEYWORD = 8


def scan(apk_path):
    apk_path = Path(apk_path)
    with zipfile.ZipFile(apk_path, 'r') as z:
        names = z.namelist()
        bundle_name = BUNDLE_PATH if BUNDLE_PATH in names else None
        if not bundle_name:
            print("Bundle not found at expected path.")
            return
        data = z.read(bundle_name)

    # Decode once as latin-1 (preserves byte offsets 1:1, safe for searching)
    text = data.decode('latin-1', errors='replace')
    text_lower = text.lower()

    print(f"Bundle size: {len(text)} chars\n")
    print("=" * 70)

    for kw in KEYWORDS:
        kw_lower = kw.lower()
        positions = []
        start = 0
        while True:
            idx = text_lower.find(kw_lower, start)
            if idx == -1:
                break
            positions.append(idx)
            start = idx + 1
            if len(positions) >= MAX_HITS_PER_KEYWORD:
                break

        if not positions:
            continue

        print(f"\n[{kw}] - {len(positions)} hit(s) (showing up to {MAX_HITS_PER_KEYWORD}):")
        for pos in positions:
            lo = max(0, pos - CONTEXT_CHARS // 2)
            hi = min(len(text), pos + len(kw) + CONTEXT_CHARS // 2)
            snippet = text[lo:hi].replace('\n', ' ').replace('\r', ' ')
            print(f"    ...{snippet}...")

    print("\n" + "=" * 70)
    print("Done. Look for a JSON-looking config block containing several")
    print("of these keys together - that's the real Amplify/AppSync config.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python extract_rn_context.py <path-to-apk>")
        sys.exit(1)
    scan(sys.argv[1])
