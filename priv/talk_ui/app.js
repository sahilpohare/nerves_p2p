(() => {
  "use strict";

  const $ = (selector) => document.querySelector(selector);
  const stages = ["discovery", "verified", "partisan", "horde"];
  const stageAliases = {
    iroh: "discovery", iroh_discovery: "discovery", discovery: "discovery",
    signature: "verified", signature_verified: "verified", verified: "verified",
    partisan: "partisan", partisan_endpoint: "partisan",
    horde: "horde", horde_placement: "horde", placement: "horde"
  };
  const ui = {
    button: $("#run-demo"), label: $("#run-label"), state: $("#run-state"),
    commandTitle: $("#command-title"), commandDetail: $("#command-detail"),
    connection: $("#connection"), connectionText: $("#connection-text"),
    tape: $("#event-tape"), count: $("#event-count"), live: $("#live-status"),
    peerStatus: $("#peer-status"), peerDetails: $("#peer-details")
  };

  let source;
  let reconnectTimer;
  let reconnectAttempt = 0;
  let eventCount = 0;
  let currentStatus = "loading";

  const text = (value, fallback = "not available") => value === undefined || value === null || value === "" ? fallback : String(value);
  const shortId = (value) => {
    const id = text(value);
    return id.length > 20 ? `${id.slice(0, 10)}...${id.slice(-7)}` : id;
  };

  function announce(message) {
    ui.live.textContent = message;
  }

  function setConnection(state, label) {
    ui.connection.dataset.state = state;
    ui.connectionText.textContent = label;
  }

  function normalizeStatus(value) {
    const status = String(value || "idle").toLowerCase();
    if (["loading", "idle", "running", "success", "error"].includes(status)) return status;
    if (["complete", "completed", "done"].includes(status)) return "success";
    if (status === "ok") return "running";
    if (["failed", "failure"].includes(status)) return "error";
    return "idle";
  }

  function setStatus(status, detail) {
    currentStatus = normalizeStatus(status);
    const copy = {
      loading: ["SYSTEM INITIALIZING", "Requesting current state from the talk runtime."],
      idle: ["READY FOR LIVE RUN", "Discovery begins with two real Iroh daemon processes."],
      running: ["DEMO IN PROGRESS", "Events update as the capability moves through the handoff."],
      success: ["HANDOFF COMPLETE", "The worker was placed on the current local Horde member."],
      error: ["RUN INTERRUPTED", "Read the event tape, then run the demo again."]
    }[currentStatus];
    ui.state.textContent = currentStatus.toUpperCase();
    ui.commandTitle.textContent = copy[0];
    ui.commandDetail.textContent = detail || copy[1];
    ui.button.disabled = currentStatus === "loading" || currentStatus === "running";
    ui.label.textContent = currentStatus === "running" ? "RUNNING" : currentStatus === "error" ? "RUN AGAIN" : "RUN DEMO";
    document.body.dataset.status = currentStatus;
  }

  function stageName(value) {
    return stageAliases[String(value || "").toLowerCase()] || "";
  }

  function renderStages(data) {
    const status = normalizeStatus(data.status || data.run_status);
    const active = stageName(data.stage || data.current_stage);
    const supplied = data.stages && typeof data.stages === "object" ? data.stages : {};
    const activeIndex = stages.indexOf(active);

    stages.forEach((name, index) => {
      const node = document.querySelector(`[data-stage="${name}"]`);
      const explicit = supplied[name] || supplied[Object.keys(stageAliases).find((key) => stageAliases[key] === name)];
       let state = typeof explicit === "object" ? explicit.status : explicit;
       if (state === "ok" || state === "success") state = "done";
       if (state === "running") state = "active";
      if (!state && active) state = index < activeIndex ? "done" : index === activeIndex ? "active" : "pending";
       if (!state && status === "success") state = "done";
       if (status === "error" && index === Math.max(0, activeIndex)) state = "error";
       node.dataset.state = String(state || "pending").toLowerCase();
       node.toggleAttribute("aria-current", node.dataset.state === "active");
    });
  }

  function daemonData(data, role) {
    const daemons = data.daemons || data.topology || {};
    if (Array.isArray(daemons)) return daemons.find((item) => String(item.role || item.name || "").toLowerCase().includes(role)) || {};
    return daemons[role] || data[`${role}_daemon`] || {};
  }

  function renderDaemon(role, data) {
    const node = document.querySelector(`[data-daemon="${role}"]`);
    const daemon = daemonData(data, role);
    const id = daemon.endpoint_id || daemon.id || data[`${role}_id`];
    node.querySelector("code").textContent = shortId(id || "awaiting identity");
    node.dataset.state = daemon.status || (id ? "active" : "waiting");
  }

  function renderPeer(peer = {}) {
    const partisan = peer.partisan || peer.partisan_endpoint || [peer.partisan_ip, peer.partisan_port].filter(Boolean).join(":");
    const capabilities = peer.capabilities || {};
    const capability = typeof capabilities === "object" ? Object.entries(capabilities).map(([key, value]) => `${key} = ${value}`).join(", ") : capabilities;
    const values = [
      ["ENDPOINT", shortId(peer.endpoint_id || peer.id || "not selected")],
      ["NODE", text(peer.node_name || peer.node, "not selected")],
      ["PARTISAN", text(partisan, "not joined")],
      ["CAPABILITY", text(capability || peer.capability, "gpu = required")],
      ["SEQUENCE", text(peer.sequence, "not received")],
      ["PLACEMENT", text(peer.placement || peer.horde_placement, "local Horde member")]
    ];
    ui.peerDetails.replaceChildren(...values.map(([term, value]) => {
      const row = document.createElement("div");
      const dt = document.createElement("dt");
      const dd = document.createElement("dd");
      dt.textContent = term;
      dd.textContent = value;
      row.append(dt, dd);
      return row;
    }));
    ui.peerStatus.textContent = peer.endpoint_id || peer.id ? "LOCKED" : "NONE";
  }

  function appendEvent(event) {
    if (!event || typeof event !== "object") event = { message: text(event) };
    if (ui.tape.querySelector(".empty-line")) ui.tape.replaceChildren();
    const row = document.createElement("div");
    const time = document.createElement("time");
    const kind = document.createElement("b");
    const message = document.createElement("span");
    const eventTime = event.at || event.time || event.timestamp;
    time.textContent = eventTime ? new Date(eventTime).toLocaleTimeString([], { hour12: false }) : new Date().toLocaleTimeString([], { hour12: false });
    kind.textContent = text(event.type || event.kind || event.stage, "EVENT").toUpperCase().replaceAll("_", " ");
    message.textContent = text(event.message || event.detail || event.summary || event.result, "State updated");
    row.className = "tape-row";
    row.dataset.kind = String(event.type || event.kind || "event").toLowerCase();
    row.append(time, kind, message);
    ui.tape.append(row);
    while (ui.tape.children.length > 5) ui.tape.firstElementChild.remove();
    eventCount += 1;
    ui.count.textContent = `${eventCount} ${eventCount === 1 ? "EVENT" : "EVENTS"}`;
    ui.tape.scrollTop = ui.tape.scrollHeight;
  }

  function render(data = {}) {
    const payload = data.state && typeof data.state === "object" ? { ...data, ...data.state } : data;
    setStatus(payload.status || payload.run_status || "idle", payload.error || payload.detail);
    renderStages(payload);
    renderDaemon("finder", payload);
    renderDaemon("gpu", payload);
    renderPeer(payload.selected_peer || payload.peer || {});
    if (Array.isArray(payload.events)) {
      ui.tape.replaceChildren();
      eventCount = 0;
      payload.events.forEach(appendEvent);
    }
  }

  function handleEvent(message) {
    let data;
    try { data = JSON.parse(message.data); } catch { data = { message: message.data }; }
    appendEvent({ type: message.type === "message" ? data.type : message.type, ...data });
    const renderData = data.data && typeof data.data === "object" ? { ...data, ...data.data } : data;
    if (renderData.stage === "complete") renderData.status = "success";
    if (renderData.state || renderData.status || renderData.stage || renderData.selected_peer || renderData.peer || renderData.daemons) render(renderData);
    if (data.stage) announce(`${String(data.stage).replaceAll("_", " ")}: ${text(data.message, data.status)}`);
  }

  function connectEvents() {
    clearTimeout(reconnectTimer);
    source?.close();
    setConnection(reconnectAttempt ? "reconnecting" : "connecting", reconnectAttempt ? "RECONNECTING" : "CONNECTING");
    source = new EventSource("/api/events");
    source.onopen = () => {
      reconnectAttempt = 0;
      setConnection("connected", "LIVE LINK");
    };
    source.onmessage = handleEvent;
    ["state", "stage", "event", "success", "error"].forEach((name) => source.addEventListener(name, handleEvent));
    source.onerror = () => {
      source.close();
      setConnection("reconnecting", "RECONNECTING");
      clearTimeout(reconnectTimer);
      const delay = Math.min(1000 * (2 ** reconnectAttempt++), 15000);
      reconnectTimer = setTimeout(connectEvents, delay);
    };
  }

  async function loadState() {
    setStatus("loading");
    try {
      const response = await fetch("/api/state", { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error(`State request failed (${response.status})`);
      render(await response.json());
    } catch (error) {
      setStatus("error", `${error.message}. The event stream will keep reconnecting.`);
      appendEvent({ type: "error", message: error.message });
    }
  }

  async function runDemo() {
    if (ui.button.disabled) return;
    setStatus("running");
    renderStages({ status: "running", stage: "discovery" });
    announce("Demo started");
    try {
      const response = await fetch("/api/run", { method: "POST", headers: { Accept: "application/json" } });
      const data = response.headers.get("content-type")?.includes("application/json") ? await response.json() : {};
      if (!response.ok) throw new Error(data.error || `Run request failed (${response.status})`);
      if (Object.keys(data).length) render(data);
    } catch (error) {
      setStatus("error", error.message);
      renderStages({ status: "error", stage: "discovery" });
      appendEvent({ type: "error", message: error.message });
      announce(`Demo failed: ${error.message}`);
    }
  }

  ui.button.addEventListener("click", runDemo);
  document.addEventListener("keydown", (event) => {
    if (event.key.toLowerCase() === "r" && !event.metaKey && !event.ctrlKey && !event.altKey && document.activeElement?.tagName !== "INPUT") {
      event.preventDefault();
      runDemo();
    }
  });
  window.addEventListener("online", () => { loadState(); connectEvents(); });
  window.addEventListener("offline", () => setConnection("reconnecting", "OFFLINE"));
  window.addEventListener("beforeunload", () => source?.close());

  loadState();
  connectEvents();
})();
