# bar — status bar view
#
# Flat bottom bar. No pills, no rounding — edge-to-edge.
# Uses wm/* subscriptions (compositor-agnostic), clock.janet, sysinfo.janet.

# -- Theme colors --

(def- bg         (theme :bg))
(def- surface    (theme :surface))
(def- overlay    (theme :overlay))
(def- muted      (theme :muted))
(def- subtle     (theme :subtle))
(def- text-color (theme :text))
(def- bright     (theme :bright))
(def- accent     (theme :accent))
(def- green      (theme :base0B))
(def- yellow     (theme :base0A))
(def- red        (theme :base08))
(def- orange     (theme :base09))
(def- cyan       (theme :base0C))
(def- purple     (theme :base0E))

# -- Subscriptions --

(reg-sub :wm/focused-output [:wm/outputs]
  (fn [outputs] (find |(get $ "focused") outputs)))

(defn- this-output []
  (def name (current-output))
  (def outputs (sub :wm/outputs))
  (when (and name outputs)
    (find |(= (get $ "name") name) outputs)))

# -- Helpers --

(defn- pct-color [pct]
  (cond (>= pct 80) red (>= pct 50) yellow green))

(defn- dim [color &opt a]
  [(color 0) (color 1) (color 2) (or a 100)])

(defn- fmt-gb [g]
  (let [w (math/floor g) f (math/floor (* 10 (- g w)))]
    (string w "." f)))

(defn- fmt-rate [bps]
  (cond
    (>= bps 1073741824) (string/format "%.1fG" (/ bps 1073741824))
    (>= bps 104857600)  (string/format "%.0fM" (/ bps 1048576))
    (>= bps 1048576)    (string/format "%.1fM" (/ bps 1048576))
    (>= bps 102400)     (string/format "%.0fK" (/ bps 1024))
    (>= bps 1024)       (string/format "%.1fK" (/ bps 1024))
    (> bps 0)           (string/format "%.1fK" (/ bps 1024))
    "0K"))

(defn- normalize-history [history scale]
  "Normalize history to 0-1. Scale is the max value to normalize against."
  (if (or (nil? history) (= 0 (length history)))
    []
    (map |(min 1 (/ $ (max 1 scale))) history)))

(defn- sep []
  [:row {:w 1 :h 20 :bg overlay}])

# -- Workspace tags --

(defn- tag-view [idx tag]
  (def id (string "tag-" idx))
  (def hover (anim (keyword id "-hover")))
  (def focused (tag :focused))
  [:row {:id id :pad [2 8] :align-x :center :align-y :center
         :bg (if focused accent [(muted 0) (muted 1) (muted 2) (math/floor (* hover 200))])}
    [:text {:color (if focused bg text-color) :size 14} (string idx)]])

(defn- workspaces-view []
  (def out (this-output))
  (def active-tag (when out (get out "tag" 0)))
  (def occupied (sub :wm/occupied-tags))
  [:row {:gap 1 :align-y :center}
    ;(seq [i :range [1 10]
           :let [focused (= i active-tag)
                 occ (or focused (truthy? (some |(= $ i) (or occupied []))))]
           :when occ]
       (tag-view i {:focused focused :occupied occ}))])

# -- Scroll minimap --

(defn- minimap-tree [node w h]
  (def focused (get node "focused" false))
  (def color (if focused accent overlay))
  (if (= (get node "type" "leaf") "leaf")
    [:row {:w w :h h :bg color}]
    (let [children (get node "children" [])
          n (length children)
          vertical (= (get node "orientation" "vertical") "vertical")
          gap 1
          avail (- (if vertical h w) (* gap (max 0 (- n 1))))
          csz (max 2 (math/floor (/ avail (max 1 n))))]
      [(if vertical :col :row) {:gap gap :w w :h h}
        ;(seq [c :in children]
           (minimap-tree c (if vertical w csz) (if vertical csz h)))])))

(defn- scroll-minimap []
  (def out (this-output))
  (when out
    (def columns (get out "columns" []))
    (when (> (length columns) 0)
      (def mh 18)
      (def tw (sum (map |(get $ "width" 1) columns)))
      (def mw (min 160 (max 40 (* mh (max 1 (* tw 1.5))))))
      (def scale (/ mw (max 0.01 tw)))
      [:row {:gap 1 :align-y :center}
        ;(seq [col :in columns
               :let [sw (max 3 (math/floor (* (get col "width" 1) scale)))
                     tree (get col "tree")]]
           (if tree
             (minimap-tree tree sw mh)
             (let [nl (get col "leaves" 1)
                   fc (get col "focused" false)
                   c (if fc accent overlay)]
               (if (<= nl 1)
                 [:row {:w sw :h mh :bg c}]
                 [:col {:gap 1 :w sw :h mh}
                   ;(seq [_ :range [0 nl]
                          :let [rh (max 2 (math/floor (/ (- mh (- nl 1)) nl)))]]
                      [:row {:w sw :h rh :bg c}])]))))])))

# -- Title --

(defn- title-view []
  (def out (this-output))
  (def is-focused (and out (get out "focused" false)))
  (if is-focused
    (do
      (def title (sub :wm/title))
      (def app-id (sub :wm/app-id))
      (if (and title (> (length title) 0))
        [:row {:id "title" :gap 8 :align-y :center}
          (when (and app-id (> (length app-id) 0) (not= app-id title))
            [:text {:color muted :size 13} app-id])
          [:text {:color text-color} title]]
        [:text {:id "title" :color subtle} ""]))
    [:text {:id "title" :color subtle} ""]))

# -- Right-side modules --

(defn- cpu-view []
  (def pct (sub :cpu/percent))
  (def history (sub :cpu/history))
  (def color (pct-color pct))
  [:row {:gap 6 :align-y :center}
    [:area {:w 80 :h 28 :values history
            :color (dim color) :smooth true}]
    [:col {:gap 0}
      [:text {:color color :size 16} (string (math/floor pct) "%")]
      [:text {:color subtle :size 10} "cpu"]]])

(defn- mem-view []
  (def mem (sub :mem))
  (def pct (get mem :percent 0))
  (def used (get mem :used-mb 0))
  (def total (get mem :total-mb 0))
  (def color (pct-color pct))
  [:col {:gap 2}
    [:row {:gap 4 :align-y :center}
      [:text {:color color :size 14}
        (string (fmt-gb (/ used 1024)) "/" (fmt-gb (/ total 1024)) "G")]
      [:text {:color subtle :size 10} "mem"]]
    [:row {:w 80 :h 6 :bg surface}
      [:row {:w [:percent (/ pct 100)] :h :grow :bg color}]]])

(defn- disk-view []
  (def disk (sub :disk))
  (def pct (get disk :percent 0))
  (def color (pct-color pct))
  [:col {:gap 2}
    [:row {:gap 4 :align-y :center}
      [:text {:color color :size 14}
        (string (fmt-gb (get disk :used-gb 0)) "/" (fmt-gb (get disk :total-gb 0)) "G")]
      [:text {:color subtle :size 10} "disk"]]
    [:row {:w 80 :h 6 :bg surface}
      [:row {:w [:percent (/ pct 100)] :h :grow :bg color}]]])

(defn- net-view []
  (def net (sub :net))
  (def rx (get net :rx-rate 0))
  (def tx (get net :tx-rate 0))
  (def peak (get net :peak 1024))
  (def rx-norm (normalize-history (sub :net/rx-history) peak))
  (def tx-norm (normalize-history (sub :net/tx-history) peak))
  [:row {:gap 6 :align-y :center}
    [:area {:w 80 :h 28 :values rx-norm :values2 tx-norm
            :color (dim green) :color2 (dim cyan)
            :smooth true}]
    [:col {:gap 1}
      [:text {:color green :size 11} (string "↓" (fmt-rate rx))]
      [:text {:color cyan :size 11} (string "↑" (fmt-rate tx))]]])

(defn- audio-view []
  (def audio (sub :audio))
  (def pct (get audio :percent 0))
  (def muted-flag (get audio :muted false))
  (def color (cond muted-flag red (>= pct 100) yellow purple))
  [:row {:id "audio" :align-y :center :gap 4}
    [:text {:color color :size 16}
      (string (if muted-flag "M " "") (math/floor pct) "%")]
    [:text {:color subtle :size 10} "vol"]])

(defn- bat-view []
  (def bat (sub :bat))
  (when (bat :present)
    (def pct (get bat :percent 0))
    (def charging (bat :charging))
    (def color (cond charging green (< pct 20) red (< pct 50) orange accent))
    [:row {:align-y :center :gap 4}
      [:text {:color color :size 16}
        (string (if charging "+" "") (math/floor pct) "%")]
      [:text {:color subtle :size 10} "bat"]]))

(defn- clock-view []
  [:col {:gap 0 :align-x :right}
    [:text {:color bright :size 16} (sub :clock/time)]
    [:text {:color subtle :size 11} (sub :clock/date)]])

# -- Root --

(defn- launcher-trigger []
  [:row {:id "launcher" :align-y :center}
    [:text {:color subtle :size 16} "⌕"]])

(defn- bar-view []
  [:row {:w :grow :h :fit :pad [6 14] :bg bg :align-y :center :gap 12}
    # Left
    [:row {:w :grow :gap 10 :align-y :center}
      (workspaces-view)
      (scroll-minimap)
      (launcher-trigger)]
    # Center
    [:row {:w :grow :align-x :center :align-y :center}
      (title-view)]
    # Right
    [:row {:w :grow :gap 12 :align-x :right :align-y :center}
      (audio-view)
      (sep)
      (net-view)
      (sep)
      (cpu-view)
      (sep)
      (mem-view)
      (sep)
      (disk-view)
      (sep)
      (bat-view)
      (sep)
      (clock-view)]])

# -- Pointer handlers --

(reg-event-handler :pointer-enter
  (fn [cofx event]
    (def id (get event 1 ""))
    (when (string/has-prefix? "tag-" id)
      {:anim {:id (keyword id "-hover") :to 1 :duration 0.15 :easing :ease-out-cubic}})))

(reg-event-handler :pointer-leave
  (fn [cofx event]
    (def id (get event 1 ""))
    (when (string/has-prefix? "tag-" id)
      {:anim {:id (keyword id "-hover") :to 0 :duration 0.2 :easing :ease-out-cubic}})))

(reg-event-handler :click
  (fn [cofx event]
    (def id (get event 1 ""))
    (cond
      (string/has-prefix? "tag-" id)
      (let [tag (scan-number (string/slice id 4))]
        (when tag {:dispatch [:wm/focus-tag tag]}))

      (= id "launcher")
      {:dispatch [:launcher/open]}

      (= id "title")
      {:dispatch [:launcher/open "@"]})))

(reg-event-handler :scroll
  (fn [cofx event]
    (def dir (get event 1 ""))
    (def id (get event 2 ""))
    (cond
      (string/has-prefix? "tag-" id)
      (let [tags (get (get (cofx :db) :wm {}) :tags [])
            current (do (var found 1)
                     (for i 1 10
                       (def tag (get tags i))
                       (when (and tag (tag :focused))
                         (set found i)
                         (break)))
                     found)
            next (if (= dir "up")
                   (max 1 (- current 1))
                   (min 9 (+ current 1)))]
        (when (not= next current)
          {:dispatch [:wm/focus-tag next]}))

      (= id "title")
      {:dispatch [:wm/focus (if (= dir "up") "prev" "next")]})))

(reg-view bar-view)
