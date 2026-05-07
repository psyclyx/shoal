# util — Shared utilities for shoal configs
#
# Color manipulation, formatting, and other helpers.

(defn tint
  "Override alpha channel of a color (0-255 range)."
  [color a]
  [(color 0) (color 1) (color 2) (or a 100)])

(defn blend-bg
  "Pre-blend color with background at given alpha. Returns opaque color.
   Adjacent opaque sections eliminate z-fighting at skew overlaps."
  [color a &opt bg-color]
  (def bg (or bg-color (theme :bg)))
  (def alpha (/ (or a 100) 255))
  (def inv (- 1 alpha))
  [(math/floor (+ (* (color 0) alpha) (* (bg 0) inv)))
   (math/floor (+ (* (color 1) alpha) (* (bg 1) inv)))
   (math/floor (+ (* (color 2) alpha) (* (bg 2) inv)))
   255])

(defn lerp-color
  "Linear interpolation between two colors. Returns color with alpha."
  [c1 c2 t]
  [(math/floor (+ (* (c1 0) (- 1 t)) (* (c2 0) t)))
   (math/floor (+ (* (c1 1) (- 1 t)) (* (c2 1) t)))
   (math/floor (+ (* (c1 2) (- 1 t)) (* (c2 2) t)))
   (math/floor (+ (* (get c1 3 255) (- 1 t)) (* (get c2 3 255) t)))])

(defn pct-color
  "Color based on percentage threshold: green → yellow → red."
  [pct]
  (cond (>= pct 80) (theme :red)
        (>= pct 50) (theme :yellow)
        (theme :green)))

(defn fmt-gb
  "Format GB value with one decimal place."
  [g]
  (let [w (math/floor g)
        f (math/floor (* 10 (- g w)))]
    (string/format "%d.%d" w f)))

(defn fmt-mem
  "Format memory in MB or GB."
  [mb]
  (if (>= mb 1024)
    (let [gib (/ mb 1024)
          whole (math/floor gib)
          frac (math/floor (* 10 (- gib whole)))]
      (string/format "%d.%dG" whole frac))
    (string/format "%dM" (math/floor mb))))

(defn fmt3
  "Format value + suffix as exactly 3 characters: X.X or XX or XXX."
  [val suffix]
  (if (>= val 10)
    (string/format "%3.0f%s" val suffix)
    (string/format "%3.1f%s" val suffix)))

(defn fmt-rate
  "Format bandwidth rate in K/M/G suffix."
  [bps]
  (cond
    (>= bps 1073741824) (fmt3 (/ bps 1073741824) "G")
    (>= bps 1048576)    (fmt3 (/ bps 1048576) "M")
    (> bps 0)           (fmt3 (/ bps 1024) "K")
    "0.0K"))

(defn clamp
  "Clamp value to range [lo, hi]."
  [v lo hi]
  (min hi (max lo v)))
