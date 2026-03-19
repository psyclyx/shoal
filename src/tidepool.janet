# tidepool — compositor IPC module
#
# Connects to tidepool's netrepl socket, subscribes to state events,
# parses JSON updates, and stores compositor state in the db under :tp.
#
# Event flow:
#   :init → :ipc connect → handshake (automatic via :handshake key)
#   :tp/connected → send subscription expression
#   :tp/recv [:output payload] → split JSON lines → apply to db
#   :tp/disconnected → mark disconnected in db

# -- Helpers (defined first — Janet uses early binding) --

(defn- tidepool-socket-path []
  (let [runtime (os/getenv "XDG_RUNTIME_DIR")
        display (os/getenv "WAYLAND_DISPLAY")]
    (when (and runtime display)
      (string runtime "/tidepool-" display))))

(defn- tp/apply-tags [db data]
  (def tp (get db :tp {}))
  (def outputs (get data :outputs []))
  (var occupied (get data :occupied []))
  (def existing-outputs (get tp :outputs []))

  # Build output tag state, preserving layout/viewport data from existing outputs
  (def out-list
    (seq [o :in outputs]
      (def tags (get o :tags []))
      (def focused (get o :focused false))
      (def name (get o :name ""))
      (def existing (find |(= ($ :name) name) existing-outputs))
      (merge (or existing {})
             {:name name
              :x (get o :x 0)
              :y (get o :y 0)
              :focused focused
              :tags (seq [i :range [0 11]]
                      {:focused (truthy? (some |(= $ i) tags))
                       :occupied (or (truthy? (some |(= $ i) tags))
                                     (truthy? (some |(= $ i) occupied)))})})))

  # Flat tags from focused output
  (def focused-out (find |($ :focused) out-list))
  (def flat-tags
    (if focused-out
      (focused-out :tags)
      (seq [i :range [0 11]]
        {:focused false
         :occupied (truthy? (some |(= $ i) occupied))})))

  (put db :tp (merge tp {:outputs out-list :tags flat-tags})))

(defn- tp/apply-layout [db data]
  (def tp (get db :tp {}))
  (def outputs (get data :outputs []))

  (def out-layouts
    (seq [o :in outputs]
      {:name (get o :name "")
       :x (get o :x 0)
       :y (get o :y 0)
       :w (get o :w 0)
       :h (get o :h 0)
       :focused (get o :focused false)
       :layout (get o :layout "")
       :active-row (get o :active-row 0)
       :viewport (get o :viewport {})}))

  # Merge layout info into existing outputs or use as-is
  (def existing (get tp :outputs []))
  (def merged
    (seq [ol :in out-layouts]
      (def existing-out
        (find |(and (= ($ :x) (ol :x)) (= ($ :y) (ol :y))) existing))
      (if existing-out
        (merge existing-out ol)
        ol)))

  # Flat layout from focused output
  (def focused-out (find |($ :focused) out-layouts))

  (put db :tp (merge tp {:outputs merged
                         :layout (if focused-out (focused-out :layout) (get tp :layout ""))})))

(defn- tp/apply-title [db data]
  (def tp (get db :tp {}))
  (put db :tp (merge tp {:title (get data :title "")
                         :app-id (get data :app-id "")})))

(defn- tp/apply-windows [db data]
  (def tp (get db :tp {}))
  (def windows
    (seq [w :in (get data :windows [])]
      {:wid (get w :wid 0)
       :app-id (get w :app-id "")
       :title (get w :title "")
       :tag (get w :tag 0)
       :focused (get w :focused false)
       :float (get w :float false)
       :fullscreen (get w :fullscreen false)
       :visible (get w :visible false)
       :row (get w :row 0)
       :layout (get w :layout "")
       :column (get-in w [:meta :column] 0)
       :column-total (get-in w [:meta :column-total] 0)
       :row-in-col (get-in w [:meta :row] 0)
       :row-in-col-total (get-in w [:meta :row-total] 0)}))
  (put db :tp (merge tp {:windows windows})))

(defn- tp/apply-signal [db data]
  (def tp (get db :tp {}))
  (put db :tp (merge tp {:signal {:name (get data :name "")}})))

(defn- tp/apply-event [db data]
  (match (data :event)
    "tags"    (tp/apply-tags db data)
    "layout"  (tp/apply-layout db data)
    "title"   (tp/apply-title db data)
    "windows" (tp/apply-windows db data)
    "signal"  (tp/apply-signal db data)
    _ db))

# -- Handler registrations --

(reg-event-handler :init
  (fn [cofx event]
    (def path (tidepool-socket-path))
    (if path
      {:db (put (cofx :db) :tp {:connected false})
       :ipc {:connect {:path path
                       :name :tidepool
                       :framing :netrepl
                       :handshake "\xFF{:name \"shoal\" :auto-flush true}"
                       :event :tp/recv
                       :connected :tp/connected
                       :disconnected :tp/disconnected
                       :reconnect 1.0}}}
      {:db (put (cofx :db) :tp {:connected false})})))

(reg-event-handler :tp/connected
  (fn [cofx event]
    {:db (put (cofx :db) :tp
              (merge (get (cofx :db) :tp {}) {:connected true}))
     :ipc {:send {:name :tidepool
                  :data "(ipc/watch-json [:tags :layout :title :windows :signal])\n"}}}))

(reg-event-handler :tp/disconnected
  (fn [cofx event]
    {:db (put (cofx :db) :tp {:connected false})}))

(reg-event-handler :tp/recv
  (fn [cofx event]
    (def msg-type (get event 1))
    (def payload (get event 2))
    (case msg-type
      :output
      (do
        (var db (cofx :db))
        (var dispatches @[])
        (each line (string/split "\n" payload)
          (when (> (length line) 0)
            (try
              (do
                (def data (json/decode line true))
                (when data
                  (set db (tp/apply-event db data))
                  # Signals become Janet events for other modules to handle
                  (when (= (get data :event) "signal")
                    (array/push dispatches
                      [:tp/signal (get data :name "")]))))
              ([err]
                (eprintf "tidepool: recv error: %s (line: %.80s)" (string err) line)))))
        (if (> (length dispatches) 0)
          {:db db :dispatch-n dispatches}
          {:db db}))

      :return
      # watch-json exited (write error or unexpected return) — the connection
      # is alive but tidepool's netrepl is waiting for a new command while
      # shoal waits for data, deadlocking the IPC. Disconnect and schedule
      # a fresh connection via :init to re-establish the watch.
      (do
        (eprintf "tidepool: watch ended (got :return), forcing reconnect")
        {:db (put (cofx :db) :tp {:connected false})
         :ipc {:disconnect {:name :tidepool}}
         :timer {:delay 1.0 :event [:init] :id :tp-reconnect}}))))

# -- Action helpers: send commands to tidepool --

(defn- tp/dispatch-cmd [& args]
  "Build an :ipc send fx that dispatches an action to tidepool.
  Args are stringified and passed to (ipc/dispatch ...)."
  {:ipc {:send {:name :tidepool
                :data (string "(ipc/dispatch "
                              (string/join (map |(string/format "%q" $) args) " ")
                              ")\n")}}})

# Common action event handlers
(reg-event-handler :tp/focus-tag
  (fn [cofx event]
    (tp/dispatch-cmd "focus-tag" (string (get event 1 1)))))

(reg-event-handler :tp/toggle-tag
  (fn [cofx event]
    (tp/dispatch-cmd "toggle-tag" (string (get event 1 1)))))

(reg-event-handler :tp/set-tag
  (fn [cofx event]
    (tp/dispatch-cmd "set-tag" (string (get event 1 1)))))

(reg-event-handler :tp/set-layout
  (fn [cofx event]
    (tp/dispatch-cmd "set-layout" (string (get event 1 "master-stack")))))

(reg-event-handler :tp/cycle-layout
  (fn [cofx event]
    (tp/dispatch-cmd "cycle-layout" (string (get event 1 "next")))))

(reg-event-handler :tp/focus
  (fn [cofx event]
    (tp/dispatch-cmd "focus" (string (get event 1 "next")))))

(reg-event-handler :tp/close
  (fn [cofx event]
    (tp/dispatch-cmd "close")))

(reg-event-handler :tp/zoom
  (fn [cofx event]
    (tp/dispatch-cmd "zoom")))

(reg-event-handler :tp/fullscreen
  (fn [cofx event]
    (tp/dispatch-cmd "fullscreen")))

(reg-event-handler :tp/float
  (fn [cofx event]
    (tp/dispatch-cmd "float")))

(reg-event-handler :tp/dispatch-action
  (fn [cofx event]
    (def name (get event 1 ""))
    (tp/dispatch-cmd name)))

# -- Subscriptions --

(reg-sub :tp (fn [db] (get db :tp {})))
(reg-sub :tp/connected [:tp] (fn [tp] (get tp :connected false)))
(reg-sub :tp/tags [:tp] (fn [tp] (get tp :tags [])))
(reg-sub :tp/outputs [:tp] (fn [tp] (get tp :outputs [])))
(reg-sub :tp/layout [:tp] (fn [tp] (get tp :layout "")))
(reg-sub :tp/title [:tp] (fn [tp] (get tp :title "")))
(reg-sub :tp/app-id [:tp] (fn [tp] (get tp :app-id "")))
(reg-sub :tp/windows [:tp] (fn [tp] (get tp :windows [])))
(reg-sub :tp/signal [:tp] (fn [tp] (get tp :signal nil)))
