use std::{
    collections::HashMap,
    io,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use iroh::{
    Endpoint, EndpointId,
    endpoint::{Connection, RecvStream, SendStream},
    protocol::{AcceptError, ProtocolHandler},
};
use tokio::sync::mpsc;

use crate::valid_node_name;

pub const ALPN: &[u8] = b"elixir-rpc/iroh-dist/1";
pub const CREDIT_WINDOW: usize = 256 * 1024;
const DATA_CHUNK: usize = 16 * 1024;
const COMMAND_QUEUE: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Incoming {
        stream_id: u64,
        from_node: String,
        target_node: String,
    },
    Connected {
        stream_id: u64,
        target_node: String,
    },
    Data {
        stream_id: u64,
        bytes: Vec<u8>,
    },
    Credit {
        stream_id: u64,
        bytes: usize,
    },
    Closed {
        stream_id: u64,
        reason: String,
    },
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum Error {
    #[error("network_not_started")]
    NetworkNotStarted,
    #[error("not_listening")]
    NotListening,
    #[error("unknown_node")]
    UnknownNode,
    #[error("unknown_stream")]
    UnknownStream,
    #[error("credit_exhausted")]
    CreditExhausted,
    #[error("queue_full")]
    QueueFull,
    #[error("invalid_credit")]
    InvalidCredit,
    #[error("connection_failed")]
    ConnectionFailed,
}

#[derive(Debug, Clone)]
pub struct Dist {
    endpoint: Endpoint,
    shared: Arc<Mutex<Shared>>,
    events: mpsc::Sender<Event>,
}

#[derive(Debug)]
struct Shared {
    next_id: u64,
    listen_node: Option<String>,
    bindings: HashMap<String, Binding>,
    streams: HashMap<u64, StreamState>,
}

#[derive(Debug)]
struct Binding {
    endpoint: EndpointId,
    expires: Instant,
}

#[derive(Debug)]
struct StreamState {
    commands: mpsc::Sender<StreamCommand>,
    send_credit: usize,
    receive_credit: usize,
}

#[derive(Debug)]
enum StreamCommand {
    Send(Vec<u8>),
    Credit(usize),
    Close,
}

#[derive(Debug, Clone)]
pub struct Handler {
    shared: Arc<Mutex<Shared>>,
    events: mpsc::Sender<Event>,
}

impl Dist {
    pub fn new(endpoint: Endpoint, events: mpsc::Sender<Event>) -> (Self, Handler) {
        let shared = Arc::new(Mutex::new(Shared {
            next_id: 1,
            listen_node: None,
            bindings: HashMap::new(),
            streams: HashMap::new(),
        }));
        (
            Self {
                endpoint,
                shared: shared.clone(),
                events: events.clone(),
            },
            Handler { shared, events },
        )
    }

    pub fn listen(&self, node_name: &str) -> Result<(), Error> {
        if !valid_node_name(node_name) {
            return Err(Error::NotListening);
        }
        self.shared.lock().expect("dist state").listen_node = Some(node_name.to_owned());
        Ok(())
    }

    pub fn replace_bindings(&self, bindings: Vec<(EndpointId, String, u64)>) {
        let now = Instant::now();
        self.shared.lock().expect("dist state").bindings = bindings
            .into_iter()
            .map(|(endpoint, node, ttl_ms)| {
                (
                    node,
                    Binding {
                        endpoint,
                        expires: now + Duration::from_millis(ttl_ms),
                    },
                )
            })
            .collect();
    }

    pub async fn connect(&self, from_node: String, target_node: String) -> Result<u64, Error> {
        if !valid_node_name(&from_node) || !valid_node_name(&target_node) {
            return Err(Error::UnknownNode);
        }
        let endpoint = {
            let shared = self.shared.lock().expect("dist state");
            shared
                .bindings
                .get(&target_node)
                .filter(|binding| binding.expires > Instant::now())
                .map(|binding| binding.endpoint)
                .ok_or(Error::UnknownNode)?
        };
        let connection = self
            .endpoint
            .connect(endpoint, ALPN)
            .await
            .map_err(|_| Error::ConnectionFailed)?;
        let (mut send, recv) = connection
            .open_bi()
            .await
            .map_err(|_| Error::ConnectionFailed)?;
        send.write_all(&encode_header(&from_node, &target_node))
            .await
            .map_err(|_| Error::ConnectionFailed)?;
        install_stream(
            &self.shared,
            &self.events,
            connection,
            send,
            recv,
            Event::Connected {
                stream_id: 0,
                target_node,
            },
        )
        .await
    }

    pub fn send(&self, stream_id: u64, bytes: Vec<u8>) -> Result<(), Error> {
        if bytes.is_empty() || bytes.len() > CREDIT_WINDOW {
            return Err(Error::InvalidCredit);
        }
        let mut shared = self.shared.lock().expect("dist state");
        let stream = shared
            .streams
            .get_mut(&stream_id)
            .ok_or(Error::UnknownStream)?;
        if bytes.len() > stream.send_credit {
            return Err(Error::CreditExhausted);
        }
        let length = bytes.len();
        stream
            .commands
            .try_send(StreamCommand::Send(bytes))
            .map_err(|_| Error::QueueFull)?;
        stream.send_credit -= length;
        Ok(())
    }

    pub fn credit(&self, stream_id: u64, bytes: usize) -> Result<(), Error> {
        if bytes == 0 || bytes > CREDIT_WINDOW {
            return Err(Error::InvalidCredit);
        }
        let mut shared = self.shared.lock().expect("dist state");
        let stream = shared
            .streams
            .get_mut(&stream_id)
            .ok_or(Error::UnknownStream)?;
        if stream
            .receive_credit
            .checked_add(bytes)
            .is_none_or(|credit| credit > CREDIT_WINDOW)
        {
            return Err(Error::InvalidCredit);
        }
        stream
            .commands
            .try_send(StreamCommand::Credit(bytes))
            .map_err(|_| Error::QueueFull)?;
        stream.receive_credit += bytes;
        Ok(())
    }

    pub fn close(&self, stream_id: u64) -> Result<(), Error> {
        let shared = self.shared.lock().expect("dist state");
        shared
            .streams
            .get(&stream_id)
            .ok_or(Error::UnknownStream)?
            .commands
            .try_send(StreamCommand::Close)
            .map_err(|_| Error::QueueFull)
    }
}

impl ProtocolHandler for Handler {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let remote = connection.remote_id();
        let (send, mut recv) = connection.accept_bi().await?;
        let header = read_header(&mut recv).await?;
        let allowed = {
            let shared = self.shared.lock().expect("dist state");
            shared.listen_node.as_deref() == Some(&header.target_node)
                && shared
                    .bindings
                    .get(&header.from_node)
                    .is_some_and(|binding| {
                        binding.endpoint == remote && binding.expires > Instant::now()
                    })
        };
        if !allowed {
            connection.close(1u32.into(), b"unauthorized");
            return Ok(());
        }
        install_stream(
            &self.shared,
            &self.events,
            connection,
            send,
            recv,
            Event::Incoming {
                stream_id: 0,
                from_node: header.from_node,
                target_node: header.target_node,
            },
        )
        .await
        .map_err(|_| {
            AcceptError::from_err(io::Error::new(io::ErrorKind::BrokenPipe, "port closed"))
        })?;
        Ok(())
    }
}

async fn install_stream(
    shared: &Arc<Mutex<Shared>>,
    events: &mpsc::Sender<Event>,
    connection: Connection,
    send: SendStream,
    recv: RecvStream,
    mut initial_event: Event,
) -> Result<u64, Error> {
    let (commands, receiver) = mpsc::channel(COMMAND_QUEUE);
    let stream_id = {
        let mut shared = shared.lock().expect("dist state");
        let stream_id = shared.next_id;
        shared.next_id = shared.next_id.wrapping_add(1).max(1);
        shared.streams.insert(
            stream_id,
            StreamState {
                commands,
                send_credit: CREDIT_WINDOW,
                receive_credit: CREDIT_WINDOW,
            },
        );
        stream_id
    };
    match &mut initial_event {
        Event::Incoming { stream_id: id, .. } | Event::Connected { stream_id: id, .. } => {
            *id = stream_id;
        }
        _ => unreachable!("initial stream event"),
    }
    if events.send(initial_event).await.is_err() {
        shared
            .lock()
            .expect("dist state")
            .streams
            .remove(&stream_id);
        return Err(Error::ConnectionFailed);
    }
    tokio::spawn(run_stream(
        stream_id,
        shared.clone(),
        events.clone(),
        connection,
        send,
        recv,
        receiver,
    ));
    Ok(stream_id)
}

async fn run_stream(
    stream_id: u64,
    shared: Arc<Mutex<Shared>>,
    events: mpsc::Sender<Event>,
    connection: Connection,
    mut send: SendStream,
    mut recv: RecvStream,
    mut commands: mpsc::Receiver<StreamCommand>,
) {
    let mut receive_credit = CREDIT_WINDOW;
    let mut buffer = vec![0; DATA_CHUNK];
    let reason = loop {
        tokio::select! {
            command = commands.recv() => match command {
                Some(StreamCommand::Send(bytes)) => {
                    if send.write_all(&bytes).await.is_err() {
                        break "write_failed";
                    }
                    if let Some(stream) = shared.lock().expect("dist state").streams.get_mut(&stream_id) {
                        stream.send_credit = stream.send_credit.saturating_add(bytes.len()).min(CREDIT_WINDOW);
                    }
                    if events.send(Event::Credit { stream_id, bytes: bytes.len() }).await.is_err() {
                        break "port_closed";
                    }
                }
                Some(StreamCommand::Credit(bytes)) => {
                    if receive_credit.checked_add(bytes).is_none_or(|credit| credit > CREDIT_WINDOW) {
                        break "invalid_credit";
                    }
                    receive_credit += bytes;
                }
                Some(StreamCommand::Close) => {
                    let _ = send.finish();
                    connection.close(0u32.into(), b"closed");
                    break "local_close";
                }
                None => break "port_closed",
            },
            result = recv.read(&mut buffer[..receive_credit.min(DATA_CHUNK)]), if receive_credit > 0 => match result {
                Ok(Some(0)) | Ok(None) => break "remote_close",
                Ok(Some(count)) => {
                    receive_credit -= count;
                    if let Some(stream) = shared.lock().expect("dist state").streams.get_mut(&stream_id) {
                        stream.receive_credit -= count;
                    }
                    if events.send(Event::Data { stream_id, bytes: buffer[..count].to_vec() }).await.is_err() {
                        break "port_closed";
                    }
                }
                Err(_) => break "read_failed",
            }
        }
    };
    shared
        .lock()
        .expect("dist state")
        .streams
        .remove(&stream_id);
    let _ = events
        .send(Event::Closed {
            stream_id,
            reason: reason.to_owned(),
        })
        .await;
}

#[derive(Debug, PartialEq, Eq)]
struct Header {
    from_node: String,
    target_node: String,
}

async fn read_header(recv: &mut RecvStream) -> io::Result<Header> {
    let mut magic = [0; 8];
    recv.read_exact(&mut magic)
        .await
        .map_err(|error| io::Error::other(error.to_string()))?;
    if &magic != b"ERLDIST1" {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "bad magic"));
    }
    let from_node = read_node(recv).await?;
    let target_node = read_node(recv).await?;
    Ok(Header {
        from_node,
        target_node,
    })
}

async fn read_node(recv: &mut RecvStream) -> io::Result<String> {
    let mut encoded_length = [0; 2];
    recv.read_exact(&mut encoded_length)
        .await
        .map_err(|error| io::Error::other(error.to_string()))?;
    let length = u16::from_be_bytes(encoded_length) as usize;
    if !(1..=255).contains(&length) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bad node length",
        ));
    }
    let mut bytes = vec![0; length];
    recv.read_exact(&mut bytes)
        .await
        .map_err(|error| io::Error::other(error.to_string()))?;
    let node = String::from_utf8(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "bad node encoding"))?;
    if !valid_node_name(&node) {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "bad node name"));
    }
    Ok(node)
}

fn encode_header(from_node: &str, target_node: &str) -> Vec<u8> {
    let mut header = Vec::with_capacity(12 + from_node.len() + target_node.len());
    header.extend_from_slice(b"ERLDIST1");
    header.extend_from_slice(&(from_node.len() as u16).to_be_bytes());
    header.extend_from_slice(from_node.as_bytes());
    header.extend_from_slice(&(target_node.len() as u16).to_be_bytes());
    header.extend_from_slice(target_node.as_bytes());
    header
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn p_valid_node_names_c_encode_header_q_wire_bytes_are_exact() {
        let header = encode_header("a@fleet.local", "b@fleet.local");
        assert_eq!(&header[..8], b"ERLDIST1");
        assert_eq!(u16::from_be_bytes([header[8], header[9]]), 13);
        assert_eq!(&header[10..23], b"a@fleet.local");
        assert_eq!(u16::from_be_bytes([header[23], header[24]]), 13);
        assert_eq!(&header[25..], b"b@fleet.local");
    }
}
