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

(def- skew-pad (math/ceil (* SLANT DECO-H)))

(defn- deco-title-bar [w h title focused]
  [:row {:w w :h h :bg (if focused focused-bg normal-bg)
         :align-y :center :pad [0 12 0 8]}
    [:text {:color (if focused bright text-color) :size 14}
      (or title "")]])

(defn- deco-tab-bar [w h children active focused]
  (def n (length children))
  (def tab-w (if (> n 0) (math/floor (/ w n)) w))
  [:row {:w w :h h :gap 0 :bg normal-bg}
    ;(seq [i :range [0 n]
           :let [is-active (= i active)
                 child (children i)]]
      [:row {:w tab-w :h h :skew SLANT
             :bg (if is-active focused-bg tab-bg)
             :align-y :center :pad [0 8 0 skew-pad]}
        [:text {:color (if is-active bright text-color) :size 13}
          (or (active-leaf-title child) "")]])])

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

# -- Event handlers --

(defn- render-decoration [id params]
  "Trigger FBO render into the shared mmap buffer."
  {:render-to-shm {:view (keyword (string "deco-" id))
                    :width (get params "width" 100)
                    :height (get params "height" DECO-H)
                    :stride (get params "stride")
                    :path (get params "shm-path" "")}})

(reg-event-handler :decoration/create
  (fn [cofx event]
    (def params (get event 1))
    (def id (get params "id"))
    (def db (cofx :db))
    (def decos (get db :decorations {}))
    (def new-decos (merge decos {id params}))
    (reg-view (keyword (string "deco-" id)) (deco-view-for id))
    (merge {:db (put db :decorations new-decos)}
           (render-decoration id params))))

(reg-event-handler :decoration/update
  (fn [cofx event]
    (def params (get event 1))
    (def id (get params "id"))
    (def db (cofx :db))
    (def decos (get db :decorations {}))
    (when-let [existing (get decos id)]
      (def updated (merge existing params))
      (merge {:db (put db :decorations (merge decos {id updated}))}
             (render-decoration id updated)))))

(reg-event-handler :decoration/resize
  (fn [cofx event]
    (def params (get event 1))
    (def id (get params "id"))
    (def db (cofx :db))
    (def decos (get db :decorations {}))
    (when-let [existing (get decos id)]
      # Resize changes the shared buffer — tidepool recreates the memfd.
      # The new shm-path comes in the resize params.
      (def updated (merge existing params))
      (merge {:db (put db :decorations (merge decos {id updated}))}
             (render-decoration id updated)))))

(reg-event-handler :decoration/destroy
  (fn [cofx event]
    (def params (get event 1))
    (def id (get params "id"))
    (def db (cofx :db))
    (def decos (get db :decorations {}))
    (def new-decos (table/clone decos))
    (put new-decos id nil)
    {:db (put db :decorations new-decos)}))

# After FBO render completes, signal tidepool to re-commit the surface
(reg-event-handler :shm-rendered
  (fn [cofx event]
    (def spec (get event 1))
    (when spec
      (def view-name (get spec :view))
      (when (nil? view-name) (break))
      (def view-str (string view-name))
      (when (not (string/has-prefix? "deco-" view-str)) (break))
      (def id-str (string/slice view-str 5))
      (def id (scan-number id-str))
      (when (nil? id) (break))
      {:ipc {:send {:name :tidepool
                    :data (string (json/encode
                            {"jsonrpc" "2.0" "id" 0
                             "method" "decoration:ready"
                             "params" {"id" id}})
                          "\n")}}})))
