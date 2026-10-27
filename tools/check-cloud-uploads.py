#!/usr/bin/env python3
"""Exercise the app's Swift upload code with local HTTP failures. No credentials required."""
import collections
import hashlib
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
MIB = 1024 * 1024


def main():
    with tempfile.TemporaryDirectory(prefix="screendrop-upload-check-") as temporary:
        directory = Path(temporary)
        small = directory / "small.mov"
        large = directory / "large.mov"
        # Existing Workers must still accept medium recordings that were
        # unnecessarily routed through multipart by the original 32 MiB cutoff.
        small.write_bytes(b"s" * (40 * MIB))
        # Above Cloudflare's request limit, with non-identical parts to catch
        # ordering, duplication, and final-part truncation errors.
        digest = hashlib.sha256()
        with large.open("wb") as output:
            for index in range(110):
                block = bytes([index]) * MIB
                output.write(block)
                digest.update(block)
            output.write(b"final partial block")
            digest.update(b"final partial block")
        expected_hash = digest.hexdigest()
        attempts = collections.Counter()
        aborted = set()
        completed = set()
        parts = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def reply(self, status, value):
                body = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                self.close_connection = True

            def handle_request(self):
                url = urllib.parse.urlsplit(self.path)
                scenario = url.path.split("/")[1]
                query = urllib.parse.parse_qs(url.query)
                attempts[(scenario, self.command, url.path)] += 1
                assert self.headers.get("Authorization") == "Bearer local-test-token"
                if scenario == "early413":
                    # Leave an early rejection incomplete while the client is
                    # still sending. URLSession throws a timeout, with the HTTP
                    # status available only in its task metrics.
                    self.wfile.write(b"HTTP/1.1 413 Payload Too Large\r\nContent-Length: 1000\r\n\r\nrejected")
                    self.wfile.flush()
                    time.sleep(3)
                    self.close_connection = True
                    return
                if scenario == "timeout":
                    time.sleep(3)
                    self.close_connection = True
                    return
                length = int(self.headers.get("Content-Length", "0"))
                assert length <= (90 if scenario == "single" else 16) * MIB, f"Oversized request: {length}"
                body = self.rfile.read(length)
                if scenario == "unauthorized":
                    return self.reply(401, {})
                if scenario.startswith("unsupported"):
                    return self.reply(int(scenario[-3:]), {})
                if self.command == "DELETE":
                    aborted.add(scenario)
                    return self.reply(200, {"aborted": True})
                if url.path.endswith("/api/upload"):
                    assert scenario == "single" and body == small.read_bytes()
                    completed.add(scenario)
                    return self.reply(201, dict(id="single", url="http://localhost/single", filename="recording.mov", size=len(body)))
                if url.path.endswith("/multipart"):
                    assert self.command == "POST"
                    assert self.headers["X-Filename"] == "recording.mov"
                    return self.reply(201, dict(id="test", key="uploads/test/recording.mov", uploadId="session"))
                if self.command == "PUT":
                    number = int(query["partNumber"][0])
                    attempts[(scenario, "part", number)] += 1
                    if scenario == "part404":
                        return self.reply(404, {})
                    if scenario == "multipart" and number == 2 and attempts[(scenario, "part", number)] == 1:
                        return self.reply(503, {})
                    if scenario == "cancel" and number > 1:
                        time.sleep(3)
                        self.close_connection = True
                        return
                    parts[(scenario, number)] = body
                    return self.reply(200, dict(partNumber=number, etag=f"etag-{number}"))
                assert self.command == "POST"
                if scenario == "complete503":
                    return self.reply(503, {})
                manifest = json.loads(body)
                ordered = [parts[(scenario, part["partNumber"])] for part in manifest["parts"]]
                assert all(len(part) == 16 * MIB for part in ordered[:-1])
                assert hashlib.sha256(b"".join(ordered)).hexdigest() == expected_hash
                completed.add(scenario)
                return self.reply(201, dict(id="test", url="http://localhost/test", filename="recording.mov", size=sum(map(len, ordered))))

            do_GET = handle_request
            do_PUT = handle_request
            do_POST = handle_request
            do_DELETE = handle_request

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        executable = directory / "upload-check"
        try:
            subprocess.run([
                "swiftc", "-parse-as-library", "-strict-concurrency=complete",
                str(ROOT / "Screendrop/CloudUploadRequest.swift"),
                str(ROOT / "Screendrop/MultipartCloudUpload.swift"),
                str(ROOT / "tools/CloudUploadRegressionCheck.swift"), "-o", str(executable),
            ], check=True)
            subprocess.run([str(executable), f"http://127.0.0.1:{server.server_port}", str(small), str(large)], check=True, timeout=60)
            assert completed == {"single", "multipart"}
            assert aborted == {"part404", "cancel"}
            assert attempts[("multipart", "part", 2)] == 2
            assert attempts[("part404", "part", 1)] == 1
            assert attempts[("complete503", "POST", "/complete503/api/upload/multipart/test")] == 1
            print("PASS byte integrity, bounded parts, retry counts, and abort behavior")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
