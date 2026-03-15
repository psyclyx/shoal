# Data Sources

Data sources feed events into the reactive pipeline. They are not special —
they're just things that call `enqueue([:event-id ...args])`. The design
question is: what Zig primitives do they need, and how does Janet wire them?

## Principle: Zig Owns I/O, Janet Owns Meaning

Zig manages file descriptors, poll loops, process lifecycles, and byte framing.
Janet decides what events mean, how they map to state, and what to render.

The boundary is bytes → Janet values. Zig reads bytes from a socket or process,
frames them into messages, converts to Janet strings or parsed values, and
enqueues events. Janet handlers interpret those events.

## Built-in Effects for Data Sources

### `:spawn` — Run a Command

Zig forks a child process, pipes stdout, and enqueues events as lines arrive.

```janet
# fx from a handler:
{:spawn {:cmd ["wpctl" "get-volume" "@DEFAULT_AUDIO_SINK@"]
         :event :volume/stdout    # event-id for each stdout line
         :done  :volume/exited}}  # event-id when process exits
```

Zig-side:
- `fork`/`execvp` the command
- Pipe stdout, add read end to poll loop
- On each complete line: `enqueue([:volume/stdout "line content"])`
- On EOF/exit: `enqueue([:volume/exited exit-code])`
- stderr ignored (or logged by Zig)

Multiple spawns can be active. Each is identified by its event-id pair. A new
spawn with the same `:event` id replaces (kills) the previous one.

For **polling data sources** (cpu, memory, volume), the pattern is:
```janet
(reg-event-handler :init
  (fn [cofx event]
    {:timer {:id :volume-poll
             :delay 1.0
             :repeat true
             :event [:volume/poll]}}))

(reg-event-handler :volume/poll
  (fn [cofx event]
    {:spawn {:cmd ["wpctl" "get-volume" "@DEFAULT_AUDIO_SINK@"]
             :event :volume/stdout
             :done :volume/done}}))

(reg-event-handler :volume/stdout
  (fn [cofx event]
    (let [line (event 1)
          vol (parse-volume line)]
      {:db (put (cofx :db) :volume vol)})))
```

### `:ipc` — Unix Socket Connection

Zig manages a persistent Unix socket with automatic reconnection. This is for
tidepool and any other socket-based IPC.

```janet
# fx from a handler:
{:ipc {:connect {:path "/run/user/1000/tidepool-wayland-1"
                 :name :tidepool          # connection id
                 :framing :netrepl        # :netrepl | :line | :raw
                 :event :tidepool/recv    # event-id for received messages
                 :connected :tidepool/connected
                 :disconnected :tidepool/disconnected
                 :reconnect 1.0}}}        # auto-reconnect delay (seconds), nil = no reconnect

# Send on an existing connection:
{:ipc {:send {:name :tidepool
              :data "(ipc/watch-json [:tags :layout :title :windows :signal])\n"}}}
```

Zig-side:
- Manages a pool of named connections (small fixed array, say 8)
- Each connection: fd, recv buffer, framing state, event-ids, reconnect config
- On connect: `enqueue([:tidepool/connected])`
- On message (framed): `enqueue([:tidepool/recv "message bytes"])`
- On disconnect: `enqueue([:tidepool/disconnected])`, start reconnect timer
- Connections added to the main poll loop alongside Wayland fd

Framing modes:
- `:netrepl` — 4-byte LE length prefix (tidepool's protocol). Strips the 0xFF/
  0xFE prefix byte and delivers payload.
- `:line` — newline-delimited messages
- `:raw` — deliver whatever bytes are available (for protocols that don't frame)

### `:ipc` Lifecycle

The tidepool connection uses `:ipc` to handle the netrepl protocol:

```janet
(reg-event-handler :init
  (fn [cofx event]
    {:ipc {:connect {:path (tidepool-socket-path)
                     :name :tidepool
                     :framing :netrepl
                     :event :tidepool/recv
                     :connected :tidepool/connected
                     :disconnected :tidepool/disconnected
                     :reconnect 1.0}}}))

(reg-event-handler :tidepool/connected
  (fn [cofx event]
    {:ipc {:send {:name :tidepool
                  :data "\xFF{:name \"shoal\" :auto-flush true}"}}}))

# After handshake prompt comes back, subscribe
(reg-event-handler :tidepool/handshake
  (fn [cofx event]
    {:ipc {:send {:name :tidepool
                  :data "(ipc/watch-json [:tags :layout :title :windows :signal])\n"}}}))

(reg-event-handler :tidepool/recv
  (fn [cofx event]
    (let [msg (event 1)]
      (if (string/has-prefix? "\xFF" msg)
        # Handshake response — trigger subscription
        {:dispatch [:tidepool/handshake]}
        # Data — parse JSON, update db
        (tidepool/handle-data cofx msg)))))
```

Wait — the framing layer strips 0xFF already. Rethink.

### Netrepl Framing Details

The netrepl protocol has three message types indicated by the first byte after
the length prefix:
- `0xFF` — output data (stdout from the REPL)
- `0xFE` — return value
- Plain text — input echo

For tidepool, the sequence is:
1. Connect → send handshake `\xFF{:name "shoal" :auto-flush true}` as a netrepl
   message (4-byte length prefix + payload)
2. Receive `0xFF` prompt response → send subscription expression
3. Receive `0xFF` data messages containing JSON lines

The Zig framing layer should handle the netrepl wire protocol (length prefix,
message type byte) and expose a cleaner interface to Janet:

- On `0xFF` message: deliver as `:event` with the payload (minus 0xFF prefix)
- On `0xFE` message: deliver as a separate event (or same event, with a type tag)
- Handshake: Zig can handle automatically if we configure it, or Janet can drive

**Decision: Zig handles netrepl framing but not protocol semantics.** Janet
sees raw payloads with type tags. This keeps the Zig IPC layer generic.

Revised event shape:
```janet
# 0xFF output data:
[:tidepool/recv :output "JSON lines here\n"]

# 0xFE return value:
[:tidepool/recv :return "value string"]
```

The `:ipc` connect config gets a `:netrepl` framing mode that does:
1. Length-prefix framing (read/write)
2. First-byte type classification (:output, :return, :text)
3. Automatic handshake send on connect (configured via `:handshake` key)

```janet
{:ipc {:connect {:path (tidepool-socket-path)
                 :name :tidepool
                 :framing :netrepl
                 :handshake "\xFF{:name \"shoal\" :auto-flush true}"
                 :event :tidepool/recv
                 :connected :tidepool/connected
                 :disconnected :tidepool/disconnected
                 :reconnect 1.0}}}
```

On connect, Zig:
1. Sends the handshake message (length-prefixed)
2. Waits for the first response (prompt)
3. Fires `:tidepool/connected` event
4. Subsequent messages fire `:tidepool/recv` with type + payload

### JSON Parsing

**Janet parses JSON, not Zig.** Zig delivers string payloads. Janet has
`json/decode` in its stdlib (or we embed a small parser). This keeps the Zig
IPC layer generic — it doesn't know or care about JSON.

For tidepool, the JSON contains newline-separated objects. Janet splits and
parses:

```janet
(defn tidepool/handle-data [cofx msg-type payload]
  (when (= msg-type :output)
    (var db (cofx :db))
    (each line (string/split "\n" payload)
      (when (> (length line) 0)
        (def data (json/decode line))
        (when data
          (set db (tidepool/apply-event db data)))))
    {:db db}))

(defn tidepool/apply-event [db data]
  (match (data "event")
    "tags"    (tidepool/apply-tags db data)
    "layout"  (tidepool/apply-layout db data)
    "title"   (tidepool/apply-title db data)
    "windows" (tidepool/apply-windows db data)
    "signal"  (tidepool/apply-signal db data)
    _ db))
```

This is dramatically simpler than the current tidepool.zig which does 300+
lines of JSON parsing in Zig. Janet's dynamic typing and pattern matching make
JSON natural.

## Janet-Native Data Sources

Some data sources don't need Zig at all. They use `:timer` + Janet file I/O
or `:timer` + `:spawn`:

### Clock
```janet
(reg-event-handler :clock/tick
  (fn [cofx event]
    {:db (put (cofx :db) :time (os/date))}))

# In :init handler:
{:timer {:id :clock :delay 1.0 :repeat true :event [:clock/tick]}}
```

### CPU / Memory
```janet
(reg-event-handler :sys/poll
  (fn [cofx event]
    (let [meminfo (slurp "/proc/meminfo")
          stat (slurp "/proc/stat")]
      {:db (-> (cofx :db)
               (put :memory (parse-meminfo meminfo))
               (put :cpu (parse-stat stat)))})))
```

### Battery
```janet
(reg-event-handler :battery/poll
  (fn [cofx event]
    (let [status (slurp "/sys/class/power_supply/BAT0/status")
          capacity (slurp "/sys/class/power_supply/BAT0/capacity")]
      {:db (put (cofx :db) :battery
                {:status (string/trim status)
                 :capacity (scan-number (string/trim capacity))})})))
```

## Implementation Plan

### Step 1: `:spawn` fx handler

Add to `executeFx` in janet.zig:
- Parse spawn spec (cmd array, event-id, done-id)
- Fork/exec with piped stdout
- Add stdout fd to poll loop
- On readable: buffer lines, enqueue events
- On EOF: enqueue done event, clean up

This is the simplest data source primitive. A fixed pool of child process
slots (8-16 max).

### Step 2: `:ipc` fx handler

Add IPC connection pool to Dispatch:
- Fixed array of IpcConnection structs (8 max)
- Each: name (keyword), fd, recv buffer, framing mode, event ids, reconnect
- `handleIpcFx` — parse connect/send/disconnect specs
- Framing: netrepl (length-prefix + type byte) and line-delimited
- Add fds to poll loop
- On readable: frame messages, enqueue events
- On disconnect: enqueue event, start reconnect timer

### Step 3: Wire tidepool as Janet module

Write `tidepool.janet` — a Janet module that:
- Registers `:init` handler to connect via `:ipc`
- Registers `:tidepool/recv` handler to parse JSON and update db
- Exports subscriptions: `(reg-sub :tags ...)`, `(reg-sub :title ...)`, etc.
- Load in `shoal.janet` boot or via `(import "tidepool")`

### Step 4: Janet-native data sources

Write simple Janet modules for clock, battery, memory, etc. These are tiny
(10-30 lines each) — just timer + handler + sub.

## What's Not Covered

- **Network data source**: needs socket for monitoring, probably `:spawn` +
  `nmcli monitor` or similar.
- **PulseAudio**: `pactl subscribe` via `:spawn` for events, `wpctl` for queries.
- **File watching**: inotify for config reload. Could be a future Zig primitive
  (`:watch` fx) or just polling.
- **stdin**: reading from stdin for piped input. Low priority.

## Key Decisions

1. **Zig handles I/O, Janet handles meaning.** No JSON parsing in Zig.
2. **`:spawn` and `:ipc` are the only I/O primitives.** Everything else composes
   from these + `:timer`.
3. **Data sources are Janet modules, not Zig code.** They register handlers
   and subs. They live outside shoal core.
4. **Named connections/processes.** Enables replacement and cancellation.
5. **Framing is Zig's job.** Line splitting, netrepl length-prefix parsing —
   done before Janet sees the data. Janet gets clean message strings.
