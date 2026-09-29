use futures_lite::StreamExt;
use iroh::{Endpoint, EndpointAddr, EndpointId, protocol::Router};
use iroh_gossip::{
    ALPN, Gossip, TopicId,
    api::{ApiError, Event, GossipReceiver, GossipSender},
};
use thiserror::Error;
use tokio::sync::mpsc;

use crate::dist::{Dist, Event as DistEvent};

#[derive(Debug, Error)]
pub enum Error {
    #[error(transparent)]
    Gossip(#[from] ApiError),
    #[error("gossip subscription lagged")]
    Lagged,
    #[error("router shutdown failed: {0}")]
    Shutdown(String),
}

pub struct Transport {
    gossip: Gossip,
    router: Router,
    dist: Dist,
}

impl Transport {
    pub fn spawn(endpoint: Endpoint) -> Self {
        let (events, receiver) = mpsc::channel(1);
        drop(receiver);
        Self::spawn_with_dist(endpoint, events)
    }

    pub fn spawn_with_dist(endpoint: Endpoint, events: mpsc::Sender<DistEvent>) -> Self {
        let gossip = Gossip::builder().spawn(endpoint.clone());
        let (dist, dist_handler) = Dist::new(endpoint.clone(), events);
        let router = Router::builder(endpoint)
            .accept(ALPN, gossip.clone())
            .accept(crate::dist::ALPN, dist_handler)
            .spawn();
        Self {
            gossip,
            router,
            dist,
        }
    }

    pub fn dist(&self) -> &Dist {
        &self.dist
    }

    pub fn endpoint_addr(&self) -> EndpointAddr {
        self.router.endpoint().addr()
    }

    pub async fn subscribe(
        &self,
        topic: TopicId,
        bootstrap: Vec<EndpointId>,
    ) -> Result<Subscription, Error> {
        let (sender, receiver) = self.gossip.subscribe(topic, bootstrap).await?.split();
        Ok(Subscription { sender, receiver })
    }

    pub async fn shutdown(self) -> Result<(), Error> {
        self.router
            .shutdown()
            .await
            .map_err(|error| Error::Shutdown(error.to_string()))
    }
}

pub struct Subscription {
    sender: GossipSender,
    receiver: GossipReceiver,
}

impl Subscription {
    pub async fn join_peers(&self, peers: Vec<EndpointId>) -> Result<(), Error> {
        self.sender.join_peers(peers).await?;
        Ok(())
    }

    pub async fn joined(&mut self) -> Result<(), Error> {
        self.receiver.joined().await?;
        Ok(())
    }

    pub async fn broadcast(&self, envelope: Vec<u8>) -> Result<(), Error> {
        self.sender.broadcast(envelope.into()).await?;
        Ok(())
    }

    pub async fn receive(&mut self) -> Result<Option<Vec<u8>>, Error> {
        while let Some(event) = self.receiver.next().await {
            match event? {
                Event::Received(message) => return Ok(Some(message.content.to_vec())),
                Event::Lagged => return Err(Error::Lagged),
                Event::NeighborUp(_) | Event::NeighborDown(_) => {}
            }
        }
        Ok(None)
    }
}
