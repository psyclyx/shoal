# decorator — window decoration rendering module
#
# Receives decoration lifecycle events from tidepool, renders title bars
# and tab bars using the angled design language, exports pixel buffers
# via SHM for tidepool to attach to decoration surfaces.

# -- Theme --

(def- SLANT 0.30)
(def- DECO-H 28)

(def- bg         (theme :bg))
(def- surface    (theme :surface))
(def- overlay    (theme :overlay))
(def- muted      (theme :muted))
(def- text-color (theme :text))
(def- bright     (theme :bright))
(def- accent     (theme :accent))

(defn- blend-bg [color &opt a]
  (def alpha (/ (or a 100) 255))
  (def inv (- 1 alpha))
  [(math/floor (+ (* (color 0) alpha) (* (bg 0) inv)))
   (math/floor (+ (* (color 1) alpha) (* (bg 1) inv)))
   (math/floor (+ (* (color 2) alpha) (* (bg 2) inv)))
   255])

(def- focused-bg (blend-bg accent 80))
(def- normal-bg  (blend-bg surface 120))
(def- tab-bg     (blend-bg muted 60))

# -- Subscriptions --

(reg-sub :decorations (fn [db] (get db :decorations {})))

# -- Tree helpers --

(defn- active-leaf-title [tree]
  "Walk the tree following active indices to find the visible leaf's title."
  (when tree
    (if (= (get tree "type") "leaf")
      (get tree "title" "")
      (let [children (get tree "children" [])
            active (get tree "active" 0)]
        (when (< active (length children))
          (active-leaf-title (children active)))))))

# -- Decoration views --

(def- sep-w (math/ceil (* SLANT DECO-H)))

(defn- deco-title-bar [w h title focused]
  [:row {:w w :h h :bg (if focused focused-bg normal-bg)
         :align-y :center :pad [0 12 0 8]}
    [:text {:color (if focused bright text-color) :size 14}
      (or title "")]])

(defn- deco-tab-bar [w h children active focused]
  (def n (length children))
  (def total-seps (* sep-w (max 0 (- n 1))))
  (def tab-w (if (> n 0) (math/floor (/ (- w total-seps) n)) w))
  (def elements @[])
  (for i 0 n
    (def is-active (= i active))
    (def child (children i))
    # Slanted separator between tabs
    (when (> i 0)
      (array/push elements
        [:row {:w sep-w :h h :bg (blend-bg muted 40) :skew SLANT}]))
    (array/push elements
      [:row {:w tab-w :h h
             :bg (cond is-active focused-bg
                       focused tab-bg
                       normal-bg)
             :align-y :center :pad [0 8 0 6]}
        [:text {:color (if is-active bright text-color) :size 13}
          (or (active-leaf-title child) "")]]))
  [:row {:w w :h h :gap 0} ;elements])

(defn- deco-view-for [id]
  "Return a view function for a specific decoration."
  (fn []
    (def decos (sub :decorations))
    (def deco (get decos id))
    (when deco
      (def w (get deco "width" 100))
      (def h (get deco "height" DECO-H))
      (def tree (get deco "tree"))
      (def focused (get deco "focused" false))
      (def is-tabbed (and tree
                          (= (get tree "type") "container")
                          (= (get tree "mode") "tabbed")))
      (if is-tabbed
        (deco-tab-bar w h (get tree "children" []) (get tree "active" 0) focused)
        (deco-title-bar w h (active-leaf-title tree) focused)))))

# -- SHM path helper --

(defn- shm-path [id]
  (string "/dev/shm/shoal-deco-" id))

# -- Event handlers --

(reg-event-handler :decoration/create
  (fn [cofx event]
    (def params (get event 1))
    (def id (get params "id"))
    (def db (cofx :db))
    (def decos (get db :decorations {}))
    # Store decoration state
    (def new-decos (merge decos {id params}))
    # Register a named view for this decoration
    (reg-view (keyword (string "deco-" id)) (deco-view-for id))
    {:db (put db :decorations new-decos)
     :render-to-shm {:view (keyword (string "deco-" id))
                      :width (get params "width" 100)
                      :height (get params "height" DECO-H)
                      :path (shm-path id)}}))

(reg-event-handler :decoration/update
  (fn [cofx event]
    (def params (get event 1))
    (def id (get params "id"))
    (def db (cofx :db))
    (def decos (get db :decorations {}))
    (when-let [existing (get decos id)]
      (def updated (merge existing params))
      {:db (put db :decorations (merge decos {id updated}))
       :render-to-shm {:view (keyword (string "deco-" id))
                        :width (get updated "width" 100)
                        :height (get updated "height" DECO-H)
                        :path (shm-path id)}})))

(reg-event-handler :decoration/resize
  (fn [cofx event]
    (def params (get event 1))
    (def id (get params "id"))
    (def db (cofx :db))
    (def decos (get db :decorations {}))
    (when-let [existing (get decos id)]
      (def updated (merge existing params))
      {:db (put db :decorations (merge decos {id updated}))
       :render-to-shm {:view (keyword (string "deco-" id))
                        :width (get params "width" 100)
                        :height (get params "height" DECO-H)
                        :path (shm-path id)}})))

(reg-event-handler :decoration/destroy
  (fn [cofx event]
    (def params (get event 1))
    (def id (get params "id"))
    (def db (cofx :db))
    (def decos (get db :decorations {}))
    (def new-decos (table/clone decos))
    (put new-decos id nil)
    {:db (put db :decorations new-decos)}))

# After FBO render completes, send the buffer to tidepool
(reg-event-handler :shm-rendered
  (fn [cofx event]
    (def spec (get event 1))
    (when spec
      # Extract the decoration ID from the view name (:deco-N → N)
      (def view-name (get spec :view))
      (when (nil? view-name) (break))
      (def view-str (string view-name))
      (when (not (string/has-prefix? "deco-" view-str)) (break))
      (def id-str (string/slice view-str 5))
      (def id (scan-number id-str))
      (when (nil? id) (break))
      (def width (get spec :width 0))
      (def height (get spec :height 0))
      (def path (get spec :path ""))
      {:ipc {:send {:name :tidepool
                    :data (string (json/encode
                            {"jsonrpc" "2.0" "id" 0
                             "method" "decoration:buffer"
                             "params" {"id" id
                                       "shm-path" path
                                       "width" width
                                       "height" height
                                       "stride" (* width 4)
                                       "format" "argb8888"}})
                          "\n")}}})))
