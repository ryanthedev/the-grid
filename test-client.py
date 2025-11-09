#!/usr/bin/env python3
"""
Test client for GridServer Unix domain socket server.
Demonstrates request/response and event streaming capabilities.
"""

import argparse
import json
import socket
import sys
import threading
import time
from datetime import datetime
from typing import Optional
import uuid


class GridClient:
    """Client for communicating with GridServer via Unix domain socket"""

    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.sock: Optional[socket.socket] = None
        self.running = False
        self.receive_thread: Optional[threading.Thread] = None

    def connect(self):
        """Connect to the server"""
        try:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.connect(self.socket_path)
            print(f"✓ Connected to {self.socket_path}")
            return True
        except Exception as e:
            print(f"✗ Connection failed: {e}", file=sys.stderr)
            return False

    def disconnect(self):
        """Disconnect from the server"""
        self.running = False
        if self.sock:
            self.sock.close()
            self.sock = None
        if self.receive_thread:
            self.receive_thread.join(timeout=1)
        print("✓ Disconnected")

    def send_request(self, method: str, params: Optional[dict] = None) -> str:
        """Send a request and return the request ID"""
        request_id = str(uuid.uuid4())
        message = {
            "type": "request",
            "request": {
                "id": request_id,
                "method": method,
                "params": params
            },
            "response": None,
            "event": None
        }

        self._send_message(message)
        return request_id

    def send_event(self, event_type: str, data: Optional[dict] = None):
        """Send an event (clients can send events too)"""
        message = {
            "type": "event",
            "request": None,
            "response": None,
            "event": {
                "eventType": event_type,
                "data": data,
                "timestamp": datetime.utcnow().isoformat() + "Z"
            }
        }

        self._send_message(message)

    def _send_message(self, message: dict):
        """Send a JSON message to the server"""
        if not self.sock:
            raise RuntimeError("Not connected")

        json_str = json.dumps(message) + "\n"
        self.sock.sendall(json_str.encode('utf-8'))

    def start_receiving(self):
        """Start receiving messages in a background thread"""
        self.running = True
        self.receive_thread = threading.Thread(target=self._receive_loop, daemon=True)
        self.receive_thread.start()

    def _receive_loop(self):
        """Receive and process messages"""
        buffer = ""

        while self.running and self.sock:
            try:
                chunk = self.sock.recv(4096).decode('utf-8')
                if not chunk:
                    print("\n✗ Server closed connection")
                    break

                buffer += chunk

                # Process complete messages (newline-delimited)
                while '\n' in buffer:
                    line, buffer = buffer.split('\n', 1)
                    if line.strip():
                        self._handle_message(line)

            except Exception as e:
                if self.running:
                    print(f"\n✗ Receive error: {e}", file=sys.stderr)
                break

    def _handle_message(self, json_str: str):
        """Handle a received message"""
        try:
            message = json.loads(json_str)
            msg_type = message.get('type')

            if msg_type == 'response':
                self._handle_response(message['response'])
            elif msg_type == 'event':
                self._handle_event(message['event'])
            else:
                print(f"Unknown message type: {msg_type}")

        except Exception as e:
            print(f"✗ Message parse error: {e}", file=sys.stderr)

    def _handle_response(self, response: dict):
        """Handle a response message"""
        request_id = response.get('id', 'unknown')
        error = response.get('error')
        result = response.get('result')

        if error:
            print(f"\n✗ Response [{request_id[:8]}]: ERROR")
            print(f"  Code: {error.get('code')}")
            print(f"  Message: {error.get('message')}")
            if error.get('data'):
                print(f"  Data: {json.dumps(error.get('data'), indent=2)}")
        else:
            print(f"\n✓ Response [{request_id[:8]}]:")
            print(f"  {json.dumps(result, indent=2)}")

    def _handle_event(self, event: dict):
        """Handle an event message"""
        event_type = event.get('eventType', 'unknown')
        data = event.get('data')
        timestamp = event.get('timestamp')

        print(f"\n⚡ Event [{event_type}] @ {timestamp}")
        if data:
            print(f"  {json.dumps(data, indent=2)}")


def interactive_mode(client: GridClient):
    """Run the client in interactive mode"""
    print("\n" + "="*60)
    print("GridServer Test Client - Interactive Mode")
    print("="*60)
    print("\nCommands:")
    print("  ping                 - Send a ping request")
    print("  echo <json>          - Echo back JSON params")
    print("  spaces               - Get spaces (mock data)")
    print("  windows              - Get windows (mock data)")
    print("  info                 - Get server info")
    print("  subscribe <type>     - Subscribe to events")
    print("  event <type> <json>  - Send an event")
    print("  quit                 - Quit")
    print("="*60 + "\n")

    client.start_receiving()

    try:
        while True:
            try:
                line = input("> ").strip()
                if not line:
                    continue

                parts = line.split(maxsplit=1)
                cmd = parts[0].lower()

                if cmd == 'quit':
                    break
                elif cmd == 'ping':
                    client.send_request('ping')
                elif cmd == 'echo':
                    params = json.loads(parts[1]) if len(parts) > 1 else {}
                    client.send_request('echo', params)
                elif cmd == 'spaces':
                    client.send_request('getSpaces')
                elif cmd == 'windows':
                    client.send_request('getWindows')
                elif cmd == 'info':
                    client.send_request('getServerInfo')
                elif cmd == 'subscribe':
                    event_type = parts[1] if len(parts) > 1 else 'all'
                    client.send_request('subscribe', {'eventType': event_type})
                elif cmd == 'event':
                    if len(parts) < 2:
                        print("Usage: event <type> [<json>]")
                        continue
                    event_parts = parts[1].split(maxsplit=1)
                    event_type = event_parts[0]
                    data = json.loads(event_parts[1]) if len(event_parts) > 1 else None
                    client.send_event(event_type, data)
                else:
                    print(f"Unknown command: {cmd}")

            except KeyboardInterrupt:
                print()
                break
            except Exception as e:
                print(f"Error: {e}", file=sys.stderr)

    finally:
        client.disconnect()


def run_tests(client: GridClient):
    """Run automated tests"""
    print("\n" + "="*60)
    print("Running GridServer Tests")
    print("="*60 + "\n")

    client.start_receiving()

    tests = [
        ('ping', None),
        ('echo', {'message': 'Hello, GridServer!', 'timestamp': time.time()}),
        ('getServerInfo', None),
        ('getSpaces', None),
        ('getWindows', None),
        ('subscribe', {'eventType': 'all'}),
    ]

    for method, params in tests:
        print(f"\nSending: {method}")
        client.send_request(method, params)
        time.sleep(0.5)

    # Wait for responses
    print("\n\nWaiting for events (5 seconds)...")
    time.sleep(5)

    print("\n" + "="*60)
    print("Tests completed")
    print("="*60 + "\n")

    client.disconnect()


def main():
    parser = argparse.ArgumentParser(description='GridServer Test Client')
    parser.add_argument(
        '--socket',
        default='/tmp/grid-server.sock',
        help='Path to Unix domain socket'
    )
    parser.add_argument(
        '--test',
        action='store_true',
        help='Run automated tests instead of interactive mode'
    )

    args = parser.parse_args()

    client = GridClient(args.socket)

    if not client.connect():
        sys.exit(1)

    try:
        if args.test:
            run_tests(client)
        else:
            interactive_mode(client)
    except KeyboardInterrupt:
        print("\n\nInterrupted")
        client.disconnect()


if __name__ == '__main__':
    main()
