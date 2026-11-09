#!/usr/bin/env python3
"""Count one account's SMB2 logon attempts and refusals in a tcpdump capture of port 445.

Run it on the Samba fixture: `tcpdump -i any -s 0 -w CAPTURE tcp port 445`, run the client, stop
tcpdump, then pass CAPTURE ACCOUNT. Session setup precedes encryption, so the NTLMSSP
AUTHENTICATE message (with the account name) and the server's status are readable. Prints
counts only: no addresses, names or secrets. Other refusals, such as PASSWORD_EXPIRED, are
counted by their NT status in `otherStatuses`.
"""
import json
import struct
import sys

SESSION_SETUP = 1
LOGON_FAILURE = 0xC000006D


def packets(path):
    with open(path, 'rb') as capture:
        header = capture.read(24)
        magic = struct.unpack('<I', header[:4])[0]
        order = '<' if magic in (0xA1B2C3D4, 0xA1B23C4D) else '>'
        link = struct.unpack(order + 'I', header[20:24])[0]
        while record := capture.read(16):
            length = struct.unpack(order + 'IIII', record)[2]
            frame = capture.read(length)
            # Linux cooked capture v1 (113) or v2 (276), else Ethernet.
            offset = {113: 16, 276: 20}.get(link, 14)
            ip = frame[offset:]
            if not ip or ip[0] >> 4 != 4:
                continue
            ip_length = (ip[0] & 15) * 4
            tcp = ip[ip_length:]
            source, destination = struct.unpack('>HH', tcp[:4])
            stream = (ip[12:16], source, ip[16:20], destination)
            yield frozenset([stream[:2], stream[2:]]), tcp[(tcp[12] >> 4) * 4:]


def main():
    capture, account = sys.argv[1:]
    name = account.encode('utf-16-le')
    attempts, refused, accepted = 0, 0, 0
    other = {}
    pending = {}
    for stream, payload in packets(capture):
        start = payload.find(b'\xfeSMB')
        while start >= 0:
            status, command = struct.unpack('<IH', payload[start + 8:start + 14])
            flags = struct.unpack('<I', payload[start + 16:start + 20])[0]
            if command == SESSION_SETUP and not flags & 1:
                ntlm = payload.find(b'NTLMSSP\x00\x03\x00\x00\x00', start)
                if ntlm >= 0 and name.lower() in payload[ntlm:].lower():
                    attempts += 1
                    pending[stream] = pending.get(stream, 0) + 1
            elif command == SESSION_SETUP and pending.get(stream):
                pending[stream] -= 1
                refused += status == LOGON_FAILURE
                accepted += status == 0
                if status not in (0, LOGON_FAILURE):
                    other[f'0x{status:08X}'] = other.get(f'0x{status:08X}', 0) + 1
            start = payload.find(b'\xfeSMB', start + 4)
    print(json.dumps({'attempts': attempts, 'logonFailures': refused, 'accepted': accepted,
                      'otherStatuses': other}))


if __name__ == '__main__':
    main()
