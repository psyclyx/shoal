# bar — status bar view
#
# Pure Janet view functions producing hiccup for a status bar.
# Layout: left (workspaces, layout glyph, scroll minimap) | center (title) | right (clock, cpu, mem, bat)
#
# Uses subscriptions from tidepool.janet, clock.janet, sysinfo.janet.
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

(reg-sub :tp/focused-output [:tp/outputs]
  (fn [outputs] (find |($ :focused) outputs)))

# -- Helper: pill wrapper --

(defn- pill [& children]
  [:row {:pad [4 8] :bg surface :radius 6 :gap 6 :align-y :center}
    ;children])

# -- Workspace tags --

(defn- tag-view [idx tag]
  (def id (string "tag-" idx))
  (def hover (anim (keyword id "-hover")))
  (if (tag :focused)
    [:row {:id id :w 22 :h 22 :bg accent :radius 5 :align-x :center :align-y :center}
      [:text {:color bg :size 14} (string idx)]]
    [:row {:id id :w 22 :h 22 :bg [(muted 0) (muted 1) (muted 2) (math/floor (* hover 255))]
           :radius 5 :align-x :center :align-y :center}
      [:text {:color text-color :size 14} (string idx)]]))

(defn- workspaces-view []
  (def tags (sub :tp/tags))
  [:row {:gap 4 :align-y :center :pad [2 4] :bg surface :radius 6}
    ;(seq [i :range [1 10]
           :let [tag (get tags i {:focused false :occupied false})]
           :when (or (tag :focused) (tag :occupied))]
       (tag-view i tag))])

# -- Layout glyph --

(defn- layout-glyph []
  (def name (sub :tp/layout))
  (when (and name (> (length name) 0))
    (def c muted)
    (def hi accent)
    (def glyph
    (match name
      "master-stack"
      [:row {:gap 1 :h 16 :align-y :center}
        [:row {:w 10 :h 16 :bg hi :radius 1}]
        [:col {:gap 1}
          [:row {:w 5 :h 7 :bg c :radius 1}]
          [:row {:w 5 :h 7 :bg c :radius 1}]]]
      "grid"
      [:col {:gap 1}
        [:row {:gap 1}
          [:row {:w 7 :h 7 :bg c :radius 1}]
          [:row {:w 7 :h 7 :bg c :radius 1}]]
        [:row {:gap 1}
          [:row {:w 7 :h 7 :bg c :radius 1}]
          [:row {:w 7 :h 7 :bg c :radius 1}]]]
      "monocle"
      [:row {:w 16 :h 16 :bg hi :radius 2 :border-color c :border-width 1}]
      "scroll"
      [:row {:gap 1 :h 16 :align-y :center}
        [:row {:w 4 :h 12 :bg c :radius 1}]
        [:row {:w 5 :h 16 :bg hi :radius 1}]
        [:row {:w 4 :h 12 :bg c :radius 1}]]
      "dwindle"
      [:col {:gap 1 :w 16}
        [:row {:w 16 :h 8 :bg hi :radius 1}]
        [:row {:gap 1 :h 7}
          [:row {:w 8 :h 7 :bg c :radius 1}]
          [:col {:gap 1}
            [:row {:w 7 :h 3 :bg c :radius 1}]
            [:row {:w 7 :h 3 :bg c :radius 1}]]]]
      "tabbed"
      [:col {:gap 0 :h 16}
        [:row {:gap 1 :h 4 :align-y :center}
          [:row {:w 5 :h 4 :bg hi :radius [1 1 0 0]}]
          [:row {:w 4 :h 3 :bg c :radius [1 1 0 0]}]
          [:row {:w 4 :h 3 :bg c :radius [1 1 0 0]}]]
        [:row {:w 15 :h 11 :bg [(hi 0) (hi 1) (hi 2) 80] :radius [0 0 1 1]}]]
      "centered-master"
      [:row {:gap 1 :h 16 :align-y :center}
        [:row {:w 4 :h 12 :bg c :radius 1}]
        [:row {:w 8 :h 16 :bg hi :radius 1}]
        [:row {:w 4 :h 12 :bg c :radius 1}]]
      # fallback: text
      [:text {:color subtle :size 11} name]))
    [:row {:id "layout" :align-y :center :pad [2 4]} glyph]))

# -- Scroll minimap --

(defn- scroll-minimap []
  (def focused-out (sub :tp/focused-output))
  (when (and focused-out (= (focused-out :layout) "scroll"))
    (def vp (get focused-out :viewport))
    (when (and vp (get vp :column-widths) (> (get vp :total-content-w 0) 0))
      (def col-widths (vp :column-widths))
      (def total-w (vp :total-content-w))
      (def vp-w (get vp :w 0))
      (def scroll-off (get vp :scroll-offset 0))
      (def minimap-h 18)
      (def minimap-w (min 180 (max 60 (* minimap-h (/ total-w (max 1 (get vp :h 1)))))))
      (def scale (/ minimap-w (max 1 total-w)))

      (def windows (sub :tp/windows))
      (def focused-win (find |($ :focused) windows))
      (def focused-col (when focused-win (get focused-win :column)))

      # Group visible windows by column index
      (def col-rows @{})
      (each w windows
        (when (w :visible)
          (def ci (w :column))
          (def existing (get col-rows ci @[]))
          (array/push existing w)
          (put col-rows ci existing)))

      # Build column position table
      (var cx 0)
      (def columns
        (seq [i :range [0 (length col-widths)]
              :let [cw (get col-widths i 0)
                    x cx]]
          (do (set cx (+ cx cw))
              {:x x :w cw :i i})))

      (def vp-end (+ scroll-off vp-w))

      [:row {:gap 1 :align-y :center :pad [2 4] :bg surface :radius 6}
        ;(seq [col :in columns
               :let [in-vp (and (< (col :x) vp-end)
                                (> (+ (col :x) (col :w)) scroll-off))
                     is-focused (= (col :i) focused-col)
                     scaled-w (max 3 (math/floor (* (col :w) scale)))
                     rows (get col-rows (col :i))
                     n-rows (if rows (length rows) 1)
                     base-color (cond
                                  is-focused accent
                                  in-vp overlay
                                  [(muted 0) (muted 1) (muted 2) 100])]]
           (if (<= n-rows 1)
             [:row {:w scaled-w :h minimap-h :bg base-color :radius 2}]
             [:col {:gap 1 :w scaled-w :h minimap-h :radius 2}
               ;(seq [r :range [0 n-rows]
                      :let [row-h (max 2 (math/floor (/ (- minimap-h (- n-rows 1)) n-rows)))
                            rw (get rows r)
                            row-focused (and rw (rw :focused))
                            color (if row-focused accent base-color)]]
                  [:row {:w scaled-w :h row-h :bg color :radius 1}])]))])))

# -- Title --

(defn- title-view []
  (def title (sub :tp/title))
  (def app-id (sub :tp/app-id))
  (if (and title (> (length title) 0))
    [:row {:gap 6 :align-y :center}
      (when (and app-id (> (length app-id) 0) (not= app-id title))
        [:text {:color muted :size 13} app-id])
      [:text {:color text-color :size 17} title]]
    [:text {:color subtle :size 17} ""]))

# -- Right-side modules --

(defn- pct-color [pct]
  (cond (>= pct 80) red (>= pct 50) yellow green))

(defn- fmt-gb [g]
  (let [w (math/floor g)
        f (math/floor (* 10 (- g w)))]
    (string w "." f)))

(defn- fmt-rate [bps]
  "Format bytes/sec as human-readable rate. Uses K+ units for stability."
  (cond
    (>= bps 1073741824) (string/format "%.1fG" (/ bps 1073741824))
    (>= bps 104857600)  (string/format "%.0fM" (/ bps 1048576))
    (>= bps 1048576)    (string/format "%.1fM" (/ bps 1048576))
    (>= bps 102400)     (string/format "%.0fK" (/ bps 1024))
    (>= bps 1024)       (string/format "%.1fK" (/ bps 1024))
    (> bps 0)           (string/format "%.1fK" (/ bps 1024))
    "0K"))

(defn- cpu-view []
  (def pct (sub :cpu/percent))
  (pill
    [:text {:color (pct-color pct) :size 14}
      (string (math/floor pct) "%")]
    [:text {:color subtle :size 11} "cpu"]))

(defn- mem-view []
  (def mem (sub :mem))
  (def pct (get mem :percent 0))
  (def used (get mem :used-mb 0))
  (def total (get mem :total-mb 0))
  (def used-str (if (>= used 1024) (fmt-gb (/ used 1024)) (string (math/floor used))))
  (def total-str (if (>= total 1024)
                   (string (fmt-gb (/ total 1024)) "G")
                   (string (math/floor total) "M")))
  (pill
    [:text {:color (pct-color pct) :size 13}
      (string used-str "/" total-str)]
    [:text {:color subtle :size 11} "mem"]))

(defn- bat-view []
  (def bat (sub :bat))
  (when (bat :present)
    (def pct (get bat :percent 0))
    (def charging (bat :charging))
    (def color (cond charging accent (< pct 20) red (< pct 50) yellow green))
    (pill
      [:text {:color color :size 14}
        (string (if charging "⚡" "") (math/floor pct) "%")]
      [:text {:color subtle :size 11} "bat"])))

(defn- disk-view []
  (def disk (sub :disk))
  (def pct (get disk :percent 0))
  (def used (get disk :used-gb 0))
  (def total (get disk :total-gb 0))
  (pill
    [:text {:color (pct-color pct) :size 13}
      (string (fmt-gb used) "/" (fmt-gb total) "G")]
    [:text {:color subtle :size 11} "disk"]))

(defn- net-view []
  (def net (sub :net))
  (def rx (get net :rx-rate 0))
  (def tx (get net :tx-rate 0))
  (def iface (get net :iface ""))
  (def ipv4 (get net :ipv4 ""))
  [:row {:pad [4 8] :bg surface :radius 6 :gap 6 :align-y :center}
    [:text {:color green :size 12} (string "↓" (fmt-rate rx))]
    [:text {:color accent :size 12} (string "↑" (fmt-rate tx))]
    (when (> (length ipv4) 0)
      [:text {:color muted :size 11} ipv4])
    [:text {:color subtle :size 11} iface]])

(defn- clock-view []
  (pill [:text {:color text-color :size 17} (sub :clock/time)]))

# -- Root bar view --

(defn- launcher-trigger []
  [:row {:id "launcher" :pad [4 8] :bg surface :radius 6 :align-y :center}
    [:text {:color subtle :size 14} "⌕"]])

(defn- bar-view []
  [:row {:w :grow :h :grow :pad [0 8] :bg bg :radius 8 :align-y :center}
    # Left: workspaces + layout + minimap + launcher
    [:row {:w :grow :gap 6 :align-y :center}
      (workspaces-view)
      (layout-glyph)
      (scroll-minimap)
      (launcher-trigger)]
    # Center: title
    [:row {:w :grow :align-x :center :align-y :center}
      (title-view)]
    # Right: system info
    [:row {:w :grow :gap 6 :align-x :right :align-y :center}
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
        (when tag {:dispatch [:tp/focus-tag tag]}))

      (= id "launcher")
      {:dispatch [:launcher/open]}

      (= id "layout")
      {:dispatch [:tp/cycle-layout "next"]})))

(reg-view bar-view)
