# shoal — reactive event loop registration API
#
# Registries: event handlers, cofx injectors, fx executors, subscriptions.
# All tables are module-level. Zig reads these directly to dispatch events.

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
  When cofx keys are declared, those cofx injectors run before the handler."
  [event-id & args]
  (match args
    [cofx-keys handler-fn]
    (put handlers event-id {:fn handler-fn :cofx cofx-keys})

    [handler-fn]
    (put handlers event-id {:fn handler-fn :cofx []})

    _ (error "reg-event-handler: expected (id fn) or (id cofx-keys fn)")))

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
  "Look up a handler entry by event-id. Returns {:fn ... :cofx ...} or nil."
  [event-id]
  (get handlers event-id))

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

(defn clear-sub-cache
  "Clear all cached subscription values."
  []
  (eachk k sub-cache (put sub-cache k nil)))

# --- View ---

(var- *view-fn* nil)

(defn reg-view
  "Register the root view function. Called with no args, returns hiccup tree."
  [view-fn]
  (set *view-fn* view-fn))

(defn get-view-fn
  "Return the registered root view function, or nil."
  []
  *view-fn*)

# --- Internal handlers ---

# IPC reconnect: timer fires this event with the original connect spec.
(reg-event-handler :_ipc-reconnect
  (fn [cofx event]
    {:ipc {:connect (event 1)}}))
