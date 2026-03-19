# tidepool — compositor integration for tidepool WM
#
# Connects to tidepool's netrepl socket, subscribes to state events,
# parses JSON updates, and stores compositor state in the db under :wm.
#
# Populates the standard wm/* interface that modules consume.

# -- Helpers --

(defn- tidepool-socket-path []
  (let [runtime (os/getenv "XDG_RUNTIME_DIR")
        display (os/getenv "WAYLAND_DISPLAY")]
    (when (and runtime display)
      (string runtime "/tidepool-" display))))

(defn- tp/apply-tags [db data]
  (def wm (get db :wm {}))
  (def outputs (get data :outputs []))
  (var occupied (get data :occupied []))
  (def existing-outputs (get wm :outputs []))

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

  (def focused-out (find |($ :focused) out-list))
  (def flat-tags
    (if focused-out
      (focused-out :tags)
      (seq [i :range [0 11]]
        {:focused false
         :occupied (truthy? (some |(= $ i) occupied))})))

  (put db :wm (merge wm {:outputs out-list :tags flat-tags})))

(defn- tp/apply-layout [db data]
  (def wm (get db :wm {}))
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

  (def existing (get wm :outputs []))
  (def merged
    (seq [ol :in out-layouts]
      (def existing-out
        (find |(and (= ($ :x) (ol :x)) (= ($ :y) (ol :y))) existing))
      (if existing-out
        (merge existing-out ol)
        ol)))

  (def focused-out (find |($ :focused) out-layouts))

  (put db :wm (merge wm {:outputs merged
                         :layout (if focused-out (focused-out :layout) (get wm :layout ""))})))

(defn- tp/apply-title [db data]
  (def wm (get db :wm {}))
  (put db :wm (merge wm {:title (get data :title "")
                         :app-id (get data :app-id "")})))

(defn- tp/apply-windows [db data]
  (def wm (get db :wm {}))
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
  (put db :wm (merge wm {:windows windows})))

(defn- tp/apply-signal [db data]
  (def wm (get db :wm {}))
  (put db :wm (merge wm {:signal {:name (get data :name "")}})))

(defn- tp/apply-event [db data]
  (match (data :event)
    "tags"    (tp/apply-tags db data)
    "layout"  (tp/apply-layout db data)
    "title"   (tp/apply-title db data)
    "windows" (tp/apply-windows db data)
    "signal"  (tp/apply-signal db data)
    _ db))

# -- IPC connection --

(reg-event-handler :init
  (fn [cofx event]
    (def path (tidepool-socket-path))
    (if path
      {:db (put (cofx :db) :wm {:connected false})
       :ipc {:connect {:path path
                       :name :tidepool
                       :framing :netrepl
                       :handshake "\xFF{:name \"shoal\" :auto-flush true}"
                       :event :tp/recv
                       :connected :tp/connected
                       :disconnected :tp/disconnected
                       :reconnect 1.0}}
       :dispatch [:tp-cmd/init]}
      {:db (put (cofx :db) :wm {:connected false})})))

(reg-event-handler :tp-cmd/init
  (fn [cofx event]
    (def path (tidepool-socket-path))
    (when path
      {:ipc {:connect {:path path
                       :name :tp-cmd
                       :framing :netrepl
                       :handshake "\xFF{:name \"shoal-cmd\"}"
                       :event :tp-cmd/recv
                       :connected :tp-cmd/connected
                       :disconnected :tp-cmd/disconnected
                       :reconnect 1.0}}})))

(reg-event-handler :tp-cmd/connected
  (fn [cofx event]
    {:dispatch [:wm/query-actions]}))

(reg-event-handler :tp-cmd/disconnected
  (fn [cofx event]
    (eprintf "tp-cmd: command channel disconnected")))

(reg-event-handler :tp-cmd/recv
  (fn [cofx event]
    (def msg-type (get event 1))
    (def payload (get event 2))
    (when (= msg-type :return)
      (try
        (do
          (def data (json/decode payload true))
          (when (and data (indexed? data)
                     (> (length data) 0)
                     (get (first data) :name))
            (def action-items
              (map |(do
                (def key (get $ :key ""))
                (def label (string ($ :name)
                                   (when (> (length key) 0) (string "  [" key "]"))
                                   (when (get $ :desc)
                                     (string " — " ($ :desc)))))
                {:label label :kind :action :action-name ($ :name)}) data))
            {:db (-> (cofx :db)
                     (put :launcher/actions data)
                     (put :launcher/action-items action-items))}))
        ([err] nil)))))

(reg-event-handler :tp/connected
  (fn [cofx event]
    {:db (put (cofx :db) :wm
              (merge (get (cofx :db) :wm {}) {:connected true}))
     :ipc {:send {:name :tidepool
                  :data "(ipc/watch-json [:tags :layout :title :windows :signal])\n"}}}))

(reg-event-handler :tp/disconnected
  (fn [cofx event]
    {:db (put (cofx :db) :wm {:connected false})}))

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
                  (when (= (get data :event) "signal")
                    (array/push dispatches
                      [:wm/signal (get data :name "")]))))
              ([err]
                (eprintf "tidepool: recv error: %s (line: %.80s)" (string err) line)))))
        (if (> (length dispatches) 0)
          {:db db :dispatch-n dispatches}
          {:db db}))

      :return
      (do
        (eprintf "tidepool: watch ended (got :return), forcing reconnect")
        {:db (put (cofx :db) :wm {:connected false})
         :ipc {:disconnect {:name :tidepool}}
         :timer {:delay 1.0 :event [:init] :id :tp-reconnect}}))))

# -- Action dispatch --

(defn- tp/dispatch-cmd [& args]
  (def cmd (string "(ipc/dispatch "
                   (string/join (map |(string/format "%q" $) args) " ")
                   ")\n"))
  {:ipc {:send {:name :tp-cmd
                :data cmd}}})

(reg-event-handler :wm/focus-tag
  (fn [cofx event]
    (tp/dispatch-cmd "focus-tag" (string (get event 1 1)))))

(reg-event-handler :wm/toggle-tag
  (fn [cofx event]
    (tp/dispatch-cmd "toggle-tag" (string (get event 1 1)))))

(reg-event-handler :wm/set-tag
  (fn [cofx event]
    (tp/dispatch-cmd "set-tag" (string (get event 1 1)))))

(reg-event-handler :wm/set-layout
  (fn [cofx event]
    (tp/dispatch-cmd "set-layout" (string (get event 1 "master-stack")))))

(reg-event-handler :wm/cycle-layout
  (fn [cofx event]
    (tp/dispatch-cmd "cycle-layout" (string (get event 1 "next")))))

(reg-event-handler :wm/focus
  (fn [cofx event]
    (tp/dispatch-cmd "focus" (string (get event 1 "next")))))

(reg-event-handler :wm/close
  (fn [cofx event]
    (tp/dispatch-cmd "close")))

(reg-event-handler :wm/zoom
  (fn [cofx event]
    (tp/dispatch-cmd "zoom")))

(reg-event-handler :wm/fullscreen
  (fn [cofx event]
    (tp/dispatch-cmd "fullscreen")))

(reg-event-handler :wm/float
  (fn [cofx event]
    (tp/dispatch-cmd "float")))

(reg-event-handler :wm/dispatch-action
  (fn [cofx event]
    (def name (get event 1 ""))
    (tp/dispatch-cmd name)))

(reg-event-handler :wm/focus-window
  (fn [cofx event]
    (def wid (get event 1 0))
    {:ipc {:send {:name :tp-cmd
                  :data (string "(ipc/dispatch \"focus-window\" " wid ")\n")}}}))

(reg-event-handler :wm/query-actions
  (fn [cofx event]
    (when (get-in (cofx :db) [:wm :connected])
      {:ipc {:send {:name :tp-cmd
                     :data "(ipc/list-actions)\n"}}})))

(reg-event-handler :wm/eval
  (fn [cofx event]
    (def expr (get event 1 ""))
    (when (> (length expr) 0)
      {:ipc {:send {:name :tp-cmd :data (string expr "\n")}}})))

# -- Subscriptions --

(reg-sub :wm (fn [db] (get db :wm {})))
(reg-sub :wm/connected [:wm] (fn [wm] (get wm :connected false)))
(reg-sub :wm/tags [:wm] (fn [wm] (get wm :tags [])))
(reg-sub :wm/outputs [:wm] (fn [wm] (get wm :outputs [])))
(reg-sub :wm/layout [:wm] (fn [wm] (get wm :layout "")))
(reg-sub :wm/title [:wm] (fn [wm] (get wm :title "")))
(reg-sub :wm/app-id [:wm] (fn [wm] (get wm :app-id "")))
(reg-sub :wm/windows [:wm] (fn [wm] (get wm :windows [])))
(reg-sub :wm/signal [:wm] (fn [wm] (get wm :signal nil)))
