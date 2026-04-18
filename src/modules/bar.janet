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
(def- minimap-bg  (blend-bg surface 120))

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

# -- Sparkline bars --
# 15 parallelogram bars sampling a smooth Catmull-Rom curve over
# time-stamped data. The curve scrolls left at a constant rate;
# bars update every frame by resampling at their time positions.

(def- N-BARS 15)
(def- SBAR-W 4)
(def- SBAR-GAP 2)
(def- ln10 (math/log 10))

(defn- log10 [x] (/ (math/log x) ln10))

(defn- catmull-rom [p0 p1 p2 p3 t]
  "Catmull-Rom spline interpolation between p1 and p2 at parameter t."
  (let [t2 (* t t)
        t3 (* t2 t)]
    (* 0.5
       (+ (* 2 p1)
          (* (+ (- p0) p2) t)
          (* (+ (* 2 p0) (* -5 p1) (* 4 p2) (- p3)) t2)
          (* (+ (- p0) (* 3 p1) (* -3 p2) p3) t3)))))

(defn- sample-curve [samples t key]
  "Sample the smooth curve at time t using Catmull-Rom interpolation."
  (let [n (length samples)]
    (when (= n 0) (break 0))
    (when (= n 1) (break (get (samples 0) key 0)))
    # Find i1: rightmost sample with t_sample <= t
    (var i1 0)
    (for i 0 n
      (when (<= (get (samples i) :t 0) t)
        (set i1 i)))
    (let [i0 (max 0 (- i1 1))
          i2 (min (- n 1) (+ i1 1))
          i3 (min (- n 1) (+ i1 2))
          s1 (samples i1)
          s2 (samples i2)
          dt (- (get s2 :t 0) (get s1 :t 0))
          frac (if (> dt 0.001)
                 (max 0 (min 1 (/ (- t (get s1 :t 0)) dt)))
                 0)]
      (max 0 (catmull-rom
        (get (samples i0) key 0)
        (get s1 key 0)
        (get s2 key 0)
        (get (samples i3) key 0)
        frac)))))

(defn- sparkline-values [samples now window key]
  "Compute N-BARS values by sampling the smooth curve across a time window."
  (let [step (/ window (- N-BARS 1))]
    (seq [i :range [0 N-BARS]
          :let [t (- now (* (- (- N-BARS 1) i) step))]]
      (sample-curve samples t key))))

(defn- lerp-color [c1 c2 t]
  [(math/floor (+ (* (c1 0) (- 1 t)) (* (c2 0) t)))
   (math/floor (+ (* (c1 1) (- 1 t)) (* (c2 1) t)))
   (math/floor (+ (* (c1 2) (- 1 t)) (* (c2 2) t)))
   (math/floor (+ (* (get c1 3 255) (- 1 t)) (* (get c2 3 255) t)))])

(defn- sparkline-bars [values color-fn]
  "Render N-BARS parallelogram bars with varying heights and colors."
  [:row {:h SEC-H :align-y :bottom :gap SBAR-GAP}
    ;(seq [i :range [0 N-BARS]
           :let [v (max 0 (min 1 (get values i 0)))
                 h (max MIN-BAR-H (math/round (* SEC-H v)))]]
      [:row {:w SBAR-W :h h :bg (color-fn v) :skew SLANT}])])

# -- Icons --
# All shapes lean with the / via skew to match the section aesthetic.

(def- ICON-SKEW SLANT)

(defn- icon-cpu [color]
  "Chip: angled outline with die."
  (def offset (math/floor (* ICON-SKEW 16 0.5)))
  [:row {:w 16 :h 16 :bg (tint color 60) :skew ICON-SKEW
         :align-x :center :align-y :center :pad [0 0 0 offset]}
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
  "Speaker: skewed driver + skewed cone flaring right."
  [:row {:gap 0 :align-y :center :skew ICON-SKEW}
    [:row {:w 4 :h 8 :bg color}]
    [:tri {:w 7 :h 13 :dir :left :color color}]])

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
  (def skew-offset (math/floor (* SLANT BAR-H 0.5)))
  [:row {:id id :h BAR-H :pad [0 10 0 (+ 10 skew-offset)] :align-x :center :align-y :center
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
          gap 2
          avail (- (if vertical h w) (* gap (max 0 (- n 1))))
          csz (max 2 (math/floor (/ avail (max 1 n))))]
      (if vertical
        # Vertical split: offset each child rightward so left edges
        # trace a continuous / slant. Bottom child has zero offset,
        # each child above shifts right by SLANT * height-below-it.
        (do
          (def total-below @[])
          (var acc 0)
          (for i 0 n
            (array/push total-below acc)
            (set acc (+ acc csz gap)))
          # Reverse: top child needs the most offset
          (def offsets (reverse (array/slice total-below)))
          [:col {:gap gap :w (+ w (math/floor (* SLANT (- h csz)))) :h h}
            ;(seq [i :range [0 n]
                   :let [c (children i)
                         pad-l (math/floor (* SLANT (offsets i)))]]
               [:row {:pad [0 0 0 pad-l]}
                 (minimap-tree c w csz)])])
        [:row {:gap gap :w w :h h}
          ;(seq [c :in children]
             (minimap-tree c csz h))]))))

(defn- scroll-minimap []
  (def out (this-output))
  (when out
    (def columns (get out "columns" []))
    (when (> (length columns) 0)
      (def mh BAR-H)
      (def tw (sum (map |(get $ "width" 1) columns)))
      (def mw (min 180 (max 50 (* mh (max 1 (* tw 1.5))))))
      (def scale (/ mw (max 0.01 tw)))
      [:row {:gap 2 :align-y :center :h BAR-H :pad [0 6] :bg minimap-bg :skew SLANT}
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
                 (let [rh (max 2 (math/floor (/ (- mh (* 2 (- nl 1))) nl)))]
                   [:col {:gap 2 :w (+ sw (math/floor (* SLANT (- mh rh)))) :h mh}
                     ;(seq [i :range [0 nl]
                            :let [pad-l (math/floor (* SLANT (* (- nl 1 i) (+ rh 2))))]]
                        [:row {:pad [0 0 0 pad-l]}
                          [:row {:w sw :h rh :bg c :skew SLANT}]])])))))])))

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

(defn- cpu-bar-color [v]
  (tint (pct-color (* v 100)) 200))

(defn- cpu-view []
  (let [pct (sub :cpu/percent)
        cpu (sub :cpu)
        samples (or (get cpu :samples) @[])
        now (os/clock :monotonic)
        values (sparkline-values samples now 60 :v)]
    (section cpu-bg
      (sparkline-bars values cpu-bar-color)
      (icon-cpu (pct-color pct)))))

(defn- mem-view []
  (let [pct (get (sub :mem) :percent 0)]
    (section mem-bg
      (fill-bar green pct)
      (icon-mem green))))

(defn- disk-view []
  (let [pct (get (sub :disk) :percent 0)]
    (section disk-bg
      (fill-bar orange pct)
      (icon-disk orange))))

(defn- net-log-val [bps link-speed]
  "Log10-normalize bytes/sec to 0-1 range."
  (let [floor-bps 1024
        ceil-bps (or link-speed 1250000000)]
    (if (<= bps floor-bps) 0
      (min 1 (/ (- (log10 bps) (log10 floor-bps))
                (- (log10 ceil-bps) (log10 floor-bps)))))))

(defn- net-bar-color [v]
  "Inverted contrast: compressed color at low end, rich change at high end."
  (lerp-color (tint cyan 180) (tint bright 255) (* v v v)))

(defn- net-view []
  (let [net (sub :net)
        rx (get net :rx-rate 0)
        tx (get net :tx-rate 0)
        samples (or (get net :samples) @[])
        link-speed (get net :link-speed)
        now (os/clock :monotonic)
        rx-vals (sparkline-values samples now 30 :rx)
        tx-vals (sparkline-values samples now 30 :tx)
        values (map |(net-log-val (max $0 $1) link-speed) rx-vals tx-vals)]
    (section net-bg
      (sparkline-bars values net-bar-color)
      [:col {:gap 1}
        [:text {:color green :size 13} (string "↓" (fmt-rate rx))]
        [:text {:color cyan :size 13} (string "↑" (fmt-rate tx))]])))

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
    (def discharging (not charging))
    (def critical (and discharging (< pct 5)))
    (def low (and discharging (< pct 15)))
    # Flash: sin-based 1 Hz pulse, alpha oscillates 0.3–1.0
    (def flash-alpha (if (or critical low)
                       (+ 0.65 (* 0.35 (math/sin (* 2 math/pi (os/clock :monotonic)))))
                       1.0))
    (def base-color (cond charging green low red (< pct 50) orange accent))
    (def color [(base-color 0) (base-color 1) (base-color 2)
                (math/floor (* (get base-color 3 255) flash-alpha))])
    (section bat-bg
      (fill-bar color pct)
      (icon-battery color))))

(defn- clock-view []
  (section clock-bg
    [:col {:align-x :right :gap 1 :pad [0 14 0 0]}
      [:row {:gap 6 :align-y :baseline}
        [:text {:color bright :size 17} (sub :clock/time)]
        [:text {:color text-color :size 12} (sub :clock/dow)]]
      [:text {:color subtle :size 12} (sub :clock/date)]]))

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
      (cpu-view)
      (net-view)
      (audio-view)
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
