# bar — status bar view
#
# Flat bottom bar, edge-to-edge.
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

(defn- interp-values [history pending anim-id]
  "Append a live interpolated point to history."
  (if (and pending (> (length history) 0))
    (let [t (anim anim-id)
          last-val (last history)
          live (+ last-val (* t (- pending last-val)))]
      [;history live])
    history))

(defn- normalize-to [history scale]
  "Normalize history to 0-1 against a fixed scale with headroom."
  (if (or (nil? history) (= 0 (length history)))
    []
    (let [s (max 1 (* scale 1.25))]
      (map |(min 1 (/ $ s)) history))))

(defn- sep []
  [:row {:w 1 :h 24 :bg overlay}])

# -- Workspace tags --

(defn- tag-view [idx tag]
  (def id (string "tag-" idx))
  (def hover (anim (keyword id "-hover")))
  (def focused (tag :focused))
  [:row {:id id :pad [4 10] :align-x :center :align-y :center
         :bg (if focused accent [(muted 0) (muted 1) (muted 2) (math/floor (* hover 200))])}
    [:text {:color (if focused bg text-color) :size 16} (string idx)]])

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
      (def mh 22)
      (def tw (sum (map |(get $ "width" 1) columns)))
      (def mw (min 180 (max 50 (* mh (max 1 (* tw 1.5))))))
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
            [:text {:color muted :size 15} app-id])
          [:text {:color text-color :size 18} title]]
        [:text {:id "title" :color subtle :size 18} ""]))
    [:text {:id "title" :color subtle :size 18} ""]))

# -- Right-side modules --

(defn- cpu-view []
  (def pct (sub :cpu/percent))
  (def history (sub :cpu/history))
  (def pending (sub :cpu/pending))
  (def values (interp-values history pending :cpu/interp))
  (def color (pct-color pct))
  [:row {:gap 8 :align-y :center}
    [:area {:w 80 :h 32 :values values
            :color (dim color 140) :grid true :smooth true}]
    [:col {:gap 0}
      [:text {:color color :size 18} (string (math/floor pct) "%")]
      [:text {:color subtle :size 12} "cpu"]]])

(defn- mem-view []
  (def mem (sub :mem))
  (def pct (get mem :percent 0))
  (def used (get mem :used-mb 0))
  (def total (get mem :total-mb 0))
  (def color (pct-color pct))
  [:col {:gap 3}
    [:row {:gap 6 :align-y :center}
      [:text {:color color :size 16}
        (string (fmt-gb (/ used 1024)) "/" (fmt-gb (/ total 1024)) "G")]
      [:text {:color subtle :size 12} "mem"]]
    [:row {:w 90 :h 6 :bg surface}
      [:row {:w [:percent (/ pct 100)] :h :grow :bg color}]]])

(defn- disk-view []
  (def disk (sub :disk))
  (def pct (get disk :percent 0))
  (def color (pct-color pct))
  [:col {:gap 3}
    [:row {:gap 6 :align-y :center}
      [:text {:color color :size 16}
        (string (fmt-gb (get disk :used-gb 0)) "/" (fmt-gb (get disk :total-gb 0)) "G")]
      [:text {:color subtle :size 12} "disk"]]
    [:row {:w 90 :h 6 :bg surface}
      [:row {:w [:percent (/ pct 100)] :h :grow :bg color}]]])

(defn- net-view []
  (def net (sub :net))
  (def rx (get net :rx-rate 0))
  (def tx (get net :tx-rate 0))
  (def peak (get net :peak 1024))
  (def rx-hist (sub :net/rx-history))
  (def tx-hist (sub :net/tx-history))
  (def rx-pending (get net :rx-pending))
  (def tx-pending (get net :tx-pending))
  (def rx-vals (interp-values (or rx-hist @[]) rx-pending :net/interp))
  (def tx-vals (interp-values (or tx-hist @[]) tx-pending :net/interp))
  (def rx-norm (normalize-to rx-vals peak))
  (def tx-norm (normalize-to tx-vals peak))
  [:row {:gap 8 :align-y :center}
    [:area {:w 80 :h 32 :values rx-norm :values2 tx-norm
            :color (dim green 140) :color2 (dim cyan 140)
            :mirror true :grid true :smooth true}]
    [:col {:gap 1}
      [:text {:color green :size 13} (string "↓" (fmt-rate rx))]
      [:text {:color cyan :size 13} (string "↑" (fmt-rate tx))]]])

(defn- audio-view []
  (def audio (sub :audio))
  (def pct (get audio :percent 0))
  (def muted-flag (get audio :muted false))
  (def color (cond muted-flag red (>= pct 100) yellow purple))
  [:row {:id "audio" :align-y :center :gap 6}
    [:text {:color color :size 18}
      (string (if muted-flag "M " "") (math/floor pct) "%")]
    [:text {:color subtle :size 12} "vol"]])

(defn- bat-view []
  (def bat (sub :bat))
  (when (bat :present)
    (def pct (get bat :percent 0))
    (def charging (bat :charging))
    (def color (cond charging green (< pct 20) red (< pct 50) orange accent))
    [:row {:align-y :center :gap 6}
      [:text {:color color :size 18}
        (string (if charging "+" "") (math/floor pct) "%")]
      [:text {:color subtle :size 12} "bat"]]))

(defn- clock-view []
  [:col {:gap 1 :align-x :right}
    [:text {:color bright :size 18} (sub :clock/time)]
    [:text {:color subtle :size 13} (sub :clock/date)]])

# -- Root --

(defn- launcher-trigger []
  [:row {:id "launcher" :align-y :center}
    [:text {:color subtle :size 18} "⌕"]])

(defn- intersperse [separator items]
  "Insert separator between non-nil items."
  (def result @[])
  (each item items
    (when item
      (when (> (length result) 0)
        (array/push result (separator)))
      (array/push result item)))
  result)

(defn- bar-view []
  (def right-modules
    (intersperse sep
      [(audio-view)
       (net-view)
       (cpu-view)
       (mem-view)
       (disk-view)
       (bat-view)
       (clock-view)]))
  [:row {:w :grow :h :fit :pad [8 0] :bg bg :align-y :center :gap 14}
    # Left
    [:row {:w :grow :gap 10 :pad [0 8] :align-y :center}
      (workspaces-view)
      (scroll-minimap)
      (launcher-trigger)]
    # Center
    [:row {:w :grow :align-x :center :align-y :center}
      (title-view)]
    # Right
    [:row {:w :grow :gap 14 :pad [0 8] :align-x :right :align-y :center}
      ;right-modules]])

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
