#!/usr/bin/env shoal
# bar.janet — Example status bar
#
# Powerline-style bar with workspace indicators, window title, minimap,
# system widgets, and clock.
# Run with: shoal run bar.janet [compositor]
#   compositor: "sway" or "tidepool" (default: "tidepool")

# Get compositor from args (default: tidepool)
(def compositor (or (script-args 0) "tidepool"))

# Load compositor integration
(case compositor
  "sway" (use "compositor/sway")
  "tidepool" (use "compositor/tidepool")
  (error (string "unknown compositor: " compositor)))

# Load data sources and overlays
(use "module/clock")
(use "module/sysinfo")
(use "module/launcher")
(use "module/osd")

# Load drawing helpers
(use "stdlib/util")
(use "drawing/widgets")

# Theme shortcuts
(def bg (theme :bg))
(def surface (theme :surface))
(def overlay (theme :overlay))
(def muted (theme :muted))
(def subtle (theme :subtle))
(def text-color (theme :text))
(def bright (theme :bright))
(def accent (theme :accent))
(def red (theme :red))
(def orange (theme :orange))
(def yellow (theme :yellow))
(def green (theme :green))
(def cyan (theme :cyan))
(def blue (theme :blue))
(def purple (theme :purple))

(def BAR-H 38)

# --- Derived colors ---

(def audio-bg (blend-bg purple 100 bg))
(def net-bg (blend-bg cyan 100 bg))
(def cpu-bg (blend-bg yellow 100 bg))
(def mem-bg (blend-bg green 100 bg))
(def disk-bg (blend-bg orange 100 bg))
(def bat-bg (blend-bg red 100 bg))
(def clock-bg (blend-bg blue 100 bg))
(def launcher-bg (blend-bg muted 80 bg))
(def minimap-bg (blend-bg surface 120 bg))

# --- Subscriptions ---

(reg-sub :wm/focused-output [:wm/outputs]
  (fn [outputs] (find |(get $ "focused") outputs)))

(defn this-output []
  (def name (current-output))
  (def outputs (sub :wm/outputs))
  (when (and name outputs)
    (find |(= (get $ "name") name) outputs)))

# --- Helpers ---

(defn local-pct-color [pct]
  (cond (>= pct 80) red
        (>= pct 50) yellow
        green))

(defn fill-bar-local [color pct]
  (def clamped (max 0 pct))
  (def wrapped (> clamped 100))
  (def bar-pct (if wrapped (% clamped 100) clamped))
  (def bar-pct (if (and wrapped (= bar-pct 0)) 100 bar-pct))
  (def bar-color (if wrapped bright color))
  (def fill-h (max MIN-BAR-H (math/round (* BAR-H (/ (min 100 bar-pct) 100)))))
  [:row {:w 8 :h BAR-H :align-y :bottom}
    [:row {:w 8 :h fill-h :bg bar-color :skew SLANT}]])

(defn bar-scroll [tick-clock period]
  (max 0 (min 0.99 (/ (- (os/clock :monotonic) (or tick-clock 0)) period))))

# --- Workspace tags ---

(defn tag-view [idx tag]
  (def id (string/format "tag-%d" idx))
  (def hover (anim (keyword (string id "-hover"))))
  (def focused (tag :focused))
  (def skew-offset (math/floor (* SLANT BAR-H 0.5)))
  [:row {:id id :h BAR-H :pad [0 10 0 (+ 10 skew-offset)]
         :align-x :center :align-y :center
         :bg (if focused
               accent
               [(muted 0) (muted 1) (muted 2) (math/floor (* hover 200))])
         :skew SLANT}
    [:text {:color (if focused bg text-color) :size 16}
      (string/format "%d" idx)]])

(defn workspaces-view []
  (def out (this-output))
  (def active-tag (when out (get out "tag" 0)))
  (def tags (sub :wm/tags))
  (def output-tags
    (if out
      (let [out-tags (get out "tags" [])]
        (if (> (length out-tags) 0)
          out-tags
          (if (> (or active-tag 0) 0) [active-tag] [])))
      (seq [i :range [1 10]
            :let [tag (get tags i)]
            :when (and tag (get tag :occupied false))]
        i)))
  [:row {:gap 0 :align-y :center}
    ;(seq [i :in output-tags
           :let [tag (get tags i)
                 focused (or (= i active-tag)
                             (and tag (get tag :focused false)))
                 occupied (or focused
                              (and tag (get tag :occupied false)))]
           :when occupied]
      (tag-view i {:focused focused :occupied occupied}))])

# --- Scroll minimap ---

(defn scroll-minimap []
  (def out (this-output))
  (when out
    (def columns (get out "columns" []))
    (when (> (length columns) 0)
      (def mh BAR-H)
      (def tw (sum (map |(get $ "width" 1) columns)))
      (def mw (min 180 (max 50 (* mh (max 1 (* tw 1.5))))))
      (def scale (/ mw (max 0.01 tw)))
      [:row {:gap 2 :align-y :center :h BAR-H :pad [0 6]
             :bg minimap-bg :skew SLANT}
        ;(seq [col :in columns
               :let [sw (max 3 (math/floor (* (get col "width" 1) scale)))
                     tree (get col "tree")]]
          (if tree
            (minimap-tree tree sw mh accent overlay)
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

# --- Title ---

(defn title-view []
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

# --- Right-side widgets ---

(defn cpu-bar-color [v]
  (tint (local-pct-color (* v 100)) 200))

(defn cpu-view []
  (let [cpu (sub :cpu)
        pct (get cpu :percent 0)
        bars (or (get cpu :bars) (array/new-filled (+ N-SPARKLINE 1) 0))
        scroll (bar-scroll (get cpu :tick-clock 0) 2.0)]
    (section cpu-bg {}
      (sparkline bars {:colors (map cpu-bar-color bars)
                       :scroll scroll})
      (icon-cpu (local-pct-color pct)))))

(defn mem-view []
  (let [pct (get (sub :mem) :percent 0)]
    (section mem-bg {}
      (fill-bar-local green pct)
      (icon-mem green))))

(defn disk-view []
  (let [pct (get (sub :disk) :percent 0)]
    (section disk-bg {}
      (fill-bar-local orange pct)
      (icon-disk orange))))

(defn net-rx-color [v]
  (lerp-color (tint green 170) (tint bright 255) (* v v)))

(defn net-tx-color [v]
  (lerp-color (tint cyan 170) (tint bright 255) (* v v)))

(defn net-view []
  (let [net (sub :net)
        rx (get net :rx-rate 0)
        tx (get net :tx-rate 0)
        spark (net-spark-values net N-NET-SPARK)
        scroll (bar-scroll (get net :tick-clock 0) NET-SAMPLE-SEC)]
    (section net-bg {}
      (network-spark (spark :rx) (spark :tx) (tint green 205) (tint cyan 205)
                     {:scroll scroll})
      [:col {:gap 1}
        [:text {:color green :size 13} (string/format "rx %s" (fmt-rate rx))]
        [:text {:color cyan :size 13} (string/format "tx %s" (fmt-rate tx))]])))

(defn audio-view []
  (def audio (sub :audio))
  (def pct (get audio :percent 0))
  (def muted-flag (get audio :muted false))
  (def color (cond muted-flag red (>= pct 100) yellow purple))
  (section audio-bg {}
    (fill-bar-local color pct)
    (icon-audio color)))

(defn bat-view []
  (def bat (sub :bat))
  (when (bat :present)
    (def pct (get bat :percent 0))
    (def charging (bat :charging))
    (def discharging (not charging))
    (def critical (and discharging (< pct 5)))
    (def low (and discharging (< pct 15)))
    (def flash-alpha (if (or critical low)
                       (+ 0.65 (* 0.35 (math/sin (* 2 math/pi (os/clock :monotonic)))))
                       1.0))
    (def base-color (cond charging green low red (< pct 50) orange accent))
    (def color [(base-color 0) (base-color 1) (base-color 2)
                (math/floor (* (get base-color 3 255) flash-alpha))])
    (section bat-bg {}
      (fill-bar-local color pct)
      (icon-battery color))))

(defn clock-view []
  (def skew-pad (math/ceil (* SLANT BAR-H)))
  (def date-slant-shift (math/floor (* skew-pad 0.85)))
  (section clock-bg {:pad [0 8 0 2] :gap 6}
    [:col {:align-x :right :gap 1 :pad [0 6 0 skew-pad]}
      [:row {:gap 5 :align-y :baseline}
        [:text {:color bright :size 17} (sub :clock/time)]
        [:text {:color text-color :size 12} (sub :clock/dow)]]
      [:text {:color subtle :size 12 :dx (- 0 date-slant-shift) :baseline-shift-line -0.06}
        (sub :clock/date)]]))

# --- Root ---

(defn launcher-view []
  (section launcher-bg {}
    [:row {:id "launcher" :align-y :center}
      (icon-launcher bright)]))

(defn bar-view []
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

# --- Pointer handlers ---

(reg-event-handler :pointer-enter
    (fn [cofx event]
      (def id (get event 1 ""))
      (when (string/has-prefix? "tag-" id)
        {:anim {:id (keyword (string id "-hover")) :to 1 :duration 0.15 :easing :ease-out-cubic
                :surface :default}})))

(reg-event-handler :pointer-leave
    (fn [cofx event]
      (def id (get event 1 ""))
      (when (string/has-prefix? "tag-" id)
        {:anim {:id (keyword (string id "-hover")) :to 0 :duration 0.2 :easing :ease-out-cubic
                :surface :default}})))

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

(reg-surface :default
  {:per-output true
   :anchor {:bottom true :left true :right true}
   :exclusive-zone BAR-H}
  bar-view)
