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
  [:row {:pad [4 8] :bg surface :radius 6}
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
    (match name
      "master-stack"
      [:row {:gap 1 :h 16 :align-y :center}
        [:row {:w 9 :h 16 :bg hi :radius 1}]
        [:col {:gap 1}
          [:row {:w 6 :h 7 :bg c :radius 1}]
          [:row {:w 6 :h 7 :bg c :radius 1}]]]
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
      [:row {:gap 1 :h 16}
        [:row {:w 8 :h 16 :bg hi :radius 1}]
        [:col {:gap 1}
          [:row {:w 7 :h 8 :bg c :radius 1}]
          [:row {:gap 1 :h 7}
            [:row {:w 3 :h 7 :bg c :radius 1}]
            [:row {:w 3 :h 7 :bg c :radius 1}]]]]
      "centered-master"
      [:row {:gap 1 :h 16 :align-y :center}
        [:row {:w 4 :h 12 :bg c :radius 1}]
        [:row {:w 8 :h 16 :bg hi :radius 1}]
        [:row {:w 4 :h 12 :bg c :radius 1}]]
      # fallback: text
      [:text {:color subtle :size 11} name])))

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
      # Scale to fit — clamp minimap width to a reasonable range
      (def minimap-w (min 180 (max 60 (* minimap-h (/ total-w (max 1 (get vp :h 1)))))))
      (def scale (/ minimap-w (max 1 total-w)))

      (def windows (sub :tp/windows))
      (def focused-win (find |($ :focused) windows))
      (def focused-col (when focused-win (get focused-win :column)))

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
                     color (cond
                             is-focused accent
                             in-vp overlay
                             [(muted 0) (muted 1) (muted 2) 100])]]
           [:row {:w scaled-w :h minimap-h :bg color :radius 2}])])))

# -- Title --

(defn- title-view []
  (def title (sub :tp/title))
  (def app-id (sub :tp/app-id))
  (if (and title (> (length title) 0))
    [:row {:gap 6 :align-y :center}
      (when (and app-id (> (length app-id) 0) (not= app-id title))
        [:text {:color muted :size 13} app-id])
      [:text {:color text-color :size 15} title]]
    [:text {:color subtle :size 15} ""]))

# -- Right-side modules --

(defn- pct-color [pct]
  (cond (>= pct 80) red (>= pct 50) yellow green))

(defn- fill-bar [pct color &opt w]
  (default w 32)
  [:row {:w w :h 4 :bg [(muted 0) (muted 1) (muted 2) 80] :radius 2}
    [:row {:w (max 1 (math/floor (* w (/ (min pct 100) 100)))) :h 4 :bg color :radius 2}]])

(defn- cpu-view []
  (def pct (sub :cpu/percent))
  [:row {:pad [4 8] :bg surface :radius 6 :gap 6 :align-y :center}
    [:col {:gap 3 :align-y :center}
      [:text {:color text-color :size 13} (string (math/floor pct) "%")]
      (fill-bar pct (pct-color pct) 28)]
    [:text {:color subtle :size 11} "cpu"]])

(defn- mem-view []
  (def mem (sub :mem))
  (def pct (get mem :percent 0))
  (def used (get mem :used-mb 0))
  (def total (get mem :total-mb 0))
  [:row {:pad [4 8] :bg surface :radius 6 :gap 6 :align-y :center}
    [:col {:gap 3 :align-y :center}
      [:text {:color text-color :size 13}
        (string (if (>= used 1024)
                  (let [g (/ used 1024)
                        w (math/floor g)
                        f (math/floor (* 10 (- g w)))]
                    (string w "." f))
                  (string (math/floor used)))
                "/"
                (if (>= total 1024)
                  (let [g (/ total 1024)
                        w (math/floor g)
                        f (math/floor (* 10 (- g w)))]
                    (string w "." f "G"))
                  (string (math/floor total) "M")))]
      (fill-bar pct (pct-color pct) 36)]
    [:text {:color subtle :size 11} "mem"]])

(defn- bat-view []
  (def bat (sub :bat))
  (when (bat :present)
    (def pct (get bat :percent 0))
    (def charging (bat :charging))
    (def color (cond charging accent (< pct 20) red (< pct 50) yellow green))
    [:row {:pad [4 8] :bg surface :radius 6 :gap 6 :align-y :center}
      [:col {:gap 3 :align-y :center}
        [:text {:color text-color :size 13}
          (string (if charging "+" "") (math/floor pct) "%")]
        (fill-bar pct color 24)]
      [:text {:color subtle :size 11} "bat"]]))

(defn- clock-view []
  (pill [:text {:color text-color :size 15} (sub :clock/time)]))

# -- Root bar view --

(defn- bar-view []
  [:row {:w :grow :h :grow :pad [0 8] :bg bg :radius 8 :align-y :center}
    # Left: workspaces + layout + minimap
    [:row {:w :grow :gap 6 :align-y :center}
      (workspaces-view)
      (layout-glyph)
      (scroll-minimap)]
    # Center: title
    [:row {:w :grow :align-x :center :align-y :center}
      (title-view)]
    # Right: system info
    [:row {:w :grow :gap 6 :align-x :right :align-y :center}
      (cpu-view)
      (mem-view)
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
    (when (string/has-prefix? "tag-" id)
      (def tag (scan-number (string/slice id 4)))
      (when tag
        {:dispatch [:tp/focus-tag tag]}))))

(reg-view bar-view)
