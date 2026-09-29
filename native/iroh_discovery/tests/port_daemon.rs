use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};

const MAX_FRAME_SIZE: usize = 64 * 1024;
static TEMP_ID: AtomicU64 = AtomicU64::new(0);

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "iroh-discovery-port-{}-{}-{}",
            std::process::id(),
            TEMP_ID.fetch_add(1, Ordering::Relaxed),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock after epoch")
                .as_nanos()
        ));
        fs::create_dir(&path).expect("create temporary directory");
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Port {
    child: Child,
    stdin: ChildStdin,
    stdout: ChildStdout,
}

impl Port {
    fn spawn(data_dir: &Path) -> Self {
        Self::spawn_named(data_dir, "camera@fleet.local")
    }

    fn spawn_named(data_dir: &Path, node_name: &str) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_iroh_discovery_port"))
            .arg(data_dir)
            .arg(hex::encode([7; 32]))
            .arg(node_name)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn port daemon");
        let stdin = child.stdin.take().expect("daemon stdin");
        let stdout = child.stdout.take().expect("daemon stdout");
        Self {
            child,
            stdin,
            stdout,
        }
    }

    fn raw_frame(&mut self, payload: &[u8]) -> Value {
        self.stdin
            .write_all(&(payload.len() as u32).to_be_bytes())
            .expect("write frame length");
        self.stdin.write_all(payload).expect("write frame body");
        self.stdin.flush().expect("flush request");
        self.read()
    }

    fn request(&mut self, request: Value) -> Value {
        self.raw_frame(&serde_json::to_vec(&request).expect("encode request"))
    }

    fn read(&mut self) -> Value {
        let mut length = [0; 4];
        self.stdout
            .read_exact(&mut length)
            .expect("read response length");
        let mut payload = vec![0; u32::from_be_bytes(length) as usize];
        self.stdout
            .read_exact(&mut payload)
            .expect("read response body");
        serde_json::from_slice(&payload).expect("JSON response")
    }

    fn shutdown(mut self, id: u64) {
        let response = self.request(json!({"id": id, "command": "shutdown"}));
        assert_eq!(response["id"], id);
        assert_eq!(response["ok"], true);
        assert!(self.child.wait().expect("wait for daemon").success());
    }
}

#[test]
fn p_two_daemons_share_a_lan_c_start_without_bootstrap_q_they_auto_discover() {
    let finder_dir = TempDir::new();
    let worker_dir = TempDir::new();
    let mut finder = Port::spawn_named(&finder_dir.0, "finder@fleet.local");
    let mut worker = Port::spawn_named(&worker_dir.0, "worker@fleet.local");

    assert_eq!(
        finder.request(
            json!({"id": 1, "command": "network_start", "mdns": true, "dns": false, "relay": false})
        )["ok"],
        true
    );
    assert_eq!(
        worker.request(
            json!({"id": 1, "command": "network_start", "mdns": true, "dns": false, "relay": false})
        )["ok"],
        true
    );

    let mut found = None;
    for id in 2..22 {
        assert_eq!(
            worker.request(json!({
                "id": id,
                "command": "publish",
                "ttl_ms": 60_000,
                "partisan_ip": "192.168.10.22",
                "partisan_port": 10_222,
                "capabilities": {"gpu": true},
                "load": {"running": 0, "capacity": 1}
            }))["ok"],
            true
        );
        let response = finder.request(json!({
            "id": id,
            "command": "find",
            "predicates": [{"op": "equals", "name": "gpu", "value": true}]
        }));
        if response["ok"] == true {
            found = Some(response);
            break;
        }
        thread::sleep(Duration::from_millis(200));
    }

    let found = found.expect("finder discovers worker through mDNS");
    assert_eq!(
        found["result"]["peers"][0]["node_name"],
        "worker@fleet.local"
    );
    worker.shutdown(22);
    finder.shutdown(22);
}

#[test]
fn p_two_daemons_are_authorized_c_publish_signed_capability_q_direct_lan_discovery_returns_it() {
    let a_dir = TempDir::new();
    let b_dir = TempDir::new();
    let mut a = Port::spawn_named(&a_dir.0, "a@fleet.local");
    let mut b = Port::spawn_named(&b_dir.0, "b@fleet.local");

    let a_id = a.request(json!({"id": 1, "command": "identity"}))["result"]["endpoint_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let b_id = b.request(json!({"id": 1, "command": "identity"}))["result"]["endpoint_id"]
        .as_str()
        .unwrap()
        .to_owned();

    assert_eq!(
        a.request(json!({
            "id": 2,
            "command": "authorize",
            "endpoint_id": b_id,
            "node_name": "b@fleet.local"
        }))["ok"],
        true
    );
    assert_eq!(
        b.request(json!({
            "id": 2,
            "command": "authorize",
            "endpoint_id": a_id,
            "node_name": "a@fleet.local"
        }))["ok"],
        true
    );

    let a_network = a.request(json!({
        "id": 3,
        "command": "network_start",
        "dns": false,
        "relay": false
    }));
    assert_eq!(a_network["ok"], true);
    assert_eq!(a_network["result"]["discovery_mechanisms"], json!([]));
    let a_address = a_network["result"]["endpoint_address"].clone();
    assert_eq!(a_address["endpoint_id"], a_id);
    assert!(!a_address["direct_addresses"].as_array().unwrap().is_empty());
    let network_identity = a.request(json!({"id": 4, "command": "identity"}));
    assert_eq!(
        network_identity["result"]["endpoint_address"]["endpoint_id"],
        a_id
    );

    let b_network = b.request(json!({
        "id": 3,
        "command": "network_start",
        "dns": false,
        "relay": false,
        "bootstrap": a_address
    }));
    assert_eq!(b_network["ok"], true);
    assert_eq!(
        b_network["result"]["discovery_mechanisms"],
        json!(["bootstrap"])
    );
    assert_eq!(b_network["result"]["endpoint_address"]["endpoint_id"], b_id);

    let published = b.request(json!({
        "id": 4,
        "command": "publish",
        "ttl_ms": 60_000,
        "partisan_ip": "192.168.10.22",
        "partisan_port": 10_222,
        "capabilities": {"camera": true},
        "load": {"running": 0, "capacity": 1}
    }));
    assert_eq!(published["ok"], true);

    let found = a.request(json!({
        "id": 5,
        "command": "find",
        "predicates": [{"op": "equals", "name": "camera", "value": true}]
    }));
    assert_eq!(found["ok"], true, "{found}");
    assert_eq!(found["result"]["peers"][0]["endpoint_id"], b_id);
    assert_eq!(found["result"]["peers"][0]["node_name"], "b@fleet.local");
    assert_eq!(found["result"]["peers"][0]["partisan_ip"], "192.168.10.22");
    assert_eq!(found["result"]["peers"][0]["partisan_port"], 10_222);

    b.shutdown(5);
    a.shutdown(6);
}

#[test]
fn p_two_daemons_have_a_dist_stream_c_exchange_and_close_q_bytes_are_ordered_and_close_propagates()
{
    let a_dir = TempDir::new();
    let b_dir = TempDir::new();
    let mut a = Port::spawn_named(&a_dir.0, "a@fleet.local");
    let mut b = Port::spawn_named(&b_dir.0, "b@fleet.local");
    let a_id = a.request(json!({"id": 1, "command": "identity"}))["result"]["endpoint_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let b_id = b.request(json!({"id": 1, "command": "identity"}))["result"]["endpoint_id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(
        a.request(json!({"id": 2, "command": "authorize", "endpoint_id": b_id, "node_name": "b@fleet.local"}))["ok"],
        true
    );
    assert_eq!(
        b.request(json!({"id": 2, "command": "authorize", "endpoint_id": a_id, "node_name": "a@fleet.local"}))["ok"],
        true
    );
    let a_network = a.request(json!({
        "id": 3,
        "command": "network_start",
        "dns": false,
        "relay": false
    }));
    assert_eq!(a_network["ok"], true);
    assert_eq!(
        b.request(json!({
            "id": 3,
            "command": "network_start",
            "dns": false,
            "relay": false,
            "bootstrap": a_network["result"]["endpoint_address"].clone()
        }))["ok"],
        true
    );
    let publish = |id, port| {
        json!({
            "id": id,
            "command": "publish",
            "ttl_ms": 60_000,
            "partisan_ip": "127.0.0.1",
            "partisan_port": port,
            "capabilities": {},
            "load": {"running": 0, "capacity": 1}
        })
    };
    let a_envelope = a.request(publish(4, 9001))["result"]["envelope"]
        .as_str()
        .unwrap()
        .to_owned();
    let b_envelope = b.request(publish(4, 9002))["result"]["envelope"]
        .as_str()
        .unwrap()
        .to_owned();
    for response in [
        a.request(json!({"id": 5, "command": "ingest", "envelope": b_envelope, "endpoint_id": b_id, "node_name": "b@fleet.local"})),
        b.request(json!({"id": 5, "command": "ingest", "envelope": a_envelope, "endpoint_id": a_id, "node_name": "a@fleet.local"})),
    ] {
        assert!(
            response["ok"] == true || response["error"] == "stale_sequence",
            "{response}"
        );
    }
    assert_eq!(
        a.request(json!({"id": 6, "command": "dist_listen", "node_name": "a@fleet.local"}))["ok"],
        true
    );
    let connected = b.request(json!({
        "id": 6,
        "command": "dist_connect",
        "from_node": "b@fleet.local",
        "target_node": "a@fleet.local"
    }));
    assert_eq!(connected["ok"], true, "{connected}");
    let b_stream = connected["result"]["stream_id"].as_u64().unwrap();
    assert_eq!(b.read()["event"], "dist_connected");
    let incoming = a.read();
    assert_eq!(incoming["event"], "dist_incoming");
    let a_stream = incoming["stream_id"].as_u64().unwrap();

    assert_eq!(
        b.request(
            json!({"id": 7, "command": "dist_send", "stream_id": b_stream, "bytes": "6f6e6574776f"})
        )["ok"],
        true
    );
    assert_eq!(b.read()["event"], "dist_credit");
    let data = a.read();
    assert_eq!(data["event"], "dist_data");
    assert_eq!(data["bytes"], "6f6e6574776f");
    assert_eq!(
        a.request(
            json!({"id": 7, "command": "dist_send", "stream_id": a_stream, "bytes": "7468726565"})
        )["ok"],
        true
    );
    assert_eq!(a.read()["event"], "dist_credit");
    let reverse = b.read();
    assert_eq!(reverse["event"], "dist_data");
    assert_eq!(reverse["bytes"], "7468726565");

    assert_eq!(
        b.request(json!({"id": 8, "command": "dist_close", "stream_id": b_stream}))["ok"],
        true
    );
    assert_eq!(b.read()["event"], "dist_closed");
    assert_eq!(a.read()["event"], "dist_closed");
    b.shutdown(9);
    a.shutdown(9);
}

#[test]
fn p_daemon_identity_is_initialized_c_publish_then_find_q_record_round_trips() {
    let dir = TempDir::new();
    let mut port = Port::spawn(&dir.0);

    let identity = port.request(json!({"id": 1, "command": "identity"}));
    assert_eq!(identity["id"], 1);
    assert_eq!(identity["ok"], true);
    assert_eq!(
        identity["result"]["endpoint_id"].as_str().unwrap().len(),
        64
    );

    for (id, partisan_ip, partisan_port) in [(90, "not-an-ip", 9000), (91, "127.0.0.1", 0)] {
        let rejected = port.request(json!({
            "id": id,
            "command": "publish",
            "ttl_ms": 60_000,
            "partisan_ip": partisan_ip,
            "partisan_port": partisan_port,
            "capabilities": {},
            "load": {"running": 0, "capacity": 1}
        }));
        assert_eq!(rejected["ok"], false);
        assert_eq!(rejected["error"], "invalid_record");
    }

    let published = port.request(json!({
        "id": 2,
        "command": "publish",
        "ttl_ms": 60_000,
        "partisan_ip": "192.168.1.25",
        "partisan_port": 9000,
        "capabilities": {"camera": true, "height": 1080},
        "load": {"running": 0, "capacity": 2}
    }));
    assert_eq!(published["id"], 2);
    assert_eq!(published["ok"], true);
    assert_eq!(published["result"]["sequence"], 1);
    assert!(published["result"]["envelope"].as_str().unwrap().len() > 64);

    let found = port.request(json!({
        "id": 3,
        "command": "find",
        "predicates": [
            {"op": "equals", "name": "camera", "value": true},
            {"op": "at_least", "name": "height", "value": 720}
        ]
    }));
    assert_eq!(found["id"], 3);
    assert_eq!(found["ok"], true);
    assert_eq!(
        found["result"]["peers"][0]["node_name"],
        "camera@fleet.local"
    );
    assert_eq!(found["result"]["peers"][0]["partisan_ip"], "192.168.1.25");
    assert_eq!(found["result"]["peers"][0]["partisan_port"], 9000);

    port.shutdown(4);
}

#[test]
fn p_daemon_receives_invalid_frames_c_process_then_query_q_errors_return_and_daemon_survives() {
    let dir = TempDir::new();
    let mut port = Port::spawn(&dir.0);

    let malformed = port.raw_frame(b"not json");
    assert_eq!(malformed["ok"], false);

    let oversized = port.raw_frame(&vec![b'x'; MAX_FRAME_SIZE + 1]);
    assert_eq!(oversized["ok"], false);
    assert_eq!(oversized["error"], "frame_too_large");

    let identity = port.request(json!({"id": 9, "command": "identity"}));
    assert_eq!(identity["id"], 9);
    assert_eq!(identity["ok"], true);
    port.shutdown(10);
}

#[test]
fn p_identity_and_sequence_are_persisted_c_restart_daemon_q_both_continue_monotonically() {
    let dir = TempDir::new();
    let mut first = Port::spawn(&dir.0);
    let identity = first.request(json!({"id": 1, "command": "identity"}));
    let endpoint_id = identity["result"]["endpoint_id"].clone();
    let publish = |id| {
        json!({
            "id": id,
            "command": "publish",
            "ttl_ms": 5_000,
            "partisan_ip": "127.0.0.1",
            "partisan_port": 9000,
            "capabilities": {"camera": true},
            "load": {"running": 0, "capacity": 1}
        })
    };
    assert_eq!(first.request(publish(2))["result"]["sequence"], 1);
    first.shutdown(3);

    let mut second = Port::spawn(&dir.0);
    assert_eq!(
        second.request(json!({"id": 4, "command": "identity"}))["result"]["endpoint_id"],
        endpoint_id
    );
    assert_eq!(second.request(publish(5))["result"]["sequence"], 2);
    second.shutdown(6);
}
