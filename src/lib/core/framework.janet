# shoal — reactive surface runtime
#
# Core primitives for building Wayland surfaces with Janet.
# Registries: event handlers, cofx injectors, fx executors, subscriptions, surfaces.
# All tables are module-level. Zig reads these directly to dispatch events.

# --- Load path ---

# Search path for (use). Each entry is a directory.
# Populated by Zig runtime with config dir + user dir + sholib dir.
(var load-path @[])

(defn set-load-path
  "Called by Zig to set the module search path."
  [path]
  (set load-path path))

(defn add-load-path
  "Add a directory to the load path (front = highest priority)."
  [dir]
  (array/insert load-path 0 dir))

(defn use
  "Load a module from the load path.
   (use \"compositor/sway\") → searches load-path for compositor/sway.janet
   Modules are loaded into the current environment, so they have access to
   all bindings from core/framework.janet (theme, db, etc)."
  [name]
  (def rel-path (string "/" name ".janet"))
  (def env (fiber/getenv (fiber/current)))
  (var result nil)
  (var found false)
  (each dir load-path
    (def full-path (string dir rel-path))
    (try
      (do
        (set result (dofile full-path :env env))
        (set found true)
        (break))
      ([err] nil)))
  (unless found
    (error (string "use: module not found: " name)))
  result)

(def- handlers
  "Registry: event-id keyword → handler-fn or {:fn handler-fn :cofx [...keys]}"
  @{})

(def- cofx-registry
  "Registry: cofx-id keyword → injector-fn (fn [cofx] → cofx with key added)"
  @{})

(def- fx-registry
  "Registry: fx-id keyword → executor-fn (fn [value] → side effect)"
  @{})

# --- Registration API ---

(defn reg-event-handler
  "Register a handler for an event-id.

  Two arities:
    (reg-event-handler :id handler-fn)
    (reg-event-handler :id [:cofx :key1 :key2] handler-fn)

  Handler fn signature: (fn [cofx event] → fx-map or nil)
  When cofx keys are declared, those cofx injectors run before the handler.

  Multiple handlers can be registered for the same event-id. They are composed:
  each handler sees the db as updated by previous handlers, and fx maps are merged."
  [event-id & args]
  (def entry
    (match args
      [cofx-keys handler-fn]
      {:fn handler-fn :cofx cofx-keys}

      [handler-fn]
      {:fn handler-fn :cofx []}

      _ (error "reg-event-handler: expected (id fn) or (id cofx-keys fn)")))
  (def existing (get handlers event-id))
  (if existing
    (put handlers event-id (array/push (if (array? existing) existing @[existing]) entry))
    (put handlers event-id entry)))

(defn reg-cofx
  "Register a cofx injector. Called before handlers that declare this cofx key.

  Injector signature: (fn [cofx] → cofx)
  The injector receives the cofx table and should `put` its key into it."
  [cofx-id injector-fn]
  (put cofx-registry cofx-id injector-fn))

(defn reg-fx
  "Register an fx executor. Called after a handler returns an fx map with this key.

  Executor signature: (fn [value] → nil)
  The executor receives the value from the fx map and performs the side effect."
  [fx-id executor-fn]
  (put fx-registry fx-id executor-fn))

# --- Query API (for Zig to call) ---

(defn get-handler
  "Look up a handler entry by event-id. Returns {:fn ... :cofx ...} or nil.
  When multiple handlers are registered, returns a composed handler."
  [event-id]
  (def entry (get handlers event-id))
  (when entry
    (if (array? entry)
      # Compose multiple handlers: thread db, accumulate fx
      (let [all-cofx (distinct (mapcat |($ :cofx) entry))]
        {:fn (fn [cofx event]
               (var fx @{})
               (var dispatches @[])
               (var timers @[])
               (var renders @[])
               (each h entry
                 (def result ((h :fn) cofx event))
                 (when result
                   (when (result :db)
                     (put cofx :db (result :db)))
                   # Accumulate :dispatch and :dispatch-n
                   (when (result :dispatch)
                     (array/push dispatches (result :dispatch)))
                   (when (result :dispatch-n)
                     (array/concat dispatches (result :dispatch-n)))
                   # Accumulate :timer into array
                   (when (result :timer)
                     (array/push timers (result :timer)))
                   # Accumulate targeted render requests. A db-writing handler
                   # without a target keeps the old conservative full redraw.
                   (if (result :render)
                     (array/push renders (result :render))
                     (when (result :db)
                       (array/push renders :all)))
                   (merge-into fx result)))
               # Replace with accumulated values
               (when (> (length dispatches) 0)
                 (put fx :dispatch-n dispatches)
                 (put fx :dispatch nil))
               (when (> (length timers) 0)
                 (put fx :timer timers))
               (when (> (length renders) 0)
                 (put fx :render renders))
               (if (next fx) fx nil))
         :cofx all-cofx})
      entry)))

(defn get-cofx-injector
  "Look up a cofx injector by cofx-id. Returns fn or nil."
  [cofx-id]
  (get cofx-registry cofx-id))

(defn get-fx-executor
  "Look up an fx executor by fx-id. Returns fn or nil."
  [fx-id]
  (get fx-registry fx-id))

# --- Subscriptions ---

(def- sub-registry
  "Registry: sub-id keyword → [sub-fn deps-or-nil]"
  @{})

(def- sub-cache
  "Cache: sub-id keyword → [gen value inputs-or-nil]"
  @{})

(var- db-generation 0)
(var- *current-db* nil)
(var- *current-output* nil)

(defn reg-sub
  "Register a subscription.

  Layer 2 (db extractor):
    (reg-sub :id (fn [db] ...))

  Layer 3 (sub-to-sub):
    (reg-sub :id [:dep1 :dep2] (fn [v1 v2] ...))"
  [sub-id & args]
  (match args
    [deps-vec sub-fn]
    (put sub-registry sub-id [sub-fn deps-vec])

    [sub-fn]
    (put sub-registry sub-id [sub-fn nil])

    _ (error "reg-sub: expected (id fn) or (id deps fn)")))

(defn sub
  "Query a subscription value. Evaluates lazily with memoization."
  [sub-id]
  (def entry (get sub-registry sub-id))
  (unless entry (error (string "sub: unknown subscription " sub-id)))

  (def cached (get sub-cache sub-id))
  (def sub-fn (entry 0))
  (def deps (entry 1))

  (if deps
    # Layer 3: depends on other subs
    (if (and cached (= (cached 0) db-generation))
      (cached 1)
      (let [input-vals (map sub deps)]
        (if (and cached (deep= input-vals (cached 2)))
          (do
            (put sub-cache sub-id [db-generation (cached 1) input-vals])
            (cached 1))
          (let [val (apply sub-fn input-vals)]
            (put sub-cache sub-id [db-generation val input-vals])
            val))))
    # Layer 2: depends on db
    (if (and cached (= (cached 0) db-generation))
      (cached 1)
      (let [val (sub-fn *current-db*)]
        (put sub-cache sub-id [db-generation val nil])
        val))))

(defn bump-generation
  "Called by Zig after :db fx executes."
  []
  (++ db-generation))

(defn set-current-db
  "Called by Zig before view evaluation to make db visible to subs."
  [db]
  (set *current-db* db))

(defn set-current-output
  "Called by Zig before view evaluation to set which output is being rendered."
  [name]
  (set *current-output* name))

(defn current-output
  "Returns the name of the output currently being rendered."
  []
  *current-output*)

# --- Internal handlers ---

# IPC reconnect: timer fires this event with the original connect spec.
(reg-event-handler :_ipc-reconnect
  (fn [cofx event]
    {:ipc {:connect (event 1)}}))

# --- Surfaces ---

(def- surface-registry
  "Registry: keyword → {:view fn :config table}"
  @{})

(defn reg-surface
  "Register a layer-shell surface.

   Forms:
     (reg-surface :name view-fn)
     (reg-surface :name {:layer :overlay :anchor {:top true} ...} view-fn)

   Config options:
     :per-output            — Create one surface per wl_output (default: false)
     :lazy                  — Don't auto-create at :init; await :surface :create fx
     :layer                 — :background, :bottom, :top, :overlay (default: :top)
     :anchor                — {:top true :left true ...} (default: all false)
     :width                 — Width in pixels (default: 0 = full output width)
     :height                — Height in pixels (default: 0 = auto-size to content)
     :margin                — {:top 0 :right 0 :bottom 0 :left 0}
     :exclusive-zone        — Exclusive zone (default: 0)
     :keyboard-interactivity — :none, :exclusive, :on-demand (default: :none)
     :input-region          — :default or :empty for click-through (default: :default)
     :namespace             — wl_layer_surface namespace (default: \"shoal\")

   At :init, Zig creates a surface per non-lazy registration. Lazy entries
   register the view but defer creation until a :surface :create fx fires."
  [name & args]
  (def [config view-fn] (match args
                          [vf]              [{} vf]
                          [cfg vf]          [cfg vf]))
  (put surface-registry name {:view view-fn :config config}))

(defn reg-view
  "Register a named view function without a surface config. The view is
   looked up when something else references the name — for example a
   :surface :create fx with overrides, or :render-to-shm into a buffer.
   Equivalent to (reg-surface name {:lazy true} view-fn)."
  [name view-fn]
  (put surface-registry name {:view view-fn :config {:lazy true}}))

(defn get-surface
  "Get surface registration by name. Returns {:view :config} or nil."
  [name]
  (get surface-registry name))

(defn list-surfaces
  "List all registered surface names."
  []
  (keys surface-registry))

(defn get-view-fn
  "Look up the view function registered for a surface name."
  [&opt name]
  (when name
    (when-let [entry (get surface-registry name)] (entry :view))))

(defn get-surface-config
  "Get surface config for Zig. Returns config table with defaults applied,
   or nil if name is not registered."
  [name]
  (when-let [entry (get surface-registry name)]
    (let [cfg (entry :config)]
      {:layer (get cfg :layer :top)
       :anchor (get cfg :anchor {})
       :width (get cfg :width 0)
       :height (get cfg :height 0)
       :margin (get cfg :margin {})
       :exclusive-zone (get cfg :exclusive-zone 0)
       :keyboard-interactivity (get cfg :keyboard-interactivity :none)
       :input-region (get cfg :input-region :default)
       :namespace (get cfg :namespace "shoal")
       :per-output (get cfg :per-output false)
       :lazy (get cfg :lazy false)})))

(defn has-surface?
  "Check if a surface is registered."
  [name]
  (truthy? (get surface-registry name)))

(defn get-all-surface-configs
  "Get configs for all non-lazy registered surfaces. Returns array of
   {:name :layer :anchor :per-output ...} for Zig to create at :init."
  []
  (def result @[])
  (each name (keys surface-registry)
    (let [cfg (get-surface-config name)]
      (unless (get cfg :lazy)
        (array/push result (merge {:name name} cfg)))))
  result)

# --- Theme ---

# Theme colors. Set by Zig from config or defaults.
# Default theme is Dracula dark.
(var- theme-data
  @{:bg [40 42 54 255]
    :surface [50 52 64 255]
    :overlay [60 62 74 255]
    :muted [98 114 164 255]
    :subtle [80 90 110 255]
    :text [248 248 242 255]
    :bright [255 255 255 255]
    :accent [139 233 253 255]
    :green [80 250 123 255]
    :yellow [241 250 140 255]
    :red [255 85 85 255]
    :orange [255 184 108 255]
    :cyan [139 233 253 255]
    :blue [189 147 249 255]
    :purple [189 147 249 255]
    :base02 [40 42 54 255]
    :base08 [255 85 85 255]
    :base09 [255 184 108 255]
    :base0A [241 250 140 255]
    :base0B [80 250 123 255]
    :base0C [139 233 253 255]
    :base0D [139 233 253 255]
    :base0E [189 147 249 255]})

(defn set-theme
  "Override theme colors. Called by Zig from config."
  [theme]
  (merge-into theme-data theme))

(defn theme
  "Get a theme color by key. Returns [r g b a]."
  [key]
  (get theme-data key (theme-data :text)))

# --- DB ---

(defn db
  "Get the current db value. Useful in event handlers."
  []
  *current-db*)

(defn db-get
  "Get a key from the db. Returns nil if key doesn't exist."
  [key]
  (get *current-db* key))
