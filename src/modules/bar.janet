# bar — status bar view
#
# Pure Janet view functions producing hiccup for a status bar.
# Layout: left (workspaces, scroll minimap) | center (title) | right (clock, cpu, mem, bat)
#
# Uses wm/* subscriptions (compositor-agnostic), clock.janet, sysinfo.janet.
# Theme colors from config (Base16) in 0-255 RGBA.

# -- Theme colors --

(def- bg         (theme :bg))
(def- surface    (theme :surface))
(def- overlay    (theme :overlay))
(def- muted      (theme :muted))
(def- subtle     (theme :subtle))
(def- text-color (theme :text))
(def- accent     (theme :accent))
(def- green      (theme :base0B))
(def- yellow     (theme :base0A))
(def- red        (theme :base08))

# -- Derived subscriptions --

(reg-sub :wm/focused-output [:wm/outputs]
  (fn [outputs] (find |(get $ "focused") outputs)))

(defn- this-output []
  "Return the wm output entry matching the surface being rendered."
  (def name (current-output))
  (def outputs (sub :wm/outputs))
  (when (and name outputs)
    (find |(= (get $ "name") name) outputs)))

# -- Helpers --

(defn- pill [& children]
  [:row {:pad [6 10] :bg surface :radius 6 :gap 6 :align-y :center}
    ;children])

(defn- pct-color [pct]
  (cond (>= pct 80) red (>= pct 50) yellow green))

(defn- dim-color [color &opt alpha]
  "Return color with overridden alpha (default 120)."
  [(color 0) (color 1) (color 2) (or alpha 120)])

(defn- fmt-gb [g]
  (let [w (math/floor g)
        f (math/floor (* 10 (- g w)))]
    (string w "." f)))

(defn- fmt-rate [bps]
  "Format bytes/sec as human-readable rate."
  (cond
    (>= bps 1073741824) (string/format "%.1fG" (/ bps 1073741824))
    (>= bps 104857600)  (string/format "%.0fM" (/ bps 1048576))
    (>= bps 1048576)    (string/format "%.1fM" (/ bps 1048576))
    (>= bps 102400)     (string/format "%.0fK" (/ bps 1024))
    (>= bps 1024)       (string/format "%.1fK" (/ bps 1024))
    (> bps 0)           (string/format "%.1fK" (/ bps 1024))
    "0K"))

# -- Workspace tags --

(defn- tag-view [idx tag]
  (def id (string "tag-" idx))
  (def hover (anim (keyword id "-hover")))
  (if (tag :focused)
    [:row {:id id :w 26 :h 26 :bg accent :radius 6 :align-x :center :align-y :center}
      [:text {:color bg} (string idx)]]
    [:row {:id id :w 26 :h 26 :bg [(muted 0) (muted 1) (muted 2) (math/floor (* hover 255))]
           :radius 6 :align-x :center :align-y :center}
      [:text {:color text-color} (string idx)]]))

(defn- workspaces-view []
  (def out (this-output))
  (def active-tag (when out (get out "tag" 0)))
  (def occupied (sub :wm/occupied-tags))
  [:row {:gap 4 :align-y :center :pad [4 6] :bg surface :radius 6}
    ;(seq [i :range [1 10]
           :let [focused (= i active-tag)
                 occ (or focused (truthy? (some |(= $ i) (or occupied []))))]
           :when occ]
       (tag-view i {:focused focused :occupied occ}))])

# -- Scroll minimap --

(defn- minimap-tree
  "Recursively render a column tree node into hiccup."
  [node w h]
  (def node-type (get node "type" "leaf"))
  (def focused (get node "focused" false))
  (def color (if focused accent overlay))
  (if (= node-type "leaf")
    [:row {:w w :h h :bg color :radius 1}]
    # Container: split children along the orientation axis
    (let [children (get node "children" [])
          n (length children)
          orient (get node "orientation" "vertical")
          vertical (= orient "vertical")
          gap 1
          total-gap (* gap (max 0 (- n 1)))
          avail (- (if vertical h w) total-gap)
          child-size (max 2 (math/floor (/ avail (max 1 n))))]
      [(if vertical :col :row) {:gap gap :w w :h h}
        ;(seq [c :in children]
           (minimap-tree c
             (if vertical w child-size)
             (if vertical child-size h)))])))

(defn- scroll-minimap []
  (def out (this-output))
  (when out
    (def columns (get out "columns" []))
    (when (> (length columns) 0)
      (def minimap-h 24)
      (def total-w (sum (map |(get $ "width" 1) columns)))
      (def minimap-w (min 200 (max 60 (* minimap-h (max 1 (* total-w 1.5))))))
      (def scale (/ minimap-w (max 0.01 total-w)))

      [:row {:gap 1 :align-y :center :pad [4 6] :bg surface :radius 6}
        ;(seq [col :in columns
               :let [col-w (get col "width" 1)
                     scaled-w (max 3 (math/floor (* col-w scale)))
                     tree (get col "tree")]]
           (if tree
             (minimap-tree tree scaled-w minimap-h)
             # Fallback for compositors that don't send tree data
             (let [n-leaves (get col "leaves" 1)
                   is-focused (get col "focused" false)
                   color (if is-focused accent overlay)]
               (if (<= n-leaves 1)
                 [:row {:w scaled-w :h minimap-h :bg color :radius 2}]
                 [:col {:gap 1 :w scaled-w :h minimap-h}
                   ;(seq [_ :range [0 n-leaves]
                          :let [row-h (max 2 (math/floor (/ (- minimap-h (- n-leaves 1)) n-leaves)))]]
                      [:row {:w scaled-w :h row-h :bg color :radius 1}])]))))])))

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
            [:text {:color muted} app-id])
          [:text {:color text-color} title]]
        [:text {:id "title" :color subtle} ""]))
    [:text {:id "title" :color subtle} ""]))

# -- Right-side modules --

(defn- interp-values [history pending anim-id]
  "Build sparkline values with an interpolated pending point."
  (def t (anim anim-id))
  (if (and pending (> (length history) 0))
    (let [last-val (last history)
          live (+ last-val (* t (- pending last-val)))]
      [;history live])
    history))

(defn- spark-fill [values]
  "Fill boundary: everything except the last (live) segment is confirmed."
  (def n (length values))
  (if (> n 2) (/ (- n 2) (- n 1)) 1))

(defn- cpu-view []
  (def pct (sub :cpu/percent))
  (def history (sub :cpu/history))
  (def pending (sub :cpu/pending))
  (def values (interp-values history pending :cpu/interp))
  (def color (pct-color pct))
  (pill
    [:area {:w 60 :h 24 :values values
            :color (dim-color color)
            :color2 (dim-color color 60)
            :fill (spark-fill values)
            :smooth true}]
    [:col {:gap 1}
      [:text {:color color :size 16} (string (math/floor pct) "%")]
      [:text {:color subtle :size 11} "cpu"]]))

(defn- mem-view []
  (def mem (sub :mem))
  (def history (sub :mem/history))
  (def pending (sub :mem/pending))
  (def values (interp-values history pending :mem/interp))
  (def pct (get mem :percent 0))
  (def used (get mem :used-mb 0))
  (def color (pct-color pct))
  (pill
    [:area {:w 60 :h 24 :values values
            :color (dim-color color)
            :color2 (dim-color color 60)
            :fill (spark-fill values)
            :smooth true}]
    [:col {:gap 1}
      [:text {:color color :size 14}
        (string (fmt-gb (/ used 1024)) "G")]
      [:text {:color subtle :size 11} "mem"]]))

(defn- bat-view []
  (def bat (sub :bat))
  (when (bat :present)
    (def pct (get bat :percent 0))
    (def charging (bat :charging))
    (def color (cond charging accent (< pct 20) red (< pct 50) yellow green))
    (pill
      [:text {:color color}
        (string (if charging "⚡" "") (math/floor pct) "%")]
      [:text {:color subtle :size 11} "bat"])))

(defn- disk-view []
  (def disk (sub :disk))
  (def pct (get disk :percent 0))
  (def color (pct-color pct))
  (pill
    [:row {:w 50 :h 8 :bg overlay :radius 4}
      [:row {:w [:percent (/ pct 100)] :h :grow :bg color :radius 4}]]
    [:col {:gap 1}
      [:text {:color color :size 13}
        (string (fmt-gb (get disk :used-gb 0)) "/" (fmt-gb (get disk :total-gb 0)) "G")]
      [:text {:color subtle :size 11} "disk"]]))

(defn- net-view []
  (def net (sub :net))
  (def rx (get net :rx-rate 0))
  (def tx (get net :tx-rate 0))
  (def iface (get net :iface ""))
  (def ipv4 (get net :ipv4 ""))
  [:row {:pad [6 10] :bg surface :radius 6 :gap 6 :align-y :center}
    [:col {:gap 2}
      [:text {:color green :size 12} (string "↓" (fmt-rate rx))]
      [:text {:color accent :size 12} (string "↑" (fmt-rate tx))]]
    (when (> (length ipv4) 0)
      [:text {:color muted :size 11} ipv4])])

(defn- audio-view []
  (def audio (sub :audio))
  (def pct (get audio :percent 0))
  (def muted-flag (get audio :muted false))
  (def color (cond muted-flag red (>= pct 100) yellow accent))
  [:row {:id "audio" :pad [6 10] :bg surface :radius 6 :gap 6 :align-y :center}
    [:text {:color color}
      (string (if muted-flag "M " "") (math/floor pct) "%")]
    [:text {:color subtle :size 11} "vol"]])

(defn- clock-view []
  (pill
    [:col {:gap 1 :align-x :right}
      [:text {:color text-color} (sub :clock/time)]
      [:text {:color subtle :size 12} (sub :clock/date)]]))

# -- Root bar view --

(defn- launcher-trigger []
  [:row {:id "launcher" :pad [6 10] :bg surface :radius 6 :align-y :center}
    [:text {:color subtle} "⌕"]])

(defn- bar-view []
  [:row {:w :grow :h :fit :pad [0 8] :bg bg :radius 8 :align-y :center}
    # Left: workspaces + minimap + launcher
    [:row {:w :grow :gap 6 :align-y :center}
      (workspaces-view)
      (scroll-minimap)
      (launcher-trigger)]
    # Center: title
    [:row {:w :grow :align-x :center :align-y :center}
      (title-view)]
    # Right: system info
    [:row {:w :grow :gap 6 :align-x :right :align-y :center}
      (audio-view)
      (net-view)
      (cpu-view)
      (mem-view)
      (disk-view)
      (bat-view)
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
      # Scroll on workspace tags: switch tags
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

      # Scroll on title: cycle focus
      (= id "title")
      {:dispatch [:wm/focus (if (= dir "up") "prev" "next")]})))

(reg-view bar-view)
