pub mod gossipsub_default_score {
    pub const IP_COLOCATION_FACTOR_WEIGHT: f64 = -53.0;
    pub const IP_COLOCATION_FACTOR_THRESHOLD: f64 = 3.0;
    pub const BEHAVIOUR_PENALTY_WEIGHT: f64 = -15.92;
    pub const BEHAVIOUR_PENALTY_DECAY: f64 = 0.986;
}

pub mod gossipsub_default_thresholds {
    pub const GOSSIP: f64 = -4000.0;
    pub const PUBLISH: f64 = -8000.0;
    pub const GRAYLIST: f64 = -16000.0;
    pub const ACCEPT_PX: f64 = 100.0;
    pub const OPPORTUNISTIC_GRAFT: f64 = 5.0;
}

pub const MAX_PENDING_RESPONSES: usize = 1024;
pub const MAX_DHT_EXPORT_BYTES: usize = 4 * 1024 * 1024;
