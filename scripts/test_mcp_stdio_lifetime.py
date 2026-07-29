#!/usr/bin/env python3
"""Prove mcp-stdio outlives the temporary thread that launched it on Linux."""

from __future__ import annotations

import json
import os
import queue
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import IO, Any


TIMEOUT_SECONDS = 10.0
TOKEN = "mcp-lifetime-test-token"


def fail(message: str) -> None:
    raise AssertionError(message)


def read_line(stream: IO[str], description: str) -> str:
    readable, _, _ = select.select([stream], [], [], TIMEOUT_SECONDS)
    if not readable:
        fail(f"timed out waiting for {description}")
    line = stream.readline()
    if line == "":
        fail(f"mcp-stdio closed while waiting for {description}")
    return line


def send_rpc(process: subprocess.Popen[str], request: dict[str, Any]) -> dict[str, Any]:
    if process.stdin is None or process.stdout is None:
        fail("mcp-stdio pipes are unavailable")
    process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
    process.stdin.flush()
    return json.loads(read_line(process.stdout, f"response to request {request['id']}"))


class FakeChoird:
    def __init__(self, socket_path: Path) -> None:
        self.socket_path = socket_path
        self.ready = threading.Event()
        self.registered = threading.Event()
        self.finished = threading.Event()
        self.errors: queue.Queue[BaseException] = queue.Queue()
        self.update_count = 0
        self.notes = "initial"
        self.thread = threading.Thread(target=self._run, name="fake-choird")

    def start(self) -> None:
        self.thread.start()
        if not self.ready.wait(TIMEOUT_SECONDS):
            fail("fake choird did not start")

    def join(self) -> None:
        if not self.finished.wait(TIMEOUT_SECONDS):
            fail("fake choird did not stop")
        self.thread.join()
        if not self.errors.empty():
            raise self.errors.get()

    def _respond(self, connection: socket.socket, result: dict[str, Any]) -> None:
        wire = json.dumps({"ok": True, "result": result}, separators=(",", ":"))
        connection.sendall(wire.encode() + b"\n")

    def _run(self) -> None:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(self.socket_path))
                listener.listen(1)
                self.ready.set()
                connection, _ = listener.accept()
                with connection, connection.makefile("r", encoding="utf-8") as reader:
                    registration = json.loads(reader.readline())
                    if registration.get("method") != "register":
                        fail("first bridge request was not registration")
                    if registration.get("args", {}).get("token") != TOKEN:
                        fail("bridge registration used the wrong token")
                    self._respond(connection, {})
                    self.registered.set()
                    for line in reader:
                        request = json.loads(line)
                        name = request.get("name")
                        if name == "task_get":
                            self._respond(
                                connection,
                                {"id": "choir-lifetime", "notes": self.notes},
                            )
                        elif name == "task_update":
                            self.update_count += 1
                            self.notes = request.get("args", {}).get("notes", "")
                            self._respond(connection, {"updated": True})
                        else:
                            fail(f"unexpected bridge request: {name!r}")
        except BaseException as error:
            self.errors.put(error)
        finally:
            self.ready.set()
            self.finished.set()


def main() -> int:
    if sys.platform != "linux":
        print("SKIP: PR_SET_PDEATHSIG lifetime regression is Linux-specific")
        return 0
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} /absolute/path/to/choir", file=sys.stderr)
        return 2
    executable = Path(sys.argv[1]).resolve()
    if not executable.is_file():
        print(f"choir binary does not exist: {executable}", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="choir-mcp-lifetime-") as temp:
        temp_path = Path(temp)
        socket_path = temp_path / "choird.sock"
        server = FakeChoird(socket_path)
        server.start()

        launched: queue.Queue[subprocess.Popen[str]] = queue.Queue()
        release_creator = threading.Event()

        def launch_from_temporary_thread() -> None:
            environment = os.environ.copy()
            environment["CHOIR_LISTEN_UDS"] = str(socket_path)
            environment["CHOIR_CONDUCTOR_TOKEN"] = TOKEN
            process = subprocess.Popen(
                [str(executable), "mcp-stdio", "--raw-stdio"],
                cwd=temp_path,
                env=environment,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
            )
            launched.put(process)
            release_creator.wait(TIMEOUT_SECONDS)

        creator = threading.Thread(
            target=launch_from_temporary_thread,
            name="temporary-mcp-launcher",
        )
        creator.start()
        process = launched.get(timeout=TIMEOUT_SECONDS)
        try:
            if not server.registered.wait(TIMEOUT_SECONDS):
                if not server.errors.empty():
                    raise server.errors.get()
                fail("mcp-stdio did not register with fake choird")
            initialize = send_rpc(
                process,
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            )
            if initialize.get("id") != 1 or "result" not in initialize:
                fail(f"initialize failed: {initialize}")

            before = send_rpc(
                process,
                {
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "tools/call",
                    "params": {
                        "name": "task_get",
                        "arguments": {"id": "choir-lifetime"},
                    },
                },
            )
            if "initial" not in json.dumps(before):
                fail(f"initial task_get did not observe fake state: {before}")

            release_creator.set()
            creator.join(TIMEOUT_SECONDS)
            if creator.is_alive():
                fail("temporary launcher thread did not exit")
            time.sleep(0.1)
            if process.poll() is not None:
                fail(
                    "mcp-stdio died when its temporary launcher thread exited "
                    f"(status {process.returncode})"
                )

            updated = send_rpc(
                process,
                {
                    "jsonrpc": "2.0",
                    "id": 3,
                    "method": "tools/call",
                    "params": {
                        "name": "task_update",
                        "arguments": {
                            "id": "choir-lifetime",
                            "notes": "delivered",
                        },
                    },
                },
            )
            if updated.get("id") != 3 or "error" in updated:
                fail(f"task_update failed: {updated}")

            after = send_rpc(
                process,
                {
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": {
                        "name": "task_get",
                        "arguments": {"id": "choir-lifetime"},
                    },
                },
            )
            if "delivered" not in json.dumps(after):
                fail(f"final task_get did not observe the mutation: {after}")
            if server.update_count != 1:
                fail(f"expected exactly one update, observed {server.update_count}")

            if process.stdin is None:
                fail("mcp-stdio stdin is unavailable")
            process.stdin.close()
            return_code = process.wait(timeout=TIMEOUT_SECONDS)
            if return_code != 0:
                stderr = process.stderr.read() if process.stderr is not None else ""
                fail(f"mcp-stdio exited with {return_code}: {stderr}")
            server.join()
        finally:
            release_creator.set()
            creator.join(TIMEOUT_SECONDS)
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=TIMEOUT_SECONDS)

    print("mcp-stdio survived launcher-thread exit and applied one update")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, queue.Empty, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
