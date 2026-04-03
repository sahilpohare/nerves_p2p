use std::collections::VecDeque;
use std::time::Instant;

use anyhow::Result;
use crossterm::event::{Event, EventStream, KeyCode, KeyEvent, KeyModifiers};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use crossterm::ExecutableCommand;
use futures::StreamExt;
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{
    Block, Borders, Clear, List, ListItem, ListState, Paragraph, Tabs, Wrap,
};
use ratatui::Terminal;
use tokio::sync::mpsc;

// ── Public channel types ──────────────────────────────────────────────────────

/// A peer found in a DHT query result.
#[derive(Debug, Clone)]
pub struct FoundPeer {
    pub peer_id: String,
    pub addrs: Vec<String>,
}

/// Updates flowing from the swarm task into the TUI.
#[derive(Debug)]
pub enum StateUpdate {
    PeerId(String),
    ListenAddr(String),
    PeerConnected { peer_id: String, multiaddr: String },
    PeerDisconnected(String),
    PeerDiscovered { peer_id: String, multiaddr: String, protocol: String },
    NatStatus(String),
    Log { level: LogLevel, message: String },
    QueryResult { key: String, peers: Vec<FoundPeer> },
    /// Fired each time we successfully put a record so the TUI can track it.
    Advertised(String),
}

/// Commands flowing from the TUI into the swarm task.
#[derive(Debug)]
pub enum TuiCommand {
    Dial(String),
    Advertise(String),
    Query(String),
    Quit,
}

// ── Internal state ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
#[allow(dead_code)]
pub enum LogLevel {
    Info,
    Warn,
    Error,
    Debug,
}

#[derive(Debug)]
struct LogEntry {
    time: String,
    level: LogLevel,
    message: String,
}

#[derive(Debug)]
struct PeerEntry {
    peer_id: String,
    multiaddr: String,
    extra: String, // protocol for discovered, duration for connected
    connected: bool,
    seen_at: Instant,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Tab {
    Overview,
    Peers,
    Dht,
    Log,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum InputMode {
    Normal,
    Dial,
    Advertise,
    Query,
}

#[derive(Debug, Clone)]
struct DhtEntry {
    key: String,
    peers: Vec<FoundPeer>,
    queried_at: Instant,
}

struct TuiState {
    local_peer_id: String,
    listen_addrs: Vec<String>,
    peers: Vec<PeerEntry>,
    nat_status: String,
    log: VecDeque<LogEntry>,
    dht_results: Vec<DhtEntry>,
    /// Keys we have advertised in this session.
    my_advertisements: Vec<String>,

    tab: Tab,
    peers_list: ListState,
    dht_list: ListState,
    log_scroll: u16,

    input_mode: InputMode,
    input_value: String,
}

const LOG_CAP: usize = 500;

impl TuiState {
    fn new() -> Self {
        Self {
            local_peer_id: String::from("(waiting...)"),
            listen_addrs: vec![],
            peers: vec![],
            nat_status: String::from("unknown"),
            log: VecDeque::with_capacity(LOG_CAP),
            dht_results: vec![],
            my_advertisements: vec![],

            tab: Tab::Overview,
            peers_list: ListState::default(),
            dht_list: ListState::default(),
            log_scroll: 0,

            input_mode: InputMode::Normal,
            input_value: String::new(),
        }
    }

    fn push_log(&mut self, level: LogLevel, message: String) {
        if self.log.len() >= LOG_CAP {
            self.log.pop_front();
        }
        let now = chrono::Local::now().format("%H:%M:%S").to_string();
        self.log.push_back(LogEntry { time: now, level, message });
        // Auto-scroll to bottom
        self.log_scroll = self.log.len().saturating_sub(1) as u16;
    }

    fn apply(&mut self, update: StateUpdate) {
        match update {
            StateUpdate::PeerId(id) => {
                self.push_log(LogLevel::Info, format!("PeerID: {}", id));
                self.local_peer_id = id;
            }
            StateUpdate::ListenAddr(addr) => {
                self.push_log(LogLevel::Info, format!("Listening on: {}", addr));
                if !self.listen_addrs.contains(&addr) {
                    self.listen_addrs.push(addr);
                }
            }
            StateUpdate::PeerConnected { peer_id, multiaddr } => {
                self.push_log(LogLevel::Info, format!("Connected: {} at {}", peer_id, multiaddr));
                // Remove any discovered entry for this peer, add connected entry
                self.peers.retain(|p| p.peer_id != peer_id);
                self.peers.push(PeerEntry {
                    peer_id,
                    multiaddr,
                    extra: String::new(),
                    connected: true,
                    seen_at: Instant::now(),
                });
            }
            StateUpdate::PeerDisconnected(peer_id) => {
                self.push_log(LogLevel::Info, format!("Disconnected: {}", peer_id));
                self.peers.retain(|p| !(p.peer_id == peer_id && p.connected));
            }
            StateUpdate::PeerDiscovered { peer_id, multiaddr, protocol } => {
                // Don't add if already connected
                if !self.peers.iter().any(|p| p.peer_id == peer_id && p.connected) {
                    self.push_log(
                        LogLevel::Info,
                        format!("Discovered ({}) {} at {}", protocol, peer_id, multiaddr),
                    );
                    // Update existing discovered entry or add new
                    if let Some(entry) = self.peers.iter_mut().find(|p| p.peer_id == peer_id && !p.connected) {
                        entry.multiaddr = multiaddr;
                        entry.extra = protocol;
                        entry.seen_at = Instant::now();
                    } else {
                        self.peers.push(PeerEntry {
                            peer_id,
                            multiaddr,
                            extra: protocol,
                            connected: false,
                            seen_at: Instant::now(),
                        });
                    }
                }
            }
            StateUpdate::NatStatus(status) => {
                self.push_log(LogLevel::Info, format!("NAT status: {}", status));
                self.nat_status = status;
            }
            StateUpdate::Log { level, message } => {
                self.push_log(level, message);
            }
            StateUpdate::QueryResult { key, peers } => {
                self.push_log(
                    LogLevel::Info,
                    format!("DHT query '{}': {} peer(s)", key, peers.len()),
                );
                if let Some(entry) = self.dht_results.iter_mut().find(|e| e.key == key) {
                    entry.peers = peers;
                    entry.queried_at = Instant::now();
                } else {
                    self.dht_results.push(DhtEntry {
                        key,
                        peers,
                        queried_at: Instant::now(),
                    });
                }
            }
            StateUpdate::Advertised(key) => {
                self.push_log(LogLevel::Info, format!("Advertising: {}", key));
                if !self.my_advertisements.contains(&key) {
                    self.my_advertisements.push(key);
                }
            }
        }
    }
}

// ── Rendering ─────────────────────────────────────────────────────────────────

fn render(f: &mut ratatui::Frame, state: &TuiState) {
    let area = f.area();

    // Top bar: tabs + keybinds
    let top_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(0)])
        .split(area);

    let tab_titles: Vec<Line> = ["Overview", "Peers", "DHT", "Log"]
        .iter()
        .map(|t| Line::from(*t))
        .collect();
    let tab_index = match state.tab {
        Tab::Overview => 0,
        Tab::Peers => 1,
        Tab::Dht => 2,
        Tab::Log => 3,
    };
    let tabs = Tabs::new(tab_titles)
        .select(tab_index)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .title(" P2P Bridge  ─  Tab/←/→: switch  d: dial  a: advertise  /: query  q: quit "),
        )
        .highlight_style(Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD));
    f.render_widget(tabs, top_chunks[0]);

    let body = top_chunks[1];

    match state.tab {
        Tab::Overview => render_overview(f, state, body),
        Tab::Peers => render_peers(f, state, body),
        Tab::Dht => render_dht(f, state, body),
        Tab::Log => render_log(f, state, body),
    }

    match state.input_mode {
        InputMode::Dial => render_input_popup(f, " Dial Peer ", "Multiaddr", &state.input_value, area),
        InputMode::Advertise => render_input_popup(f, " Advertise Key ", "Key (e.g. camera)", &state.input_value, area),
        InputMode::Query => render_input_popup(f, " Query DHT ", "Key to search", &state.input_value, area),
        InputMode::Normal => {}
    }
}

fn render_overview(f: &mut ratatui::Frame, state: &TuiState, area: Rect) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
        .split(area);

    // Left: identity + NAT
    let left_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(7), Constraint::Min(0)])
        .split(cols[0]);

    let short_id = if state.local_peer_id.len() > 30 {
        format!("{}…", &state.local_peer_id[..30])
    } else {
        state.local_peer_id.clone()
    };
    let mut id_lines = vec![
        Line::from(vec![
            Span::styled("Peer ID  ", Style::default().fg(Color::DarkGray)),
            Span::styled(short_id, Style::default().fg(Color::Cyan)),
        ]),
        Line::from(vec![
            Span::styled("NAT      ", Style::default().fg(Color::DarkGray)),
            Span::styled(state.nat_status.clone(), nat_color(&state.nat_status)),
        ]),
        Line::from(""),
        Line::from(Span::styled("Listen Addresses", Style::default().fg(Color::DarkGray))),
    ];
    for addr in &state.listen_addrs {
        id_lines.push(Line::from(Span::styled(
            format!("  {}", addr),
            Style::default().fg(Color::White),
        )));
    }
    let identity = Paragraph::new(id_lines)
        .block(Block::default().borders(Borders::ALL).title(" Identity "))
        .wrap(Wrap { trim: false });
    f.render_widget(identity, left_chunks[0]);

    // Left bottom: stats
    let connected = state.peers.iter().filter(|p| p.connected).count();
    let discovered = state.peers.iter().filter(|p| !p.connected).count();
    let stats_text = vec![
        Line::from(vec![
            Span::styled("Connected   ", Style::default().fg(Color::DarkGray)),
            Span::styled(connected.to_string(), Style::default().fg(Color::Green)),
        ]),
        Line::from(vec![
            Span::styled("Discovered  ", Style::default().fg(Color::DarkGray)),
            Span::styled(discovered.to_string(), Style::default().fg(Color::Yellow)),
        ]),
    ];
    let stats = Paragraph::new(stats_text)
        .block(Block::default().borders(Borders::ALL).title(" Stats "));
    f.render_widget(stats, left_chunks[1]);

    // Right: split into connected peers (top) and log preview (bottom)
    let right_chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
        .split(cols[1]);

    render_peers_panel(f, state, right_chunks[0]);
    render_log_panel(f, state, right_chunks[1]);
}

fn render_peers_panel(f: &mut ratatui::Frame, state: &TuiState, area: Rect) {
    let items: Vec<ListItem> = state
        .peers
        .iter()
        .map(|p| {
            let (marker, color) = if p.connected {
                ("●", Color::Green)
            } else {
                ("○", Color::Yellow)
            };
            let short = short_peer_id(&p.peer_id);
            let short_addr = if p.multiaddr.len() > 25 {
                format!("{}…", &p.multiaddr[..25])
            } else {
                p.multiaddr.clone()
            };
            ListItem::new(Line::from(vec![
                Span::styled(format!("{} ", marker), Style::default().fg(color)),
                Span::styled(short, Style::default().fg(Color::White)),
                Span::styled(format!("  {}", short_addr), Style::default().fg(Color::DarkGray)),
            ]))
        })
        .collect();

    let title = format!(" Peers ({}) ", state.peers.len());
    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(title));
    f.render_widget(list, area);
}

fn render_log_panel(f: &mut ratatui::Frame, state: &TuiState, area: Rect) {
    let max_lines = area.height.saturating_sub(2) as usize;
    let total = state.log.len();
    let start = total.saturating_sub(max_lines);
    let lines: Vec<Line> = state.log.iter().skip(start).map(log_line).collect();
    let log = Paragraph::new(lines)
        .block(Block::default().borders(Borders::ALL).title(" Events "));
    f.render_widget(log, area);
}

fn render_peers(f: &mut ratatui::Frame, state: &TuiState, area: Rect) {
    let items: Vec<ListItem> = state
        .peers
        .iter()
        .map(|p| {
            let (status, color) = if p.connected {
                ("connected ", Color::Green)
            } else {
                ("discovered", Color::Yellow)
            };
            let age = p.seen_at.elapsed().as_secs();
            ListItem::new(Line::from(vec![
                Span::styled(format!("{} ", status), Style::default().fg(color)),
                Span::styled(short_peer_id(&p.peer_id), Style::default().fg(Color::Cyan)),
                Span::styled(format!("  {}", p.multiaddr), Style::default().fg(Color::White)),
                Span::styled(
                    if p.extra.is_empty() { String::new() } else { format!("  [{}]", p.extra) },
                    Style::default().fg(Color::DarkGray),
                ),
                Span::styled(
                    format!("  {}s ago", age),
                    Style::default().fg(Color::DarkGray),
                ),
            ]))
        })
        .collect();

    let title = format!(" All Peers ({}) ", state.peers.len());
    let mut list_state = state.peers_list.clone();
    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(title))
        .highlight_style(Style::default().bg(Color::DarkGray));
    f.render_stateful_widget(list, area, &mut list_state);
}

fn render_log(f: &mut ratatui::Frame, state: &TuiState, area: Rect) {
    let max_lines = area.height.saturating_sub(2) as usize;
    let total = state.log.len();

    // Respect manual scroll offset, but clamp so we can't scroll past start
    let bottom = total;
    let start = bottom
        .saturating_sub(max_lines)
        .saturating_sub(state.log_scroll as usize);
    let start = start.min(total.saturating_sub(max_lines));

    let lines: Vec<Line> = state.log.iter().skip(start).take(max_lines).map(log_line).collect();

    let scroll_hint = if state.log_scroll > 0 {
        format!(" Log  ↑{} lines ", state.log_scroll)
    } else {
        " Log  (↑/↓ scroll) ".to_string()
    };

    let log = Paragraph::new(lines)
        .block(Block::default().borders(Borders::ALL).title(scroll_hint));
    f.render_widget(log, area);
}

fn render_dht(f: &mut ratatui::Frame, state: &TuiState, area: Rect) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
        .split(area);

    // ── Top: what we are advertising ─────────────────────────────────────────
    let adv_items: Vec<ListItem> = if state.my_advertisements.is_empty() {
        vec![ListItem::new(Line::from(Span::styled(
            "  (nothing advertised yet — press 'a' to advertise a key)",
            Style::default().fg(Color::DarkGray),
        )))]
    } else {
        state
            .my_advertisements
            .iter()
            .map(|k| {
                ListItem::new(Line::from(vec![
                    Span::styled("● ", Style::default().fg(Color::Green)),
                    Span::styled(k.clone(), Style::default().fg(Color::White)),
                ]))
            })
            .collect()
    };
    let adv_block = List::new(adv_items).block(
        Block::default()
            .borders(Borders::ALL)
            .title(format!(" Advertising ({}) — refreshed every 90s ", state.my_advertisements.len())),
    );
    f.render_widget(adv_block, rows[0]);

    // ── Bottom: query results ────────────────────────────────────────────────
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(35), Constraint::Percentage(65)])
        .split(rows[1]);

    let key_items: Vec<ListItem> = state
        .dht_results
        .iter()
        .map(|e| {
            let age = e.queried_at.elapsed().as_secs();
            ListItem::new(Line::from(vec![
                Span::styled(e.key.clone(), Style::default().fg(Color::Cyan)),
                Span::styled(
                    format!("  {}  {}s ago", e.peers.len(), age),
                    Style::default().fg(Color::DarkGray),
                ),
            ]))
        })
        .collect();

    let mut list_state = state.dht_list.clone();
    let key_list = List::new(key_items)
        .block(Block::default().borders(Borders::ALL).title(
            format!(" Query Results ({}) — press '/' to query ", state.dht_results.len()),
        ))
        .highlight_style(Style::default().bg(Color::DarkGray).fg(Color::White));
    f.render_stateful_widget(key_list, cols[0], &mut list_state);

    // Right: peer details for selected key
    let detail_lines: Vec<Line> = match state.dht_list.selected() {
        Some(i) => match state.dht_results.get(i) {
            None => vec![],
            Some(e) if e.peers.is_empty() => vec![Line::from(Span::styled(
                "  (no peers found)",
                Style::default().fg(Color::DarkGray),
            ))],
            Some(e) => e
                .peers
                .iter()
                .flat_map(|p| {
                    let mut lines = vec![Line::from(vec![
                        Span::styled("Peer  ", Style::default().fg(Color::DarkGray)),
                        Span::styled(p.peer_id.clone(), Style::default().fg(Color::Cyan)),
                    ])];
                    if p.addrs.is_empty() {
                        lines.push(Line::from(Span::styled(
                            "  (no addresses)",
                            Style::default().fg(Color::DarkGray),
                        )));
                    } else {
                        for addr in &p.addrs {
                            lines.push(Line::from(vec![
                                Span::styled("  → ", Style::default().fg(Color::Green)),
                                Span::styled(addr.clone(), Style::default().fg(Color::White)),
                            ]));
                        }
                    }
                    lines.push(Line::from(""));
                    lines
                })
                .collect(),
        },
        None => vec![Line::from(Span::styled(
            "  Select a key on the left",
            Style::default().fg(Color::DarkGray),
        ))],
    };

    let detail_block = Paragraph::new(detail_lines)
        .block(Block::default().borders(Borders::ALL).title(" Peer Addresses "))
        .wrap(Wrap { trim: false });
    f.render_widget(detail_block, cols[1]);
}

fn render_input_popup(f: &mut ratatui::Frame, title: &str, label: &str, value: &str, area: Rect) {
    let popup = centered_rect(60, 7, area);
    f.render_widget(Clear, popup);

    let lines = vec![
        Line::from(""),
        Line::from(vec![
            Span::styled(format!("  {}: ", label), Style::default().fg(Color::DarkGray)),
            Span::styled(value.to_string(), Style::default().fg(Color::White)),
            Span::styled("_", Style::default().fg(Color::Cyan).add_modifier(Modifier::SLOW_BLINK)),
        ]),
        Line::from(""),
        Line::from(vec![
            Span::styled("  Enter", Style::default().fg(Color::Green)),
            Span::styled(" confirm   ", Style::default().fg(Color::DarkGray)),
            Span::styled("Esc", Style::default().fg(Color::Red)),
            Span::styled(" cancel", Style::default().fg(Color::DarkGray)),
        ]),
    ];
    let popup_widget = Paragraph::new(lines).block(
        Block::default()
            .borders(Borders::ALL)
            .title(title.to_string())
            .border_style(Style::default().fg(Color::Cyan)),
    );
    f.render_widget(popup_widget, popup);
}

// ── Input handling ────────────────────────────────────────────────────────────

enum Action {
    Continue,
    Quit,
}

fn handle_key(
    event: Event,
    state: &mut TuiState,
    tx_cmd: &mpsc::Sender<TuiCommand>,
) -> Action {
    let Event::Key(KeyEvent { code, modifiers, .. }) = event else {
        return Action::Continue;
    };

    if state.input_mode != InputMode::Normal {
        return handle_input_key(code, state, tx_cmd);
    }

    match (code, modifiers) {
        (KeyCode::Char('q'), _) | (KeyCode::Char('c'), KeyModifiers::CONTROL) => {
            let _ = tx_cmd.try_send(TuiCommand::Quit);
            return Action::Quit;
        }
        (KeyCode::Char('d'), _) => {
            state.input_mode = InputMode::Dial;
            state.input_value.clear();
        }
        (KeyCode::Char('a'), _) => {
            state.input_mode = InputMode::Advertise;
            state.input_value.clear();
        }
        (KeyCode::Char('/'), _) => {
            state.input_mode = InputMode::Query;
            state.input_value.clear();
            state.tab = Tab::Dht;
        }
        (KeyCode::Tab, _) | (KeyCode::Right, _) => {
            state.tab = match state.tab {
                Tab::Overview => Tab::Peers,
                Tab::Peers => Tab::Dht,
                Tab::Dht => Tab::Log,
                Tab::Log => Tab::Overview,
            };
        }
        (KeyCode::Left, _) => {
            state.tab = match state.tab {
                Tab::Overview => Tab::Log,
                Tab::Peers => Tab::Overview,
                Tab::Dht => Tab::Peers,
                Tab::Log => Tab::Dht,
            };
        }
        (KeyCode::Down, _) => match state.tab {
            Tab::Peers => {
                let next = state
                    .peers_list
                    .selected()
                    .map(|i| (i + 1).min(state.peers.len().saturating_sub(1)))
                    .unwrap_or(0);
                state.peers_list.select(Some(next));
            }
            Tab::Dht => {
                let next = state
                    .dht_list
                    .selected()
                    .map(|i| (i + 1).min(state.dht_results.len().saturating_sub(1)))
                    .unwrap_or(0);
                state.dht_list.select(Some(next));
            }
            Tab::Log => {
                let max_scroll = state.log.len().saturating_sub(1) as u16;
                if state.log_scroll < max_scroll {
                    state.log_scroll += 1;
                }
            }
            _ => {}
        },
        (KeyCode::Up, _) => match state.tab {
            Tab::Peers => {
                let prev = state.peers_list.selected().and_then(|i| i.checked_sub(1));
                state.peers_list.select(prev);
            }
            Tab::Dht => {
                let prev = state.dht_list.selected().and_then(|i| i.checked_sub(1));
                state.dht_list.select(prev);
            }
            Tab::Log => {
                state.log_scroll = state.log_scroll.saturating_sub(1);
            }
            _ => {}
        },
        _ => {}
    }
    Action::Continue
}

fn handle_input_key(
    code: KeyCode,
    state: &mut TuiState,
    tx_cmd: &mpsc::Sender<TuiCommand>,
) -> Action {
    match code {
        KeyCode::Esc => {
            state.input_mode = InputMode::Normal;
            state.input_value.clear();
        }
        KeyCode::Enter => {
            let value = state.input_value.trim().to_string();
            if !value.is_empty() {
                match state.input_mode {
                    InputMode::Dial => {
                        state.push_log(LogLevel::Info, format!("Dialing {}", value));
                        let _ = tx_cmd.try_send(TuiCommand::Dial(value));
                    }
                    InputMode::Advertise => {
                        state.push_log(LogLevel::Info, format!("Advertising key: {}", value));
                        let _ = tx_cmd.try_send(TuiCommand::Advertise(value));
                    }
                    InputMode::Query => {
                        state.push_log(LogLevel::Info, format!("Querying DHT for: {}", value));
                        let _ = tx_cmd.try_send(TuiCommand::Query(value));
                    }
                    InputMode::Normal => {}
                }
            }
            state.input_mode = InputMode::Normal;
            state.input_value.clear();
        }
        KeyCode::Backspace => {
            state.input_value.pop();
        }
        KeyCode::Char(c) => {
            state.input_value.push(c);
        }
        _ => {}
    }
    Action::Continue
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Run the TUI. Blocks until the user quits.
/// `rx` receives state updates from the swarm task.
/// `tx_cmd` sends commands back to the swarm task.
pub async fn run_tui(
    mut rx: mpsc::UnboundedReceiver<StateUpdate>,
    tx_cmd: mpsc::Sender<TuiCommand>,
) -> Result<()> {
    // Terminal setup
    enable_raw_mode()?;
    let mut stdout = std::io::stdout();
    stdout.execute(EnterAlternateScreen)?;

    // Panic hook: always restore terminal on panic so the shell is usable
    let original_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = disable_raw_mode();
        let _ = std::io::stdout().execute(LeaveAlternateScreen);
        original_hook(info);
    }));

    let backend = CrosstermBackend::new(std::io::stdout());
    let mut terminal = Terminal::new(backend)?;

    let mut tui_state = TuiState::new();
    let mut event_stream = EventStream::new();

    loop {
        terminal.draw(|f| render(f, &tui_state))?;

        tokio::select! {
            Some(update) = rx.recv() => {
                tui_state.apply(update);
            }
            Some(Ok(event)) = event_stream.next() => {
                // Handle resize: ratatui reflows automatically on next draw
                if let Event::Resize(_, _) = event {
                    terminal.autoresize()?;
                    continue;
                }
                match handle_key(event, &mut tui_state, &tx_cmd) {
                    Action::Quit => break,
                    Action::Continue => {}
                }
            }
        }
    }

    // Restore terminal
    disable_raw_mode()?;
    stdout.execute(LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    Ok(())
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn short_peer_id(id: &str) -> String {
    if id.len() > 16 {
        format!("{}…{}", &id[..8], &id[id.len() - 6..])
    } else {
        id.to_string()
    }
}

fn log_line(entry: &LogEntry) -> Line<'static> {
    let (label, color) = match entry.level {
        LogLevel::Info => ("INFO ", Color::Cyan),
        LogLevel::Warn => ("WARN ", Color::Yellow),
        LogLevel::Error => ("ERR  ", Color::Red),
        LogLevel::Debug => ("DBG  ", Color::DarkGray),
    };
    Line::from(vec![
        Span::styled(
            format!("{} ", entry.time.clone()),
            Style::default().fg(Color::DarkGray),
        ),
        Span::styled(label.to_string(), Style::default().fg(color).add_modifier(Modifier::BOLD)),
        Span::raw(entry.message.clone()),
    ])
}

fn nat_color(status: &str) -> Style {
    if status.starts_with("public") || status.starts_with("dcutr") {
        Style::default().fg(Color::Green)
    } else if status.starts_with("relay") {
        Style::default().fg(Color::Yellow)
    } else {
        Style::default().fg(Color::DarkGray)
    }
}

/// Return a centered rect of fixed height and percentage width within `area`.
fn centered_rect(percent_x: u16, height: u16, area: Rect) -> Rect {
    let popup_width = area.width * percent_x / 100;
    let x = area.x + (area.width.saturating_sub(popup_width)) / 2;
    let y = area.y + (area.height.saturating_sub(height)) / 2;
    Rect::new(x, y, popup_width.min(area.width), height.min(area.height))
}
