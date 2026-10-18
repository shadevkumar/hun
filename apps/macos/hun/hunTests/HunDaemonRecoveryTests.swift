import Darwin
import Foundation
import Testing
@testable import hun

struct HunDaemonRecoveryTests {
    @Test func aSlowPingDoesNotTerminateALiveDaemon() async throws {
        try await verifyExistingDaemonSurvivesProbe(firstResponse: "slow")
    }

    @Test func aClosedConnectionDoesNotTerminateALiveDaemon() async throws {
        try await verifyExistingDaemonSurvivesProbe(firstResponse: "close")
    }

    @Test func aCompatibleDaemonIsReused() async throws {
        try await verifyExistingDaemonSurvivesProbe(firstResponse: "fast")
    }
}

private func verifyExistingDaemonSurvivesProbe(firstResponse: String) async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("hr-" + UUID().uuidString.prefix(8), isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }

    // A separate process holds a real Unix socket and PID file. It must survive
    // a failed health probe, just as a daemon with running services must.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", "-c", """
import json, os, socket, sys, threading, time
home, mode = sys.argv[1:]
server = socket.socket(socket.AF_UNIX)
server.bind(home + '/daemon.sock')
server.listen()
with open(home + '/daemon.pid', 'w') as f:
    f.write(str(os.getpid()))
print('ready', flush=True)
def reply(conn, index):
    try:
        conn.recv(4096)
        if index == 0 and mode == 'close':
            return
        if index == 0 and mode == 'slow':
            time.sleep(0.8)
        payload = {'ok': True, 'data': {
            'status': 'pong', 'protocol': 15, 'version': 'test',
            'commit': 'test', 'pid': os.getpid()
        }}
        conn.sendall(json.dumps(payload).encode() + bytes([10]))
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        conn.close()
index = 0
while True:
    conn, _ = server.accept()
    threading.Thread(target=reply, args=(conn, index), daemon=True).start()
    index += 1
""", home.path, firstResponse]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    defer {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
    let ready = output.fileHandleForReading.availableData
    try #require(String(data: ready, encoding: .utf8)?.contains("ready") == true)
    let supervisor = HunDaemonSupervisor(
        client: HunDaemonClient(socketPath: home.appendingPathComponent("daemon.sock").path),
        expectedRuntimeBuild: HunRuntimeBuild(version: "test", commit: "test"),
        homeURL: home
    )

    var probeFailed = false
    do {
        try await supervisor.ensureDaemon()
    } catch {
        probeFailed = true
    }
    #expect(probeFailed == (firstResponse != "fast"))
    try #require(process.isRunning)

    try await supervisor.ensureDaemon()
    #expect(process.isRunning)
}
