# widgets — High-level drawing primitives for shoal surfaces
#
# Powerline-style sections, sparkline charts, fill bars, and icons.
# All shapes use :skew for consistent /-slant aesthetic.
#
# Requires: core/framework (theme), stdlib/util (tint, blend-bg, lerp-color)

# --- Constants ---

(def SLANT 0.30)        # Horizontal shift per unit height
(def MIN-BAR-H 2)       # Minimum bar height in pixels
(def N-SPARKLINE 15)    # Number of sparkline bars
(def SPARKLINE-W 4)     # Sparkline bar width
(def SPARKLINE-GAP 2)   # Gap between sparkline bars
(def N-NET-SPARK 15)    # 15s network window sampled at visible bar midpoints
(def NET-SPARK-W 3)     # Network spark bar width
(def NET-SPARK-GAP 3)   # Gap between network spark bars
(def NET-SPARK-HEADROOM 0.78) # Bars fade from this line to the edge

# --- Section ---

(defn section
  "Powerline section: parallelogram bg with /-slanted edges.
   Minimal left padding so fill-bars can sit at the left edge.
   Optional :height, :pad, and :gap keys in opts override defaults."
  [color opts & children]
  (def h (get opts :height 38))
  (def pad (get opts :pad [0 12 0 2]))
  (def gap (get opts :gap 8))
  [:row {:h h :pad pad :align-y :center :gap gap
         :bg color :skew SLANT}
    ;children])

# --- Fill bar ---

(defn fill-bar
  "Left-edge fill indicator. Wraps with bright color above 100%."
  [color pct &opt h]
  (default h (or (dyn :section-height) 38))
  (def clamped (max 0 pct))
  (def wrapped (> clamped 100))
  (def bar-pct (if wrapped (% clamped 100) clamped))
  (def bar-pct (if (and wrapped (= bar-pct 0)) 100 bar-pct))
  (def bar-color (if wrapped (theme :bright) color))
  (def fill-h (max MIN-BAR-H (math/round (* h (/ (min 100 bar-pct) 100)))))
  [:row {:w 8 :h h :align-y :bottom}
    [:row {:w 8 :h fill-h :bg bar-color :skew SLANT}]])

# --- Sparkline helpers ---
#
# Bars slide physically left as scroll goes 0 → 1; the leftmost bar
# fades out as it leaves and the rightmost fades in. Pass the raw N+1
# sample buffer plus the current scroll fraction.

(defn sparkline
  "Single-series sparkline. Bars grow from the bottom of the row.
   Bars slide left as scroll goes 0 → 1.

   :colors  optional per-bar color array (parallel to values)
   :color   fallback color when :colors not given
   :scroll  fractional scroll offset 0 → 1 (default 0)
   :bar-width, :bar-gap, :height, :skew"
  [values &opt opts]
  (default opts {})
  (def h (get opts :height 38))
  (def bar-w (get opts :bar-width SPARKLINE-W))
  (def gap (get opts :bar-gap SPARKLINE-GAP))
  (def skew (get opts :skew SLANT))
  (def n (length values))
  (def skew-pad (math/ceil (* (math/abs skew) h)))
  (def w (+ (* n bar-w) (* (max 0 (- n 1)) gap) (* 2 skew-pad)))
  [:sparkline (merge {:w w :h h
                      :values values
                      :scroll (get opts :scroll 0)
                      :bar-width bar-w :bar-gap gap
                      :skew skew}
                     (if-let [colors (get opts :colors)]
                       {:colors colors}
                       {:color (get opts :color (theme :text))}))])

(defn network-spark
  "Mirrored network spark with centered slanted bars.
   rx grows up from center, tx grows down. Bars slide left as scroll
   goes 0 → 1. Values are linear normalized rates; values above
   fade-start fade out vertically to suggest headroom."
  [rx-vals tx-vals rx-color tx-color &opt opts]
  (default opts {})
  (def h (get opts :height 38))
  (def bar-w (get opts :bar-width NET-SPARK-W))
  (def gap (get opts :bar-gap (get opts :gap NET-SPARK-GAP)))
  (def fade-start (get opts :fade-start NET-SPARK-HEADROOM))
  (def n (max (length rx-vals) (length tx-vals)))
  (def skew-pad (math/ceil (* SLANT (/ h 2))))
  (def w (+ (* n bar-w) (* (max 0 (- n 1)) gap) (* 2 skew-pad)))
  [:sparkline {:w w :h h
               :values rx-vals :values2 tx-vals
               :color rx-color :color2 tx-color
               :mirror true
               :scroll (get opts :scroll 0)
               :skew SLANT
               :bar-width bar-w :bar-gap gap
               :fade-start fade-start}])

# --- Icons ---
# All shapes lean with the / via skew to match the section aesthetic.

(defn icon-cpu
  "Chip: angled outline with die."
  [color]
  (def offset (math/floor (* SLANT 16 0.5)))
  [:row {:w 16 :h 16 :bg (tint color 60) :skew SLANT
         :align-x :center :align-y :center :pad [0 0 0 offset]}
    [:row {:w 6 :h 6 :bg color}]])

(defn icon-mem
  "RAM DIMMs: two skewed bars, staggered height."
  [color]
  [:row {:gap 2 :align-y :bottom}
    [:row {:w 6 :h 16 :bg color :skew SLANT}]
    [:row {:w 6 :h 12 :bg (tint color 160) :skew SLANT}]])

(defn icon-disk
  "Drive: angled body with indicator."
  [color]
  [:row {:w 16 :h 12 :bg (tint color 60) :skew SLANT
         :pad [0 0 0 3] :align-y :bottom}
    [:row {:w 3 :h 3 :bg color :radius 2}]])

(defn icon-battery
  "Battery: angled body with terminal nub."
  [color]
  [:row {:gap 0 :align-y :center}
    [:row {:w 16 :h 10 :bg (tint color 60) :skew SLANT}]
    [:row {:w 3 :h 5 :bg color}]])

(defn icon-net-rx
  "Download: arrow with angled shaft."
  [color]
  [:col {:gap 1 :align-x :center}
    [:tri {:w 10 :h 6 :dir :up :color color}]
    [:row {:w 3 :h 6 :bg color :skew SLANT}]])

(defn icon-net-tx
  "Upload: angled shaft with arrow."
  [color]
  [:col {:gap 1 :align-x :center}
    [:row {:w 3 :h 6 :bg color :skew SLANT}]
    [:tri {:w 10 :h 6 :dir :down :color color}]])

(defn icon-audio
  "Speaker: skewed driver + skewed cone flaring right."
  [color]
  [:row {:gap 0 :align-y :center :skew SLANT}
    [:row {:w 4 :h 8 :bg color}]
    [:tri {:w 7 :h 13 :dir :left :color color}]])

# --- Minimap ---

(defn minimap-tree
  "Render a tree node as skewed rectangles."
  [node w h &opt focused-color unfocused-color]
  (default focused-color (theme :accent))
  (default unfocused-color (theme :overlay))
  (def focused (get node "focused" false))
  (def color (if focused focused-color unfocused-color))
  (if (= (get node "type" "leaf") "leaf")
    [:row {:w w :h h :bg color :skew SLANT}]
    (let [children (get node "children" [])
          n (length children)
          vertical (= (get node "orientation" "vertical") "vertical")
          gap 2
          avail (- (if vertical h w) (* gap (max 0 (- n 1))))
          csz (max 2 (math/floor (/ avail (max 1 n))))]
      (if vertical
        (do
          (def total-below @[])
          (var acc 0)
          (for i 0 n
            (array/push total-below acc)
            (set acc (+ acc csz gap)))
          (def offsets (reverse (array/slice total-below)))
          [:col {:gap gap :w (+ w (math/floor (* SLANT (- h csz)))) :h h}
            ;(seq [i :range [0 n]
                   :let [c (children i)
                         pad-l (math/floor (* SLANT (offsets i)))]]
              [:row {:pad [0 0 0 pad-l]}
                (minimap-tree c w csz focused-color unfocused-color)])])
        [:row {:gap gap :w w :h h}
          ;(seq [c :in children]
             (minimap-tree c csz h focused-color unfocused-color))]))))
