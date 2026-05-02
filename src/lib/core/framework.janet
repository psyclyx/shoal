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
                   (merge-into fx result)))
               # Replace with accumulated values
               (when (> (length dispatches) 0)
                 (put fx :dispatch-n dispatches)
                 (put fx :dispatch nil))
               (when (> (length timers) 0)
                 (put fx :timer timers))
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
  "Registry: sub-id keyword → {:fn sub-fn :deps [...] or nil}"
  @{})

(def- sub-cache
  "Cache: sub-id keyword → {:gen N :value V :inputs [...] or nil}"
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
    (put sub-registry sub-id {:fn sub-fn :deps deps-vec})

    [sub-fn]
    (put sub-registry sub-id {:fn sub-fn :deps nil})

    _ (error "reg-sub: expected (id fn) or (id deps fn)")))

(defn sub
  "Query a subscription value. Evaluates lazily with memoization."
  [sub-id]
  (def entry (get sub-registry sub-id))
  (unless entry (error (string "sub: unknown subscription " sub-id)))

  (def cached (get sub-cache sub-id))

  (if (entry :deps)
    # Layer 3: depends on other subs
    (let [input-vals (map sub (entry :deps))]
      (if (and cached (deep= input-vals (cached :inputs)))
        (cached :value)
        (let [val (apply (entry :fn) input-vals)]
          (put sub-cache sub-id {:gen db-generation
                                  :value val
                                  :inputs input-vals})
          val)))
    # Layer 2: depends on db
    (if (and cached (= (cached :gen) db-generation))
      (cached :value)
      (let [val ((entry :fn) *current-db*)]
        (put sub-cache sub-id {:gen db-generation :value val})
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

# --- Views ---

(var- *view-fn* nil)
(def- named-views
  "Registry: keyword → view-fn for named surfaces."
  @{})

(defn reg-view
  "Register a view function.

  One arity (default view, used by the primary surface):
    (reg-view view-fn)

  Two arities (named view, for additional surfaces):
    (reg-view :name view-fn)"
  [name-or-fn &opt view-fn]
  (if view-fn
    (put named-views name-or-fn view-fn)
    (set *view-fn* name-or-fn)))

(defn get-view-fn
  "Return a view function. With no args, returns the default view.
  With a keyword, returns the named view or nil."
  [&opt name]
  (if name
    (get named-views name)
    *view-fn*))

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
  "Register a surface with its view function and layer shell config.

   Two arities:
     (reg-surface :name view-fn) — named surface with defaults
     (reg-surface :name {:layer :overlay :anchor {:top true} ...} view-fn)

   Config options:
     :layer                 — :background, :bottom, :top, :overlay (default: :top)
     :anchor                — {:top true :left true ...} (default: all false = compositor chooses)
     :width                 — Width in pixels (default: 0 = full output width)
     :height                — Height in pixels (default: auto-sized from content)
     :margin                — {:top 0 :right 0 :bottom 0 :left 0}
     :exclusive-zone        — Exclusive zone for panel stacking (default: auto from height + margins)
     :keyboard-interactivity — :none, :exclusive, :on-demand (default: :none)

   The view-fn returns hiccup for this surface each frame.
   Call (reg-surface) during config load; Zig creates surfaces on :init."
  [name & args]
  (def [config view-fn] (match args
                          [vf]              [{} vf]
                          [cfg vf]          [cfg vf]))
  (put surface-registry name {:view view-fn :config config}))

(defn get-surface
  "Get surface registration by name. Returns {:view :config} or nil."
  [name]
  (get surface-registry name))

(defn list-surfaces
  "List all registered surface names."
  []
  (keys surface-registry))

(defn get-surface-config
  "Get surface config for Zig. Returns config table with defaults applied.
   Special name :default uses reg-view's default view if no surface registered."
  [name]
  (def entry (get surface-registry name))
  (if entry
    # Merge defaults with user config
    (let [cfg (entry :config)]
      {:layer (get cfg :layer :top)
       :anchor (get cfg :anchor {})
       :width (get cfg :width 0)
       :height (get cfg :height 0)
       :margin (get cfg :margin {})
       :exclusive-zone (get cfg :exclusive-zone 0)
       :keyboard-interactivity (get cfg :keyboard-interactivity :none)
       :namespace (get cfg :namespace "shoal")
       :view (entry :view)})
    # Default surface: use reg-view's default view
    (when (= name :default)
      {:layer :top
       :anchor {:bottom true :left true :right true}
       :width 0
       :height 0
       :margin {}
       :exclusive-zone 0
       :keyboard-interactivity :none
       :namespace "shoal"
       :view *view-fn*})))

(defn has-surface?
  "Check if a surface is registered (or :default has a view)."
  [name]
  (if (get surface-registry name)
    true
    (and (= name :default) *view-fn*)))

(defn get-all-surface-configs
  "Get all surface configs for init. Returns array of {:name :layer :anchor ...}.
   Always includes :default if a default view is registered."
  []
  (def result @[])
  # Check for default view
  (when *view-fn*
    (array/push result (merge {:name :default} (get-surface-config :default))))
  # Add all named surfaces
  (each name (keys surface-registry)
    (unless (= name :default)
      (array/push result (merge {:name name} (get-surface-config name)))))
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
