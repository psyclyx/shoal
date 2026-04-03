# tidepool — compositor integration for tidepool WM
#
# Connects to tidepool's JSON-RPC IPC socket, subscribes to state events,
# and stores compositor state in the db under :wm.
#
# Populates the standard wm/* interface that modules consume.

# -- Helpers --

(defn- tidepool-socket-path []
  (let [runtime (os/getenv "XDG_RUNTIME_DIR")
        display (os/getenv "WAYLAND_DISPLAY")]
    (when (and runtime display)
      (string runtime "/tidepool-ipc-" display))))

(defn- tp/apply-state [db data]
  (def wm (get db :wm {}))
  (def outputs (get data "outputs" []))
  (def occupied (get data "occupied-tags" []))
  (def focused-data (get data "focused" {}))

  (def focused-out (find |($ "focused") outputs))

  # Build per-output list
  (def out-list
    (seq [o :in outputs]
      {"name" (get o "name" "")
       "x" (get o "x" 0) "y" (get o "y" 0)
       "w" (get o "w" 0) "h" (get o "h" 0)
       "focused" (get o "focused" false)
       "tag" (get o "tag" 0)
       "columns" (get o "columns" [])
       "camera" (get o "camera" 0)
       "insert-mode" (get o "insert-mode" "sibling")}))

  # Build flat tags array (indices 0-10) for workspace view
  (def focused-tags @{})
  (each o outputs (put focused-tags (get o "tag" 0) true))
  (def flat-tags
    (seq [i :range [0 11]]
      {:focused (truthy? (focused-tags i))
       :occupied (or (truthy? (focused-tags i))
                     (truthy? (some |(= $ i) occupied)))}))

  (put db :wm
    (merge wm
      {:outputs out-list
       :tags flat-tags
       :title (get focused-data "title" "")
       :app-id (get focused-data "app-id" "")
       :occupied-tags occupied})))

(defn- tp/apply-title [db data]
  (def wm (get db :wm {}))
  (put db :wm (merge wm {:title (get data "title" "")
                          :app-id (get data "app-id" "")})))

(defn- tp/handle-notification [db method params]
  (case method
    "state" (tp/apply-state db params)
    "focus:changed" (tp/apply-title db params)
    db))

# -- IPC connection --

(reg-event-handler :init
  (fn [cofx event]
    (def path (tidepool-socket-path))
    (if path
      {:db (put (cofx :db) :wm {:connected false})
       :ipc {:connect {:path path
                       :name :tidepool
                       :framing :line
                       :event :tp/recv
                       :connected :tp/connected
                       :disconnected :tp/disconnected
                       :reconnect 1.0}}}
      {:db (put (cofx :db) :wm {:connected false})})))

(reg-event-handler :tp/connected
  (fn [cofx event]
    {:db (put (cofx :db) :wm
              (merge (get (cofx :db) :wm {}) {:connected true}))
     :ipc {:send {:name :tidepool
                  :data (string (json/encode {"jsonrpc" "2.0" "id" 1
                                              "method" "watch"
                                              "params" {"events" ["state" "focus:changed"
                                                                  "window:new" "window:closed"]}})
                                "\n")}}}))

(reg-event-handler :tp/disconnected
  (fn [cofx event]
    {:db (put (cofx :db) :wm {:connected false})}))

(reg-event-handler :tp/recv
  (fn [cofx event]
    (def payload (get event 1))
    (when payload
      (var db (cofx :db))
      (try
        (do
          (def data (json/decode payload))
          (when data
            (def method (get data "method"))
            (def params (get data "params"))
            (when (and method params)
              (set db (tp/handle-notification db method params)))))
        ([err]
          (eprintf "tidepool: recv error: %s" (string err))))
      {:db db})))

# -- Action dispatch --

(defn- tp/dispatch-action [name &opt args]
  (def params {"name" name})
  (when args (put params "args" args))
  {:ipc {:send {:name :tidepool
                :data (string (json/encode {"jsonrpc" "2.0" "id" 0
                                            "method" "action"
                                            "params" params})
                              "\n")}}})

(reg-event-handler :wm/focus-tag
  (fn [cofx event]
    (tp/dispatch-action "focus-tag" [(string (get event 1 1))])))

(reg-event-handler :wm/close
  (fn [cofx event]
    (tp/dispatch-action "close-focused")))

(reg-event-handler :wm/focus
  (fn [cofx event]
    (def dir (get event 1 "next"))
    (tp/dispatch-action (if (= dir "prev") "focus-left" "focus-right"))))

(reg-event-handler :wm/dispatch-action
  (fn [cofx event]
    (def name (get event 1 ""))
    (tp/dispatch-action name)))

# -- Subscriptions --

(reg-sub :wm (fn [db] (get db :wm {})))
(reg-sub :wm/connected [:wm] (fn [wm] (get wm :connected false)))
(reg-sub :wm/tags [:wm] (fn [wm] (get wm :tags [])))
(reg-sub :wm/outputs [:wm] (fn [wm] (get wm :outputs [])))
(reg-sub :wm/occupied-tags [:wm] (fn [wm] (get wm :occupied-tags [])))
(reg-sub :wm/title [:wm] (fn [wm] (get wm :title "")))
(reg-sub :wm/app-id [:wm] (fn [wm] (get wm :app-id "")))
