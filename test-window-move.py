#!/usr/bin/env python3
"""
Test script for window move to space functionality.
"""

import argparse
import json
import socket
import sys
import time
import uuid


class GridClient:
    """Simple client for GridServer"""

    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.sock = None

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
        if self.sock:
            self.sock.close()
            self.sock = None

    def send_request(self, method: str, params: dict = None):
        """Send a request and wait for response"""
        request_id = str(uuid.uuid4())
        message = {
            "type": "request",
            "request": {
                "id": request_id,
                "method": method,
                "params": params or {}
            },
            "response": None,
            "event": None
        }

        # Send request
        json_str = json.dumps(message) + "\n"
        self.sock.sendall(json_str.encode('utf-8'))

        # Read response
        buffer = ""
        while True:
            chunk = self.sock.recv(4096).decode('utf-8')
            if not chunk:
                raise RuntimeError("Connection closed")

            buffer += chunk
            if '\n' in buffer:
                line, buffer = buffer.split('\n', 1)
                response = json.loads(line)
                if response.get('type') == 'response':
                    return response['response']


def main():
    parser = argparse.ArgumentParser(description='Test window move functionality')
    parser.add_argument('--socket', default='/tmp/grid-server.sock', help='Socket path')
    args = parser.parse_args()

    client = GridClient(args.socket)

    if not client.connect():
        sys.exit(1)

    try:
        # Get current state
        print("\n📊 Getting current state...")
        response = client.send_request('dump')

        if response.get('error'):
            print(f"✗ Error: {response['error']}")
            sys.exit(1)

        result = response.get('result', {})
        windows = result.get('windows', {})
        spaces = result.get('spaces', {})

        print(f"✓ Found {len(windows)} windows and {len(spaces)} spaces\n")

        # Display spaces
        print("📍 Available Spaces:")
        for space_id, space_info in sorted(spaces.items(), key=lambda x: x[1].get('index', 0)):
            space_type = space_info.get('type', 'unknown')
            display_uuid = space_info.get('displayUUID', 'unknown')[:8]
            index = space_info.get('index', '?')
            print(f"  [{index}] Space {space_id} (type={space_type}, display={display_uuid}...)")

        # Display windows
        print(f"\n🪟 Available Windows:")
        window_list = []
        for win_id, win_info in windows.items():
            app_name = win_info.get('appName', 'Unknown')
            title = win_info.get('title', 'Untitled')
            space_ids = win_info.get('spaceIDs', [])
            current_space = space_ids[0] if space_ids else None
            window_list.append((win_id, app_name, title, current_space))
            print(f"  Window {win_id}: {app_name} - {title}")
            print(f"    Current space: {current_space}")

        if not window_list:
            print("✗ No windows found to test with")
            sys.exit(1)

        # Pick a window and target space
        test_window_id = input(f"\n🎯 Enter window ID to move (or press Enter for {window_list[0][0]}): ").strip()
        if not test_window_id:
            test_window_id = window_list[0][0]

        # Find current space
        current_space = None
        for win_id, _, _, space_id in window_list:
            if win_id == test_window_id:
                current_space = space_id
                break

        print(f"\nWindow {test_window_id} is currently on space {current_space}")

        # Get list of user spaces (exclude fullscreen spaces)
        user_spaces = [sid for sid, info in spaces.items() if info.get('type') == 0]
        print(f"\nUser spaces available: {user_spaces}")

        # Pick a different space
        target_space = None
        for space_id in user_spaces:
            if space_id != current_space:
                target_space = space_id
                break

        if not target_space:
            print("✗ No alternative space found")
            sys.exit(1)

        target_space_input = input(f"\n🎯 Enter target space ID (or press Enter for {target_space}): ").strip()
        if target_space_input:
            target_space = target_space_input

        print(f"\n🚀 Moving window {test_window_id} to space {target_space}...")

        # Move the window
        response = client.send_request('updateWindow', {
            'windowId': int(test_window_id),
            'spaceId': target_space
        })

        if response.get('error'):
            error = response['error']
            print(f"\n❌ Move FAILED:")
            print(f"  Code: {error.get('code')}")
            print(f"  Message: {error.get('message')}")
            if error.get('data'):
                print(f"  Details: {json.dumps(error['data'], indent=2)}")
        else:
            result = response.get('result', {})
            print(f"\n✓ Server response: {json.dumps(result, indent=2)}")

            # Verify the move
            print("\n🔍 Verifying move...")
            time.sleep(0.5)

            response = client.send_request('dump')
            result = response.get('result', {})
            windows = result.get('windows', {})

            if test_window_id in windows:
                new_space_ids = windows[test_window_id].get('spaceIDs', [])
                new_space = new_space_ids[0] if new_space_ids else None

                if new_space == target_space:
                    print(f"✓ SUCCESS! Window is now on space {new_space}")
                else:
                    print(f"❌ FAILED! Window is still on space {new_space}, expected {target_space}")
            else:
                print(f"⚠️  Warning: Window {test_window_id} not found in state")

        print("\n💡 Check server logs for detailed diagnostics")

    except KeyboardInterrupt:
        print("\n\nInterrupted")
    except Exception as e:
        print(f"✗ Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
    finally:
        client.disconnect()


if __name__ == '__main__':
    main()
