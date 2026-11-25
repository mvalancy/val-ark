#!/usr/bin/env python3
"""Val Ark: is there a DHCP server on this wired link? (issue #148)

    dhcp_probe.py IFACE [WAIT] [TRIES]

Broadcasts up to TRIES (default 4) DHCPDISCOVERs on IFACE at 0, 2, 4 and 8 s,
each with a fresh xid, then keeps listening WAIT seconds (default 4) after the
last one. Several tries matter: a switch port in STP listening/learning drops
frames for up to ~30 s after link-up, so one DISCOVER is easily lost. It prints
the server identifier of the first server that answers (option 54, else the
packet's source address) and exits. Nothing printed = nobody answered.

It only ever sends DISCOVER, never REQUEST, so no lease is taken from a real
server. A BOOTP reply without a DHCP message type still counts as a server
(fail closed: never serve next to something that answers).

Receive side: an AF_PACKET socket bound to IFACE, so it works while a DHCP
client (dhclient/NetworkManager) holds UDP port 68. Frames this host sent
(pkttype PACKET_OUTGOING, or our own NIC MAC as the source) are ignored, so the
Ark's own dnsmasq never counts as "another server", while a second Ark using the
same address still does. Needs root (CAP_NET_RAW, SO_BINDTODEVICE).

Exit 0 = probe ran (output may be empty) · 2 = probe could not run (no root,
no such interface, socket error) · 64 = usage. Callers treat 2 as "unknown"
and fail closed.
"""
import random
import select
import socket
import struct
import sys
import time

ETH_P_IP = 0x0800
PACKET_OUTGOING = 4
SO_BINDTODEVICE = getattr(socket, "SO_BINDTODEVICE", 25)
MAGIC = b"\x63\x82\x53\x63"
SCHEDULE = (0, 2, 4, 8)


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


def _options(buf, into):
    i = 0
    while i < len(buf):
        code = buf[i]
        if code == 255:
            break
        if code == 0:
            i += 1
            continue
        if i + 1 >= len(buf):
            break
        ln = buf[i + 1]
        into.setdefault(code, buf[i + 2:i + 2 + ln])
        i += 2 + ln


def parse_offer(frame, xids, ports=(68,)):
    """frame = IPv4 packet (AF_PACKET SOCK_DGRAM strips the link header).
    Returns the answering server's id for an OFFER (or option-less BOOTP reply)
    to one of our xids, else None."""
    if len(frame) < 20 or frame[0] >> 4 != 4 or frame[9] != 17:
        return None
    ihl = (frame[0] & 0x0F) * 4
    if ihl < 20 or len(frame) < ihl + 8:
        return None
    if struct.unpack("!H", frame[6:8])[0] & 0x3FFF:   # MF flag or fragment offset
        return None
    src = socket.inet_ntoa(frame[12:16])
    sport, dport = struct.unpack("!HH", frame[ihl:ihl + 4])
    if sport != 67 or dport not in ports:
        return None
    b = frame[ihl + 8:]
    if len(b) < 236 or b[0] != 2 or struct.unpack("!I", b[4:8])[0] not in xids:
        return None
    if b[236:240] != MAGIC:            # plain BOOTP reply: a server is there
        return src
    opts = {}
    _options(b[240:], opts)
    ov = opts.get(52)
    if ov and len(ov) == 1:            # option overload: file and/or sname hold options
        if ov[0] in (1, 3):
            _options(b[108:236], opts)
        if ov[0] in (2, 3):
            _options(b[44:108], opts)
    mt = opts.get(53)
    sid = opts.get(54)
    sid = socket.inet_ntoa(sid) if sid and len(sid) == 4 else None
    if mt is None or len(mt) != 1:     # BOOTP-style reply: still a server (fail closed)
        return sid or src
    if mt[0] != 2:                     # only OFFERs count (we never REQUEST)
        return None
    return sid or src


def accept_link(addr, own_mac):
    """addr = AF_PACKET recvfrom address (ifname, proto, pkttype, hatype, hwaddr).
    Drop what this host sent itself."""
    if len(addr) > 2 and addr[2] == PACKET_OUTGOING:
        return False
    if len(addr) > 4 and bytes(addr[4][:6]) == own_mac:
        return False
    return True


def run_probe(send, recv, mac, ports, schedule=SCHEDULE, wait=4.0, now=time.monotonic):
    """send(pkt); recv(timeout) -> (frame, addr) or None. Returns [server] or []."""
    xids, i, t0 = set(), 0, now()
    end = t0 + schedule[-1] + wait
    while True:
        while i < len(schedule) and now() - t0 >= schedule[i]:
            x = random.getrandbits(32)
            while x in xids:
                x = random.getrandbits(32)
            xids.add(x)
            send(discover(x, mac))
            i += 1
        left = end - now()
        if left <= 0:
            return []
        if i < len(schedule):
            left = min(left, max(0.0, t0 + schedule[i] - now()))
        r = recv(left)
        if r is None:
            continue
        frame, addr = r
        if not accept_link(addr, mac):
            continue
        sid = parse_offer(frame, xids, ports)
        if sid:
            return [sid]


def main(argv):
    if len(argv) < 2 or len(argv) > 4:
        sys.stderr.write("usage: dhcp_probe.py IFACE [WAIT] [TRIES]\n")
        return 64
    iface = argv[1]
    try:
        wait = float(argv[2]) if len(argv) > 2 else 4.0
        tries = int(argv[3]) if len(argv) > 3 else len(SCHEDULE)
        if wait < 0 or not 1 <= tries <= len(SCHEDULE):
            raise ValueError
    except ValueError:
        sys.stderr.write("dhcp_probe: WAIT must be a number >= 0, TRIES 1..%d\n" % len(SCHEDULE))
        return 64
    try:
        mac = mac_of(iface)
        rx = socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, socket.htons(ETH_P_IP))
        rx.bind((iface, ETH_P_IP))
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        tx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        tx.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        tx.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, iface.encode() + b"\0")
        try:
            tx.bind(("", 68))          # servers answer the client port...
        except OSError:
            tx.bind(("", 0))           # ...or, if a DHCP client holds it, our source port
        ports = (68, tx.getsockname()[1])
    except (OSError, ValueError) as e:
        sys.stderr.write("dhcp_probe: cannot probe %s: %s\n" % (iface, e))
        return 2

    def send(pkt):
        tx.sendto(pkt, ("255.255.255.255", 67))

    def recv(timeout):
        r, _, _ = select.select([rx], [], [], timeout)
        if not r:
            return None
        return rx.recvfrom(4096)

    try:
        for sid in run_probe(send, recv, mac, ports, SCHEDULE[:tries], wait):
            print(sid, flush=True)
    except OSError as e:
        sys.stderr.write("dhcp_probe: probe on %s failed: %s\n" % (iface, e))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
