# bar — status bar view
#
# Powerline-style bottom bar: each right-side module is a coloured
# parallelogram section, adjacent sections tessellate along their `/`
# slants. Icons are drawn natively from primitive shapes (rects, tris,
# parallelograms) — no font glyphs.

# -- Layout constants --

(def- SLANT 0.30)   # horizontal shift per unit of height for /-dividers
(def- BAR-H 38)
(def- SEC-H BAR-H)

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
(def- blue       (theme :base0D))
(def- purple     (theme :base0E))

(defn- tint [color &opt a]
  "Colour with overridden alpha (0-255)."
  [(color 0) (color 1) (color 2) (or a 100)])

(defn- blend-bg [color &opt a]
  "Pre-blend color with bar bg at given alpha. Returns opaque.
   Adjacent opaque sections eliminate z-fighting at skew overlaps."
  (def alpha (/ (or a 100) 255))
  (def inv (- 1 alpha))
  [(math/floor (+ (* (color 0) alpha) (* (bg 0) inv)))
   (math/floor (+ (* (color 1) alpha) (* (bg 1) inv)))
   (math/floor (+ (* (color 2) alpha) (* (bg 2) inv)))
   255])

(def- audio-bg (blend-bg purple))
(def- net-bg   (blend-bg cyan))
(def- cpu-bg   (blend-bg yellow))
(def- mem-bg   (blend-bg green))
(def- disk-bg  (blend-bg orange))
(def- bat-bg   (blend-bg red))
(def- clock-bg (blend-bg blue))
(def- launcher-bg (blend-bg muted 80))

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

(defn- fmt-gb [g]
  (let [w (math/floor g) f (math/floor (* 10 (- g w)))]
    (string w "." f)))

(defn- fmt3 [val suffix]
  "Format value + suffix as exactly 4 characters: X.X or  XX or XXX + suffix."
  (if (>= val 10)
    (string/format "%3.0f%s" val suffix)
    (string/format "%3.1f%s" val suffix)))

(defn- fmt-rate [bps]
  (cond
    (>= bps 1073741824) (fmt3 (/ bps 1073741824) "G")
    (>= bps 1048576)    (fmt3 (/ bps 1048576) "M")
    (> bps 0)           (fmt3 (/ bps 1024) "K")
    "0.0K"))


# -- Section primitive --

(defn- section [color & children]
  "Powerline section: parallelogram bg with /-slanted edges.
   Minimal left padding so fill-bars can sit at the left edge."
  [:row {:h SEC-H :pad [0 12 0 2] :align-y :center :gap 8
         :bg color :skew SLANT}
    ;children])

(def- MIN-BAR-H 2)


# -- Fill bar --

(defn- fill-bar [color pct]
  "Left-edge fill indicator. Wraps with bright color above 100%."
  (def clamped (max 0 pct))
  (def wrapped (> clamped 100))
  (def bar-pct (if wrapped (% clamped 100) clamped))
  (def bar-pct (if (and wrapped (= bar-pct 0)) 100 bar-pct))
  (def bar-color (if wrapped bright color))
  (def fill-h (max MIN-BAR-H (math/round (* SEC-H (/ (min 100 bar-pct) 100)))))
  [:row {:w 8 :h SEC-H :align-y :bottom}
    [:row {:w 8 :h fill-h :bg bar-color :skew SLANT}]])

# -- Icons --
# All shapes lean with the / via skew to match the section aesthetic.

(def- ICON-SKEW SLANT)

(defn- icon-cpu [color]
  "Chip: angled outline with die."
  [:row {:w 16 :h 16 :bg (tint color 60) :skew ICON-SKEW
         :align-x :center :align-y :center}
    [:row {:w 6 :h 6 :bg color}]])

(defn- icon-mem [color]
  "RAM DIMMs: two skewed bars, staggered height."
  [:row {:gap 2 :align-y :bottom}
    [:row {:w 6 :h 16 :bg color :skew ICON-SKEW}]
    [:row {:w 6 :h 12 :bg (tint color 160) :skew ICON-SKEW}]])

(defn- icon-disk [color]
  "Drive: angled body with indicator."
  [:row {:w 16 :h 12 :bg (tint color 60) :skew ICON-SKEW
         :pad [0 0 0 3] :align-y :bottom}
    [:row {:w 3 :h 3 :bg color :radius 2}]])

(defn- icon-battery [color]
  "Battery: angled body with terminal nub."
  [:row {:gap 0 :align-y :center}
    [:row {:w 16 :h 10 :bg (tint color 60) :skew ICON-SKEW}]
    [:row {:w 3 :h 5 :bg color}]])

(defn- icon-net-rx [color]
  "Download: arrow with angled shaft."
  [:col {:gap 1 :align-x :center}
    [:tri {:w 10 :h 6 :dir :up :color color}]
    [:row {:w 3 :h 6 :bg color :skew ICON-SKEW}]])

(defn- icon-net-tx [color]
  "Upload: angled shaft with arrow."
  [:col {:gap 1 :align-x :center}
    [:row {:w 3 :h 6 :bg color :skew ICON-SKEW}]
    [:tri {:w 10 :h 6 :dir :down :color color}]])

(defn- icon-audio [color]
  "Speaker: back plate + cone widening right."
  [:row {:gap 0 :align-y :center}
    [:row {:w 5 :h 9 :bg color :skew ICON-SKEW}]
    [:tri {:w 10 :h 18 :dir :left :color color}]])

(defn- icon-launcher [color]
  "Grid: 2x2 angled dots."
  [:col {:gap 3}
    [:row {:gap 3}
      [:row {:w 5 :h 5 :bg color :skew ICON-SKEW}]
      [:row {:w 5 :h 5 :bg color :skew ICON-SKEW}]]
    [:row {:gap 3}
      [:row {:w 5 :h 5 :bg color :skew ICON-SKEW}]
      [:row {:w 5 :h 5 :bg color :skew ICON-SKEW}]]])

# -- Workspace tags --

(defn- tag-view [idx tag]
  (def id (string "tag-" idx))
  (def hover (anim (keyword id "-hover")))
  (def focused (tag :focused))
  [:row {:id id :pad [4 10] :align-x :center :align-y :center
         :bg (if focused accent [(muted 0) (muted 1) (muted 2) (math/floor (* hover 200))])
         :skew SLANT}
    [:text {:color (if focused bg text-color) :size 16} (string idx)]])

(defn- workspaces-view []
  (def out (this-output))
  (def active-tag (when out (get out "tag" 0)))
  (def occupied (sub :wm/occupied-tags))
  [:row {:gap 0 :align-y :center}
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
    [:row {:w w :h h :bg color :skew SLANT}]
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
      [:row {:gap 0 :align-y :center}
        ;(seq [col :in columns
               :let [sw (max 3 (math/floor (* (get col "width" 1) scale)))
                     tree (get col "tree")]]
           (if tree
             (minimap-tree tree sw mh)
             (let [nl (get col "leaves" 1)
                   fc (get col "focused" false)
                   c (if fc accent overlay)]
               (if (<= nl 1)
                 [:row {:w sw :h mh :bg c :skew SLANT}]
                 [:col {:gap 1 :w sw :h mh}
                   ;(seq [_ :range [0 nl]
                          :let [rh (max 2 (math/floor (/ (- mh (- nl 1)) nl)))]]
                      [:row {:w sw :h rh :bg c :skew SLANT}])]))))])))

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

# -- Right-side section views --

(defn- cpu-view []
  (def pct (sub :cpu/percent))
  (def cpu (sub :cpu))
  (def history (or (get cpu :history) @[]))
  (def scroll (max 0 (min 0.99 (/ (- (os/clock :monotonic) (get cpu :tick-clock 0)) 2.0))))
  (def color (pct-color pct))
  (section cpu-bg
    [:row {:pad [0 0 0 10]}
      [:area {:w 70 :h 32 :values history
              :color (tint color 180) :thickness 3.0 :scroll scroll}]]
    [:col {:gap 0}
      [:text {:color color :size 18} (string (math/floor pct) "%")]
      [:text {:color subtle :size 12} "cpu"]]))

(defn- mem-view []
  (def mem (sub :mem))
  (def pct (get mem :percent 0))
  (section mem-bg
    (fill-bar green pct)
    (icon-mem green)))

(defn- disk-view []
  (def disk (sub :disk))
  (def pct (get disk :percent 0))
  (section disk-bg
    (fill-bar orange pct)
    (icon-disk orange)))

(defn- net-view []
  (def net (sub :net))
  (def rx (get net :rx-rate 0))
  (def tx (get net :tx-rate 0))
  (def rx-norm (or (get net :rx-norm) @[]))
  (def tx-norm (or (get net :tx-norm) @[]))
  (def scroll (max 0 (min 0.99 (- (os/clock :monotonic) (get net :prev-clock 0)))))
  (section net-bg
    [:row {:pad [0 0 0 10]}
      [:area {:w 70 :h 32 :values rx-norm :values2 tx-norm
              :color (tint green 180) :color2 (tint cyan 180)
              :mirror true :thickness 3.0 :scroll scroll}]]
    [:col {:gap 1}
      [:text {:color green :size 13} (string "↓" (fmt-rate rx))]
      [:text {:color cyan :size 13} (string "↑" (fmt-rate tx))]]))

(defn- audio-view []
  (def audio (sub :audio))
  (def pct (get audio :percent 0))
  (def muted-flag (get audio :muted false))
  (def color (cond muted-flag red (>= pct 100) yellow purple))
  (section audio-bg
    (fill-bar color pct)
    (icon-audio color)))

(defn- bat-view []
  (def bat (sub :bat))
  (when (bat :present)
    (def pct (get bat :percent 0))
    (def charging (bat :charging))
    (def color (cond charging green (< pct 20) red (< pct 50) orange accent))
    (section bat-bg
      (fill-bar color pct)
      (icon-battery color)
      [:text {:color color :size 19} (string (math/floor pct) "%")])))

(defn- clock-view []
  # Left-align text so left edges follow the / slant.
  # Per-line left pad = SLANT * (SEC-H - y_center) + margin.
  (def margin 6)
  (def time-pad (+ margin (math/floor (* SLANT (- SEC-H 7)))))
  (def dow-pad  (+ margin (math/floor (* SLANT (- SEC-H 19)))))
  (def date-pad (+ margin (math/floor (* SLANT (- SEC-H 31)))))
  [:row {:h SEC-H :pad [0 16 0 0] :align-y :center :gap 0
         :bg clock-bg :skew SLANT}
    [:col {:align-x :left :gap 0}
      [:row {:pad [0 0 0 time-pad]}
        [:text {:color bright :size 17} (sub :clock/time)]]
      [:row {:pad [0 0 0 dow-pad]}
        [:text {:color text-color :size 12} (sub :clock/dow)]]
      [:row {:pad [0 0 0 date-pad]}
        [:text {:color subtle :size 12} (sub :clock/date)]]]])

# -- Root --

(defn- launcher-view []
  (section launcher-bg
    [:row {:id "launcher" :align-y :center}
      (icon-launcher bright)]))

(defn- bar-view []
  [:row {:w :grow :h BAR-H :bg bg :align-y :center}
    # Left
    [:row {:w :grow :gap 10 :pad [0 0 0 0] :align-y :center}
      (launcher-view)
      [:row {:pad [0 10] :gap 10 :align-y :center}
        (workspaces-view)
        (scroll-minimap)]]
    # Center
    [:row {:w :grow :align-x :center :align-y :center}
      (title-view)]
    # Right: powerline chain, no gap between sections
    [:row {:w :grow :align-x :right :align-y :center :gap 0}
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
