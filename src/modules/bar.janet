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
  (def out (this-output))
  (def active-tag (when out (get out "tag" 0)))
  (def occupied (sub :wm/occupied-tags))
  [:row {:gap 4 :align-y :center :pad [2 4] :bg surface :radius 6}
    ;(seq [i :range [1 10]
           :let [focused (= i active-tag)
                 occ (or focused (truthy? (some |(= $ i) (or occupied []))))]
           :when occ]
       (tag-view i {:focused focused :occupied occ}))])

# -- Scroll minimap --

(defn- scroll-minimap []
  (def out (this-output))
  (when out
    (def columns (get out "columns" []))
    (when (> (length columns) 0)
      (def minimap-h 18)
      # Sum widths, scale proportionally
      (def total-w (sum (map |(get $ "width" 1) columns)))
      (def minimap-w (min 180 (max 60 (* minimap-h (max 1 (* total-w 1.5))))))
      (def scale (/ minimap-w (max 0.01 total-w)))

      [:row {:gap 1 :align-y :center :pad [2 4] :bg surface :radius 6}
        ;(seq [col :in columns
               :let [is-focused (get col "focused" false)
                     n-leaves (get col "leaves" 1)
                     col-w (get col "width" 1)
                     scaled-w (max 3 (math/floor (* col-w scale)))
                     base-color (if is-focused accent overlay)]]
           (if (<= n-leaves 1)
             [:row {:w scaled-w :h minimap-h :bg base-color :radius 2}]
             [:col {:gap 1 :w scaled-w :h minimap-h :radius 2}
               ;(seq [r :range [0 n-leaves]
                      :let [row-h (max 2 (math/floor (/ (- minimap-h (- n-leaves 1)) n-leaves)))
                            color base-color]]
                  [:row {:w scaled-w :h row-h :bg color :radius 1}])]))])))

# -- Title --

(defn- title-view []
  (def out (this-output))
  (def is-focused (and out (get out "focused" false)))
  (if is-focused
    (do
      (def title (sub :wm/title))
      (def app-id (sub :wm/app-id))
      (if (and title (> (length title) 0))
        [:row {:id "title" :gap 6 :align-y :center}
          (when (and app-id (> (length app-id) 0) (not= app-id title))
            [:text {:color muted :size 13} app-id])
          [:text {:color text-color :size 17} title]]
        [:text {:id "title" :color subtle :size 17} ""]))
    [:text {:id "title" :color subtle :size 17} ""]))

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

(defn- audio-view []
  (def audio (sub :audio))
  (def pct (get audio :percent 0))
  (def muted (get audio :muted false))
  (def color (cond muted red (>= pct 100) yellow accent))
  [:row {:id "audio" :pad [4 8] :bg surface :radius 6 :gap 6 :align-y :center}
    [:text {:color color :size 14}
      (string (if muted "M " "") (math/floor pct) "%")]
    [:text {:color subtle :size 11} "vol"]])

(defn- clock-view []
  (pill [:text {:color text-color :size 17} (sub :clock/time)]))

# -- Root bar view --

(defn- launcher-trigger []
  [:row {:id "launcher" :pad [4 8] :bg surface :radius 6 :align-y :center}
    [:text {:color subtle :size 14} "⌕"]])

(defn- bar-view []
  [:row {:w :grow :h :grow :pad [0 8] :bg bg :radius 8 :align-y :center}
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

      (= id "audio")
      {:dispatch [:osd/volume-mute]}

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

      # Scroll on audio: adjust volume
      (= id "audio")
      {:dispatch [(if (= dir "up") :osd/volume-up :osd/volume-down)]}

      # Scroll on title: cycle focus
      (= id "title")
      {:dispatch [:wm/focus (if (= dir "up") "prev" "next")]})))

(reg-view bar-view)
