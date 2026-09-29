use crate::policy::MAX_DHT_EXPORT_BYTES;

const MAGIC: &[u8; 4] = b"L2DT";
const VERSION: u8 = 1;
const HEADER_LEN: usize = MAGIC.len() + 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoutingEntry {
    pub peer_id: Vec<u8>,
    pub addresses: Vec<Vec<u8>>,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum DhtStateError {
    #[error("input too large: got {got} bytes, max {max}")]
    InputTooLarge { got: usize, max: usize },
    #[error("truncated input at offset {offset} (need {need} bytes)")]
    Truncated { offset: usize, need: usize },
    #[error("bad magic: expected {:?}, got {got:?}", MAGIC)]
    BadMagic { got: [u8; 4] },
    #[error("unsupported version: {version}")]
    UnsupportedVersion { version: u8 },
}

pub fn encode(entries: &[RoutingEntry]) -> Vec<u8> {
    let est = HEADER_LEN
        + 4
        + entries
            .iter()
            .map(|e| {
                2 + e.peer_id.len() + 2 + e.addresses.iter().map(|a| 2 + a.len()).sum::<usize>()
            })
            .sum::<usize>();
    let mut buf = Vec::with_capacity(est);

    buf.extend_from_slice(MAGIC);
    buf.push(VERSION);
    buf.extend_from_slice(&(entries.len() as u32).to_be_bytes());

    for entry in entries {
        buf.extend_from_slice(&(entry.peer_id.len() as u16).to_be_bytes());
        buf.extend_from_slice(&entry.peer_id);
        buf.extend_from_slice(&(entry.addresses.len() as u16).to_be_bytes());
        for addr in &entry.addresses {
            buf.extend_from_slice(&(addr.len() as u16).to_be_bytes());
            buf.extend_from_slice(addr);
        }
    }

    buf
}

pub fn decode(data: &[u8]) -> Result<Vec<RoutingEntry>, DhtStateError> {
    if data.len() > MAX_DHT_EXPORT_BYTES {
        return Err(DhtStateError::InputTooLarge {
            got: data.len(),
            max: MAX_DHT_EXPORT_BYTES,
        });
    }

    let mut cur = Cursor::new(data);

    let magic = cur.read_array::<4>()?;
    if &magic != MAGIC {
        return Err(DhtStateError::BadMagic { got: magic });
    }
    let version = cur.read_u8()?;
    if version != VERSION {
        return Err(DhtStateError::UnsupportedVersion { version });
    }

    let count = cur.read_u32()? as usize;
    let mut entries = Vec::with_capacity(count.min(1024));

    for _ in 0..count {
        let peer_id_len = cur.read_u16()? as usize;
        let peer_id = cur.read_vec(peer_id_len)?;

        let addr_count = cur.read_u16()? as usize;
        let mut addresses = Vec::with_capacity(addr_count.min(64));
        for _ in 0..addr_count {
            let addr_len = cur.read_u16()? as usize;
            let addr = cur.read_vec(addr_len)?;
            addresses.push(addr);
        }

        entries.push(RoutingEntry { peer_id, addresses });
    }

    Ok(entries)
}

struct Cursor<'a> {
    buf: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, offset: 0 }
    }

    fn read_array<const N: usize>(&mut self) -> Result<[u8; N], DhtStateError> {
        if self.offset + N > self.buf.len() {
            return Err(DhtStateError::Truncated {
                offset: self.offset,
                need: N,
            });
        }
        let mut out = [0u8; N];
        out.copy_from_slice(&self.buf[self.offset..self.offset + N]);
        self.offset += N;
        Ok(out)
    }

    fn read_u8(&mut self) -> Result<u8, DhtStateError> {
        Ok(self.read_array::<1>()?[0])
    }

    fn read_u16(&mut self) -> Result<u16, DhtStateError> {
        Ok(u16::from_be_bytes(self.read_array::<2>()?))
    }

    fn read_u32(&mut self) -> Result<u32, DhtStateError> {
        Ok(u32::from_be_bytes(self.read_array::<4>()?))
    }

    fn read_vec(&mut self, n: usize) -> Result<Vec<u8>, DhtStateError> {
        if self.offset + n > self.buf.len() {
            return Err(DhtStateError::Truncated {
                offset: self.offset,
                need: n,
            });
        }
        let v = self.buf[self.offset..self.offset + n].to_vec();
        self.offset += n;
        Ok(v)
    }
}
