use crate::atoms;
use rustler::{Atom, Encoder, Env, Term};
use thiserror::Error;

pub const MAX_KEYPAIR_BYTES: usize = 4096;

#[derive(Debug, Error)]
pub enum NifError {
    #[error("invalid multiaddr: {0}")]
    InvalidMultiaddr(String),

    #[error("invalid peer id: {0}")]
    InvalidPeerId(String),

    #[error("invalid keypair: {0}")]
    InvalidKeypair(String),

    #[error("input too large: got {got} bytes, max {max}")]
    InputTooLarge { got: usize, max: usize },

    #[error("node stopped: swarm event loop has exited")]
    NodeStopped,

    #[error("channel full: swarm is overloaded")]
    ChannelFull,

    #[error("query timeout")]
    QueryTimeout,

    #[error("dht not enabled")]
    DhtNotEnabled,

    #[error("nif panic: {0}")]
    NifPanic(String),

    #[error("internal: {0}")]
    Internal(String),
}

impl NifError {
    fn atom(&self) -> Atom {
        match self {
            NifError::InvalidMultiaddr(_) => atoms::invalid_multiaddr(),
            NifError::InvalidPeerId(_) => atoms::invalid_peer_id(),
            NifError::InvalidKeypair(_) => atoms::invalid_keypair(),
            NifError::InputTooLarge { .. } => atoms::input_too_large(),
            NifError::NodeStopped => atoms::node_stopped(),
            NifError::ChannelFull => atoms::channel_full(),
            NifError::QueryTimeout => atoms::query_timeout(),
            NifError::DhtNotEnabled => atoms::dht_not_enabled(),
            NifError::NifPanic(_) => atoms::nif_panic(),

            NifError::Internal(_) => atoms::internal_error(),
        }
    }
}

impl Encoder for NifError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        (self.atom(), self.to_string()).encode(env)
    }
}

impl From<NifError> for rustler::Error {
    fn from(e: NifError) -> Self {
        rustler::Error::Term(Box::new(e))
    }
}

impl From<libp2p::multiaddr::Error> for NifError {
    fn from(e: libp2p::multiaddr::Error) -> Self {
        NifError::InvalidMultiaddr(e.to_string())
    }
}

impl From<libp2p::identity::ParseError> for NifError {
    fn from(e: libp2p::identity::ParseError) -> Self {
        NifError::InvalidPeerId(e.to_string())
    }
}

impl From<libp2p::identity::DecodingError> for NifError {
    fn from(e: libp2p::identity::DecodingError) -> Self {
        NifError::InvalidKeypair(e.to_string())
    }
}
