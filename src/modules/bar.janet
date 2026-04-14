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
  "Colour with overridden alpha (0-255). Default 100 for section bgs."
  [(color 0) (color 1) (color 2) (or a 100)])

(def- audio-bg (tint purple))
(def- net-bg   (tint cyan))
(def- cpu-bg   (tint yellow))
(def- mem-bg   (tint green))
(def- disk-bg  (tint orange))
(def- bat-bg   (tint red))
(def- clock-bg (tint blue))
(def- launcher-bg (tint muted 80))

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

(defn- weighted-peak [samples tau]
  "Time-weighted max: each sample contributes value * exp(-age/tau).
   Recent samples dominate; old samples trail off smoothly."
  (if (or (nil? samples) (= 0 (length samples)))
    0
    (do
      (def now (os/clock :monotonic))
      (var mx 0)
      (each s samples
        (def age (- now (get s 0)))
        (when (>= age 0)
          (def w (math/exp (- (/ age tau))))
          (def contrib (* (get s 1) w))
          (when (> contrib mx) (set mx contrib))))
      mx)))

(defn- resample [samples window lag n]
  "Resample timestamped [time value] pairs into n evenly-spaced values.
   Window ends at (now - lag)."
  (def now (- (os/clock :monotonic) lag))
  (if (or (nil? samples) (< (length samples) 2))
    (array/new-filled n 0)
    (do
      (def start (- now window))
      (def step (/ window (- n 1)))
      (def result @[])
      (var j 0)
      (for i 0 n
        (def t (+ start (* i step)))
        (while (and (< (+ j 1) (length samples))
                    (<= (get (get samples (+ j 1)) 0) t))
          (++ j))
        (def s0 (get samples j))
        (def t0 (get s0 0))
        (if (or (>= j (- (length samples) 1)) (<= t t0))
          (array/push result (get s0 1))
          (let [s1 (get samples (+ j 1))
                t1 (get s1 0)
                v0 (get s0 1)
                v1 (get s1 1)
                frac (/ (- t t0) (max 0.001 (- t1 t0)))]
            (array/push result (+ v0 (* frac (- v1 v0)))))))
      result)))

# -- Section primitive --

(defn- section [color & children]
  "Powerline section: parallelogram bg with /-slanted right/left edges.
   Children are laid out normally inside; the background is drawn behind
   via a :skew attribute routed through a custom render payload."
  [:row {:h SEC-H :pad [0 14] :align-y :center :gap 10
         :bg color :skew SLANT}
    ;children])

# -- Slanted bar chart --

(defn- slant-bars [w h color values]
  "Render values (each 0..1) as slanted parallelogram bars rising from
   a shared baseline. Adjacent bars tessellate on their /-slants."
  (def n (max 1 (length values)))
  (def bw (max 2 (math/floor (/ w n))))
  [:row {:w w :h h :align-y :bottom :gap 0}
    ;(seq [v :in values
           :let [clamped (max 0 (min 1 v))
                 bh (math/floor (* clamped h))]
           :when (> bh 0)]
       [:row {:w bw :h bh :bg color :skew SLANT}])])

(defn- mirrored-slant-bars [w h c1 c2 vals1 vals2]
  "Two stacked slanted-bar charts sharing a midline baseline.
   vals1 rises up from the midline, vals2 descends down."
  (def half (math/floor (/ h 2)))
  [:col {:w w :h h :gap 0}
    [:row {:w w :h half :align-y :bottom :gap 0}
      ;(seq [v :in vals1
             :let [clamped (max 0 (min 1 v))
                   bh (math/floor (* clamped half))]
             :when (> bh 0)]
         [:row {:w (max 2 (math/floor (/ w (max 1 (length vals1)))))
                :h bh :bg c1 :skew SLANT}])]
    [:row {:w w :h half :align-y :top :gap 0}
      ;(seq [v :in vals2
             :let [clamped (max 0 (min 1 v))
                   bh (math/floor (* clamped half))]
             :when (> bh 0)]
         [:row {:w (max 2 (math/floor (/ w (max 1 (length vals2)))))
                :h bh :bg c2 :skew SLANT}])]])

# -- Icons (composed from rect/tri/parallelogram primitives) --

(defn- icon-cpu [color]
  [:row {:gap 2 :align-y :bottom :h 22}
    [:row {:w 4 :h 9  :bg color :radius 1}]
    [:row {:w 4 :h 14 :bg color :radius 1}]
    [:row {:w 4 :h 19 :bg color :radius 1}]
    [:row {:w 4 :h 22 :bg color :radius 1}]])

(defn- icon-mem [color]
  [:col {:gap 2}
    [:row {:gap 2}
      [:row {:w 9 :h 9 :bg color :radius 2}]
      [:row {:w 9 :h 9 :bg color :radius 2}]]
    [:row {:gap 2}
      [:row {:w 9 :h 9 :bg color :radius 2}]
      [:row {:w 9 :h 9 :bg color :radius 2}]]])

(defn- icon-disk [color]
  [:row {:w 22 :h 22 :border-color color :border-width 2
         :radius 11 :align-x :center :align-y :center}
    [:row {:w 5 :h 5 :bg color :radius 3}]])

(defn- icon-battery [color fill-pct charging]
  (def inner-w (max 0 (math/floor (* 15 (/ fill-pct 100)))))
  [:row {:gap 0 :align-y :center}
    [:row {:w 22 :h 12 :border-color color :border-width 1
           :radius 2 :pad 2 :align-y :center}
      [:row {:w inner-w :h :grow :bg color :radius 1}]]
    [:row {:w 2 :h 6 :bg color}]])

(defn- icon-net-rx [color]
  [:tri {:w 14 :h 10 :dir :up :color color}])

(defn- icon-net-tx [color]
  [:tri {:w 14 :h 10 :dir :down :color color}])

(defn- icon-audio [color]
  [:row {:gap 2 :align-y :center}
    [:row {:w 3 :h 10 :bg color :radius 1}]
    [:tri {:w 12 :h 16 :dir :right :color color}]
    [:col {:gap 3 :align-y :center}
      [:row {:w 2 :h 2 :bg color :radius 1}]
      [:row {:w 2 :h 2 :bg color :radius 1}]]])

(defn- icon-launcher [color]
  [:col {:gap 2}
    [:row {:gap 2}
      [:row {:w 4 :h 4 :bg color :radius 1}]
      [:row {:w 4 :h 4 :bg color :radius 1}]
      [:row {:w 4 :h 4 :bg color :radius 1}]]
    [:row {:gap 2}
      [:row {:w 4 :h 4 :bg color :radius 1}]
      [:row {:w 4 :h 4 :bg color :radius 1}]
      [:row {:w 4 :h 4 :bg color :radius 1}]]
    [:row {:gap 2}
      [:row {:w 4 :h 4 :bg color :radius 1}]
      [:row {:w 4 :h 4 :bg color :radius 1}]
      [:row {:w 4 :h 4 :bg color :radius 1}]]])

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

# -- Right-side section views --

(defn- cpu-view []
  (def pct (sub :cpu/percent))
  (def cpu (sub :cpu))
  (def values (resample (get cpu :samples) 60 2 18))
  (def color (pct-color pct))
  (section cpu-bg
    (icon-cpu color)
    (slant-bars 60 24 (tint color 220) values)
    [:text {:color color :size 19} (string (math/floor pct) "%")]))

(defn- mem-view []
  (def mem (sub :mem))
  (def pct (get mem :percent 0))
  (def used (get mem :used-mb 0))
  (def total (get mem :total-mb 0))
  (def color (pct-color pct))
  (section mem-bg
    (icon-mem color)
    [:text {:color color :size 18}
      (string (fmt-gb (/ used 1024)) "/" (fmt-gb (/ total 1024)) "G")]))

(defn- disk-view []
  (def disk (sub :disk))
  (def pct (get disk :percent 0))
  (def color (pct-color pct))
  (section disk-bg
    (icon-disk color)
    [:text {:color color :size 18}
      (string (fmt-gb (get disk :used-gb 0)) "/" (fmt-gb (get disk :total-gb 0)) "G")]))

(defn- net-view []
  (def net (sub :net))
  (def rx (get net :rx-rate 0))
  (def tx (get net :tx-rate 0))
  (def rx-samples (get net :rx-samples))
  (def tx-samples (get net :tx-samples))
  (def tau 30)
  (def scale (max 1024
                  (* 1.2 (max (weighted-peak rx-samples tau)
                              (weighted-peak tx-samples tau)))))
  (def rx-vals (resample rx-samples 60 1 18))
  (def tx-vals (resample tx-samples 60 1 18))
  (def rx-norm (map |(max 0 (/ $ scale)) rx-vals))
  (def tx-norm (map |(max 0 (/ $ scale)) tx-vals))
  (section net-bg
    (mirrored-slant-bars 60 26 (tint green 220) (tint cyan 220) rx-norm tx-norm)
    [:col {:gap 2}
      [:row {:gap 4 :align-y :center}
        (icon-net-rx green)
        [:text {:color green :size 14} (fmt-rate rx)]]
      [:row {:gap 4 :align-y :center}
        (icon-net-tx cyan)
        [:text {:color cyan :size 14} (fmt-rate tx)]]]))

(defn- audio-view []
  (def audio (sub :audio))
  (def pct (get audio :percent 0))
  (def muted-flag (get audio :muted false))
  (def color (cond muted-flag red (>= pct 100) yellow purple))
  (section audio-bg
    (icon-audio color)
    [:text {:id "audio" :color color :size 19} (string (math/floor pct) "%")]))

(defn- bat-view []
  (def bat (sub :bat))
  (when (bat :present)
    (def pct (get bat :percent 0))
    (def charging (bat :charging))
    (def color (cond charging green (< pct 20) red (< pct 50) orange accent))
    (section bat-bg
      (icon-battery color pct charging)
      [:text {:color color :size 19} (string (math/floor pct) "%")])))

(defn- clock-view []
  # Date (longer, top) and time (shorter, bottom) both right-align inside
  # the parallelogram. The col right-aligns both lines to its own right
  # edge; time gets extra trailing padding so its right edge sits further
  # left — anchoring each line to the /-slant at its own y position.
  (def time-right-pad (math/floor (* SLANT 14)))
  (section clock-bg
    [:col {:align-x :right :gap 1}
      [:text {:color bright :size 17} (sub :clock/date)]
      [:row {:pad [0 time-right-pad 0 0]}
        [:text {:color subtle :size 14} (sub :clock/time)]]]))

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
