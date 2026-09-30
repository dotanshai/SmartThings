"""
diagnose_googletv.py

Standalone triage tool for "the SmartThings Google TV driver doesn't work
on my TV" reports. Runs entirely on the tester's own PC -- no SmartThings
CLI, no hub access, no driver installation needed. The goal is to answer
one question fast: is this a problem with the TV/network, or something
that needs the driver itself looked at?

Produces a clean, copy-paste-able report. Ask whoever's having trouble to
run this and send you the full output before doing anything else.

Usage:
    python diagnose_googletv.py <TV_IP>

Requires only the Python standard library for the connectivity checks.
The deeper pairing test (step 4) additionally needs:
    python -m pip install androidtvremote2
-- if that's not installed, the script still runs steps 1-3 and says so.
"""
import socket
import ssl
import sys
import time


def section(title):
    print()
    print('=' * 60)
    print(title)
    print('=' * 60)


def check_tcp_port(ip, port, timeout=5):
    """Returns (reachable: bool, detail: str)."""
    start = time.time()
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            elapsed = time.time() - start
            return True, f'connected in {elapsed:.2f}s'
    except (socket.timeout, TimeoutError):
        return False, f'timed out after {timeout}s (port likely filtered/closed, or wrong IP)'
    except ConnectionRefusedError:
        return False, 'connection refused (nothing listening on this port)'
    except OSError as e:
        return False, f'error: {e}'


def check_tls_handshake(ip, port, timeout=5):
    """Attempts a bare TLS handshake (no client cert) just to confirm
    something TLS-speaking is actually listening. Returns (ok, detail)."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((ip, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=ip) as tls_sock:
                version = tls_sock.version()
                cipher = tls_sock.cipher()
                return True, f'TLS handshake OK -- version={version}, cipher={cipher[0] if cipher else "?"}'
    except (socket.timeout, TimeoutError):
        return False, f'TLS handshake timed out after {timeout}s'
    except ssl.SSLError as e:
        return False, f'TLS handshake failed: {e}'
    except OSError as e:
        return False, f'connection error: {e}'


def try_full_pairing_check(ip):
    """Uses the reference androidtvremote2 library, if installed, to
    confirm the device speaks the actual Android TV Remote application
    protocol (not just bare TLS) -- this is the same check the SmartThings
    driver ultimately needs to pass. Does not complete pairing (no code
    entry here), just confirms the device responds correctly."""
    try:
        import asyncio
        from androidtvremote2 import AndroidTVRemote
    except ImportError:
        print('androidtvremote2 not installed -- skipping the deep protocol check.')
        print('To enable it: python -m pip install androidtvremote2')
        return None

    async def _check():
        remote = AndroidTVRemote(
            client_name='SmartThings Diagnostic',
            certfile='diag_cert.pem',
            keyfile='diag_key.pem',
            host=ip,
        )
        await remote.async_generate_cert_if_missing()
        name, mac = await remote.async_get_name_and_mac()
        return name, mac

    try:
        name, mac = asyncio.run(_check())
        return True, f'device responded -- name="{name}", MAC={mac}'
    except Exception as e:
        return False, f'{type(e).__name__}: {e}'


def main():
    if len(sys.argv) < 2:
        print('Usage: python diagnose_googletv.py <TV_IP>')
        sys.exit(1)

    ip = sys.argv[1]

    print(f'Google TV / Android TV connectivity diagnostic')
    print(f'Target: {ip}')
    print(f'Time: {time.strftime("%Y-%m-%d %H:%M:%S")}')

    section('1. Pairing port (6467) reachability')
    ok, detail = check_tcp_port(ip, 6467)
    print(('PASS' if ok else 'FAIL') + f' -- {detail}')
    pairing_port_ok = ok

    section('2. Remote-control port (6466) reachability')
    ok, detail = check_tcp_port(ip, 6466)
    print(('PASS' if ok else 'FAIL') + f' -- {detail}')

    section('3. TLS handshake on pairing port')
    if pairing_port_ok:
        ok, detail = check_tls_handshake(ip, 6467)
        print(('PASS' if ok else 'FAIL') + f' -- {detail}')
        tls_ok = ok
    else:
        print('SKIPPED -- port 6467 wasn\'t reachable, so there\'s nothing to test TLS against.')
        tls_ok = False

    section('4. Full Android TV Remote protocol check (reference library)')
    result = try_full_pairing_check(ip)
    if result is None:
        protocol_ok = None
    else:
        ok, detail = result
        print(('PASS' if ok else 'FAIL') + f' -- {detail}')
        protocol_ok = ok

    section('Summary')
    if protocol_ok:
        print('This device fully supports the Android TV Remote protocol.')
        print('The SmartThings driver should work with it -- if it still')
        print('doesn\'t, the problem is in the driver/hub side, not the TV.')
    elif protocol_ok is False:
        print('The device is reachable but did not respond correctly to')
        print('the Android TV Remote protocol. This usually means the')
        print('device is NOT running certified Android TV OS / Google TV')
        print('(common on generic/AliExpress Android boxes) -- the driver')
        print('is unlikely to ever work with this specific device.')
    elif tls_ok:
        print('TLS works but the deeper protocol check wasn\'t run (library')
        print('not installed). Run: python -m pip install androidtvremote2')
        print('and try again for a definitive answer.')
    elif pairing_port_ok:
        print('The port is open but doesn\'t speak TLS -- likely not an')
        print('Android TV Remote service at all. Double check this is the')
        print('right device and IP address.')
    else:
        print('Nothing is reachable on the expected ports. Check: the IP')
        print('address is correct, the device is powered on and connected')
        print('to the network, and nothing (router/firewall/AP isolation)')
        print('is blocking this PC from reaching it.')

    print()
    print('(Copy everything above and send it to Shai for help.)')


if __name__ == '__main__':
    main()
