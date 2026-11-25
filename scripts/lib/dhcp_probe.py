#!/usr/bin/env python3
"""Val Ark: is there a DHCP server on this wired link? (issue #148)

    dhcp_probe.py IFACE [SECONDS]

Broadcasts ONE DHCPDISCOVER on IFACE and listens for DHCPOFFERs for SECONDS
(default 4). Prints the server identifier of every server that answered, one
IPv4 per line (option 54, else the packet's source address). Nothing printed =
no server answered in the window. It only ever sends a DISCOVER, never a REQUEST,
so no lease is taken from a real server.

Receive side uses an AF_PACKET socket bound to IFACE, so it works even while a
DHCP client (dhclient/NetworkManager) holds UDP port 68. Needs root
(CAP_NET_RAW for AF_PACKET, SO_BINDTODEVICE on send).

Exit 0 = probe ran (output may be empty) · 2 = probe could not run (no root, no
such interface, socket error) · 64 = usage. Callers treat 2 as "unknown" and fail
closed: never start serving on an unknown.
"""
import os
import random
import select
import socket
import struct
import sys
import time

ETH_P_IP = 0x0800
SO_BINDTODEVICE = getattr(socket, "SO_BINDTODEVICE", 25)
MAGIC = b"\x63\x82\x53\x63"


def mac_of(iface):
    with open("/sys/class/net/%s/address" % iface) as f:
        return bytes(int(x, 16) for x in f.read().strip().split(":"))


def discover(xid, mac):
    pkt = struct.pack("!BBBBIHH", 1, 1, 6, 0, xid, 0, 0x8000)  # broadcast flag
    pkt += b"\x00" * 16                                          # ciaddr..giaddr
    pkt += mac + b"\x00" * (16 - len(mac)) + b"\x00" * 192       # chaddr, sname, file
    pkt += MAGIC
    pkt += bytes([53, 1, 1])                                     # DHCPDISCOVER
    pkt += bytes([55, 4, 1, 3, 6, 54])                           # param request list
    pkt += bytes([255])
    return pkt + b"\x00" * max(0, 300 - len(pkt))


def parse_offer(frame, xid):
    """frame = IPv4 packet (AF_PACKET SOCK_DGRAM strips the link header)."""
    if len(frame) < 20 or frame[0] >> 4 != 4 or frame[9] != 17:
        return None
    ihl = (frame[0] & 0x0F) * 4
    src = socket.inet_ntoa(frame[12:16])
    udp = frame[ihl:ihl + 8]
    if len(udp) < 8:
        return None
    sport, dport = struct.unpack("!HH", udp[:4])
    if sport != 67 or dport != 68:
        return None
    b = frame[ihl + 8:]
    if len(b) < 240 or b[0] != 2 or struct.unpack("!I", b[4:8])[0] != xid or b[236:240] != MAGIC:
        return None
    i, msg, sid = 240, None, None
    while i < len(b):
        code = b[i]
        if code == 255:
            break
        if code == 0:
            i += 1
            continue
        if i + 1 >= len(b):
            break
        ln = b[i + 1]
        val = b[i + 2:i + 2 + ln]
        if code == 53 and ln == 1:
            msg = val[0]
        elif code == 54 and ln == 4:
            sid = socket.inet_ntoa(val)
        i += 2 + ln
    if msg != 2:   # only OFFERs count
        return None
    return sid or src


def main(argv):
    if len(argv) < 2 or len(argv) > 3:
        sys.stderr.write("usage: dhcp_probe.py IFACE [SECONDS]\n")
        return 64
    iface = argv[1]
    try:
        window = float(argv[2]) if len(argv) == 3 else 4.0
    except ValueError:
        sys.stderr.write("dhcp_probe: SECONDS must be a number\n")
        return 64
    try:
        mac = mac_of(iface)
        xid = random.getrandbits(32)
        rx = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, socket.htons(ETH_P_IP))
        rx.bind((iface, ETH_P_IP))
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        tx.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, iface.encode() + b"\0")
        tx.sendto(discover(xid, mac), ("255.255.255.255", 67))
    except (OSError, ValueError) as e:
        sys.stderr.write("dhcp_probe: cannot probe %s: %s\n" % (iface, e))
        return 2
    seen = []
    end = time.monotonic() + window
    while True:
        left = end - time.monotonic()
        if left <= 0:
            break
        r, _, _ = select.select([rx], [], [], left)
        if not r:
            break
        try:
            frame = rx.recv(4096)
        except OSError:
            break
        sid = parse_offer(frame, xid)
        if sid and sid not in seen:
            seen.append(sid)
            print(sid, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
