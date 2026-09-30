"""
test_wol.py

Standalone Wake-on-LAN test, completely independent of SmartThings/the
hub. Sends the same magic packet to the same set of targets the driver
tries (broadcast on ports 9 and 7, subnet-directed broadcast, and a direct
unicast to the TV's IP), from this PC instead of the hub.

Why this matters: if the TV wakes when this script sends the packet but
NOT when the hub sends it, that points to something specific to the hub's
network stack/UDP handling. If it does NOT wake either way, that's strong,
near-conclusive evidence this is a genuine limitation of the TV's Wi-Fi
hardware/firmware -- not something fixable in the driver at all.

Usage:
    python test_wol.py AA:BB:CC:DD:EE:FF 192.168.1.137

The IP argument is optional but recommended (enables the subnet-broadcast
and unicast attempts, not just the plain broadcast).
"""
import socket
import sys


def mac_to_bytes(mac: str) -> bytes:
    hex_str = "".join(c for c in mac if c in "0123456789abcdefABCDEF")
    if len(hex_str) != 12:
        raise ValueError(f"MAC address must have 12 hex digits, got: {mac!r}")
    return bytes.fromhex(hex_str)


def subnet_broadcast(ip: str) -> str | None:
    parts = ip.split(".")
    if len(parts) != 4:
        return None
    return ".".join(parts[:3] + ["255"])


def send_packet(packet: bytes, ip: str, port: int) -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        sock.sendto(packet, (ip, port))
        print(f"  -> {ip}:{port} = sent")
    except OSError as e:
        print(f"  -> {ip}:{port} = FAILED: {e}")
    finally:
        sock.close()


def main():
    if len(sys.argv) < 2:
        print("Usage: python test_wol.py <MAC_ADDRESS> [TV_IP]")
        sys.exit(1)

    mac = sys.argv[1]
    target_ip = sys.argv[2] if len(sys.argv) > 2 else None

    mac_bytes = mac_to_bytes(mac)
    packet = b"\xff" * 6 + mac_bytes * 16

    print(f"Sending Wake-on-LAN magic packet for MAC {mac}")
    print(f"Packet size: {len(packet)} bytes")
    print()

    targets = [("255.255.255.255", 9), ("255.255.255.255", 7)]
    if target_ip:
        sb = subnet_broadcast(target_ip)
        if sb:
            targets.append((sb, 9))
        targets.append((target_ip, 9))
    else:
        print("(No TV IP given -- skipping subnet-broadcast and unicast attempts.")
        print(" Re-run with the IP as a second argument for the full test.)")
        print()

    for ip, port in targets:
        send_packet(packet, ip, port)

    print()
    print("Done. Watch the TV now -- if it powers on within the next ~10-15")
    print("seconds, Wake-on-LAN genuinely works for this device from this PC.")


if __name__ == "__main__":
    main()
