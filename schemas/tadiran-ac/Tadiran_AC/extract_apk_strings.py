"""
Extracts readable strings (URLs, API paths, auth provider hints, keys)
from an APK's compiled code and resources, without full decompilation.

Run with: python extract_apk_strings.py tadiran.apk
"""
import sys
import re
import zipfile
from pathlib import Path

# Patterns worth hunting for
URL_PATTERN = re.compile(rb'https?://[a-zA-Z0-9\-\._~:/?#\[\]@!$&\'()*+,;=%]+')
DOMAIN_HINTS = re.compile(rb'[a-zA-Z0-9\-]+\.(tadiran|amazonaws|cognito|cloudfront|execute-api)[a-zA-Z0-9\-\.]*', re.IGNORECASE)
AUTH_HINTS = re.compile(rb'(cognito|oauth|client_id|client_secret|api[_-]?key|apikey|bearer|x-api-key|firebase|amplify)', re.IGNORECASE)


def extract_strings_from_bytes(data, min_len=6):
    """Pull printable ASCII runs from raw binary - simple but effective for dex files."""
    pattern = re.compile(rb'[\x20-\x7e]{%d,}' % min_len)
    return pattern.findall(data)


def scan_apk(apk_path):
    apk_path = Path(apk_path)
    print(f"Scanning {apk_path} ({apk_path.stat().st_size / 1_000_000:.1f} MB)\n")

    found_urls = set()
    found_domains = set()
    found_auth_hints = {}

    with zipfile.ZipFile(apk_path, 'r') as z:
        names = z.namelist()

        # Focus on dex (compiled code) and common config/resource files
        targets = [n for n in names if n.endswith('.dex')]
        targets += [n for n in names if 'assets/' in n and (n.endswith('.json') or n.endswith('.xml') or n.endswith('.properties'))]
        targets += [n for n in names if n == 'resources.arsc']
        targets += [n for n in names if n.endswith('AndroidManifest.xml')]

        print(f"Files to scan: {len(targets)}")
        for n in targets:
            print(f"  - {n}")
        print()

        for name in targets:
            try:
                data = z.read(name)
            except Exception as e:
                print(f"  [skip] {name}: {e}")
                continue

            # URLs
            for m in URL_PATTERN.findall(data):
                found_urls.add(m.decode('utf-8', errors='replace'))

            # Domain-ish hints (covers cases URL regex misses, e.g. split strings)
            for m in DOMAIN_HINTS.findall(data):
                found_domains.add(m.decode('utf-8', errors='replace'))

            # Auth-related keyword hits, with a bit of surrounding context
            all_strings = extract_strings_from_bytes(data, min_len=4)
            for s in all_strings:
                if AUTH_HINTS.search(s):
                    text = s.decode('utf-8', errors='replace')
                    found_auth_hints.setdefault(text, 0)
                    found_auth_hints[text] += 1

    print("=" * 70)
    print(f"URLS FOUND ({len(found_urls)}):")
    print("=" * 70)
    for u in sorted(found_urls):
        print(f"  {u}")

    print()
    print("=" * 70)
    print(f"DOMAIN HINTS ({len(found_domains)}):")
    print("=" * 70)
    for d in sorted(found_domains):
        print(f"  {d}")

    print()
    print("=" * 70)
    print(f"AUTH / API-KEY RELATED STRINGS ({len(found_auth_hints)}):")
    print("=" * 70)
    # Sort by frequency, most common first - often the real config, not noise
    for s, count in sorted(found_auth_hints.items(), key=lambda x: -x[1])[:80]:
        print(f"  [{count}x] {s}")

    print()
    print("Done. Look especially for:")
    print("  - Any api.tadiran-iot.co.il paths beyond just the bare domain")
    print("  - 'cognito' hits -> means AWS Cognito auth (well-documented, big win)")
    print("  - 'client_id' / pool id strings near cognito hits")
    print("  - execute-api.*.amazonaws.com -> AWS API Gateway URL (the real API host)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python extract_apk_strings.py <path-to-apk>")
        sys.exit(1)
    scan_apk(sys.argv[1])
