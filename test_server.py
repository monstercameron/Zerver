#!/usr/bin/env python3
"""Simple HTTP client to test the Zerver server."""

import socket
import time
import sys

def test_server():
    # Wait for server to start
    time.sleep(1)
    
    try:
        # Connect to server
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        sock.connect(('127.0.0.1', 8080))
        
        # Send HTTP request
        request = b"GET / HTTP/1.1\r\nHost: localhost:8080\r\n\r\n"
        print(f"Sending request:\n{request.decode()}")
        sock.sendall(request)
        
        # Receive response
        response = b""
        while True:
            try:
                chunk = sock.recv(1024)
                if not chunk:
                    break
                response += chunk
            except socket.timeout:
                break
        
        sock.close()
        
        print(f"\nReceived response:\n{response.decode()}")
        print(f"\nSuccess! Server responded with {len(response)} bytes")
        return True
        
    except Exception as e:
        print(f"Error: {e}")
        return False

if __name__ == "__main__":
    success = test_server()
    sys.exit(0 if success else 1)
