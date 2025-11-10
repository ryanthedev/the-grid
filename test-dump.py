#!/usr/bin/env python3
"""Simple test script for the dump endpoint"""

import socket
import json

def test_dump():
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    try:
        sock.connect("/tmp/grid-server.sock")

        # Send dump request wrapped in Message envelope
        request = {
            "type": "request",
            "request": {
                "id": "test-1",
                "method": "dump",
                "params": {}
            },
            "response": None,
            "event": None
        }

        message = json.dumps(request) + "\n"
        sock.sendall(message.encode())

        # Receive response
        response_data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response_data += chunk
            if b"\n" in chunk:
                break

        message_envelope = json.loads(response_data.decode().strip())
        print("Response received:")
        print(json.dumps(message_envelope, indent=2))

        # Extract the actual response from the envelope
        response = message_envelope.get("response", {})

        # Check if we got state data
        if "result" in response:
            result = response["result"]
            print(f"\n✓ Got state dump with {len(result.get('windows', {}))} windows and {len(result.get('spaces', {}))} spaces")
            print(f"✓ Displays: {len(result.get('displays', []))}")
        else:
            print("✗ Error:", response.get("error"))

    except Exception as e:
        print(f"✗ Error: {e}")
    finally:
        sock.close()

if __name__ == "__main__":
    test_dump()
