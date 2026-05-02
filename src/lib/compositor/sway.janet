# sway — compositor integration for sway/i3
#
# Subscribes to sway events via `swaymsg -t subscribe -m` and populates
# the standard wm/* interface that modules consume.
#
# Uses the :spawn fx to run swaymsg and parse its JSON output line by line.

# -- Helpers --

(defn- sway/apply-workspaces [db data]
  (def wm (get db :wm {}))
  (def workspaces (if (indexed? data) data []))

  (def tags
    (seq [i :range [0 11]]
      (def ws (find |(= (get $ :num 0) i) workspaces))
      {:focused (and ws (get ws :focused false))
       :occupied (truthy? ws)}))

  (def focused-ws (find |(get $ :focused false) workspaces))
  (def layout (if focused-ws (get focused-ws :layout "") (get wm :layout "")))

  (put db :wm (merge wm {:tags tags :layout layout})))

(defn- sway/apply-window-event [db data]
  (def wm (get db :wm {}))
  (def change (get data :change ""))
  (def container (get data :container {}))

  (case change
    "focus"
    (put db :wm (merge wm {:title (get container :name "")
                           :app-id (get container :app_id "")}))

    "title"
    (if (get container :focused false)
      (put db :wm (merge wm {:title (get container :name "")}))
      db)

    "close"
    (if (= (get container :name "") (get wm :title ""))
      (put db :wm (merge wm {:title "" :app-id ""}))
      db)

    db))

# -- Event subscription via spawn --

(reg-event-handler :init
  (fn [cofx event]
    (if (os/getenv "SWAYSOCK")
      {:db (put (cofx :db) :wm {:connected false})
       :spawn {:cmd ["swaymsg" "-t" "subscribe" "-m"
                      "[\"workspace\",\"window\",\"mode\",\"binding\"]"]
               :event :sway/event
               :done :sway/disconnected}
       :dispatch-n [[:sway/poll-workspaces] [:sway/poll-tree]]}
      {:db (put (cofx :db) :wm {:connected false})})))

(reg-event-handler :sway/poll-workspaces
  (fn [cofx event]
    {:spawn {:cmd ["swaymsg" "-t" "get_workspaces"]
             :event :sway/workspaces-line
             :done :sway/workspaces-done}}))

(reg-event-handler :sway/workspaces-line
  (fn [cofx event]
    (def line (get event 1 ""))
    (try
      (do
        (def data (json/decode line true))
        (when (and data (indexed? data))
          {:db (sway/apply-workspaces (cofx :db) data)}))
      ([err] nil))))

(reg-event-handler :sway/workspaces-done
  (fn [cofx event] nil))

(reg-event-handler :sway/poll-tree
  (fn [cofx event]
    {:spawn {:cmd ["swaymsg" "-t" "get_tree"]
             :event :sway/tree-line
             :done :sway/tree-done}}))

(defn- sway/collect-windows [node]
  "Recursively collect leaf windows from a sway tree node."
  (def results @[])
  (def nodes (get node :nodes []))
  (def floating (get node :floating_nodes []))
  (each n (array/concat @[] nodes floating)
    (if (and (get n :pid) (not (get n :nodes)))
      (array/push results
        {:wid (get n :id 0)
         :app-id (get n :app_id "")
         :title (get n :name "")
         :focused (get n :focused false)
         :float (= (get n :type "") "floating_con")
         :fullscreen (= (get n :fullscreen_mode 0) 1)
         :visible (get n :visible true)
         :tag (get n :num 0)
         :row 0 :layout "" :column 0
         :column-total 0 :row-in-col 0 :row-in-col-total 0})
      (array/concat results (sway/collect-windows n))))
  results)

(reg-event-handler :sway/tree-line
  (fn [cofx event]
    (def line (get event 1 ""))
    (try
      (do
        (def data (json/decode line true))
        (when data
          (def windows (sway/collect-windows data))
          (def wm (get (cofx :db) :wm {}))
          (def focused (find |($ :focused) windows))
          {:db (put (cofx :db) :wm
                    (merge wm
                           {:windows windows
                            :connected true}
                           (when focused
                             {:title (get focused :title "")
                              :app-id (get focused :app-id "")})))}))
      ([err] nil))))

(reg-event-handler :sway/tree-done
  (fn [cofx event] nil))

# -- Live event stream --

(reg-event-handler :sway/event
  (fn [cofx event]
    (def line (get event 1 ""))
    (try
      (do
        (def data (json/decode line true))
        (when data
          (def change (get data :change ""))
          (cond
            # Workspace events
            (get data :current)
            {:dispatch-n [[:sway/poll-workspaces] [:sway/poll-tree]]}

            # Window events
            (get data :container)
            (do
              (def db (sway/apply-window-event (cofx :db) data))
              {:db db
               :dispatch [:sway/poll-tree]})

            # Binding events (treated as signals)
            (get data :binding)
            (let [cmd (get-in data [:binding :command] "")]
              (when (string/has-prefix? "nop signal " cmd)
                {:dispatch [:wm/signal (string/slice cmd 11)]})))))
      ([err] nil))))

(reg-event-handler :sway/disconnected
  (fn [cofx event]
    (eprintf "sway: subscription ended, reconnecting in 2s")
    {:db (put (cofx :db) :wm (merge (get (cofx :db) :wm {}) {:connected false}))
     :timer {:delay 2.0 :event [:init] :id :sway-reconnect}}))

# -- Actions --

(defn- sway/cmd [& args]
  {:exec {:cmd (string "swaymsg " (string/join args " "))}
   :dispatch-n [[:sway/poll-workspaces] [:sway/poll-tree]]})

(reg-event-handler :wm/focus-tag
  (fn [cofx event]
    (sway/cmd "workspace number" (string (get event 1 1)))))

(reg-event-handler :wm/toggle-tag
  (fn [cofx event]
    (sway/cmd "workspace number" (string (get event 1 1)))))

(reg-event-handler :wm/set-tag
  (fn [cofx event]
    (sway/cmd "move container to workspace number" (string (get event 1 1)))))

(reg-event-handler :wm/set-layout
  (fn [cofx event]
    (def layout (get event 1 "default"))
    (sway/cmd "layout" layout)))

(reg-event-handler :wm/cycle-layout
  (fn [cofx event]
    (sway/cmd "layout toggle split tabbed stacking")))

(reg-event-handler :wm/focus
  (fn [cofx event]
    (def dir (get event 1 "next"))
    (def sway-dir (case dir "next" "right" "prev" "left" dir))
    (sway/cmd "focus" sway-dir)))

(reg-event-handler :wm/close
  (fn [cofx event]
    (sway/cmd "kill")))

(reg-event-handler :wm/zoom
  (fn [cofx event]
    (sway/cmd "swap container with first")))

(reg-event-handler :wm/fullscreen
  (fn [cofx event]
    (sway/cmd "fullscreen toggle")))

(reg-event-handler :wm/float
  (fn [cofx event]
    (sway/cmd "floating toggle")))

(reg-event-handler :wm/dispatch-action
  (fn [cofx event]
    (def name (get event 1 ""))
    (sway/cmd name)))

(reg-event-handler :wm/focus-window
  (fn [cofx event]
    (def wid (get event 1 0))
    (sway/cmd (string "[con_id=" wid "]") "focus")))

(reg-event-handler :wm/query-actions
  (fn [cofx event] nil))

(reg-event-handler :wm/eval
  (fn [cofx event] nil))

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
