#!/usr/bin/env shoal
# bar.janet — Example status bar
#
# A simple status bar with workspace indicators, system stats, and clock.
# Run with: shoal bar.janet [compositor]
#   compositor: "sway" or "tidepool" (default: "tidepool")

# Get compositor from args (default: tidepool)
(def compositor (or (script-args 0) "tidepool"))

# Load compositor integration
(case compositor
  "sway" (use "compositor/sway")
  "tidepool" (use "compositor/tidepool")
  (error (string "unknown compositor: " compositor)))

# Load data sources
(use "module/clock")
(use "module/sysinfo")

# Load drawing helpers
(use "stdlib/util")
(use "drawing/widgets")

# Theme shortcuts
(def bg (theme :bg))
(def text-color (theme :text))
(def accent (theme :accent))
(def green (theme :green))
(def muted (theme :muted))

# --- Workspace tags ---

(defn tag-view [idx tag]
  (def id (string "tag-" idx))
  (def focused (tag :focused))
  [:row {:id id :h 38 :pad [0 10] :align-x :center :align-y :center
         :bg (if focused accent muted)}
    [:text {:color (if focused bg text-color) :size 16}
      (string idx)]])

(defn workspaces-view []
  (def tags (sub :wm/tags))
  [:row {:gap 0 :align-y :center}
    ;(seq [i :range [1 10]
           :let [tag (get tags i)]
           :when (and tag (tag :occupied))]
      (tag-view i tag))])

# --- Sections ---

(defn cpu-view []
  (let [pct (sub :cpu/percent)]
    (section (blend-bg (theme :yellow) 200) {}
      (fill-bar green pct)
      [:text {:color text-color :size 14} (string "CPU " pct "%")])))

(defn mem-view []
  (let [mem (sub :mem)
        used (get mem :used-mb 0)
        total (get mem :total-mb 0)
        pct (get mem :percent 0)]
    (section (blend-bg green 200) {}
      (fill-bar green pct)
      [:text {:color text-color :size 14}
        (string (fmt-mem used) "/" (fmt-mem total))])))

(defn clock-view []
  (section (blend-bg (theme :blue) 200) {}
    [:col {:align-x :right :gap 1 :pad [0 14 0 0]}
      [:text {:color (theme :bright) :size 17} (sub :clock/time)]
      [:text {:color muted :size 12} (sub :clock/date)]]))

# --- Main view ---

(defn bar-view []
  [:row {:w :grow :h 38 :bg bg :align-y :center}
    # Left: workspaces
    [:row {:w :grow :pad [0 10] :align-y :center}
      (workspaces-view)]
    # Right: stats
    [:row {:w :grow :align-x :right :align-y :center :gap 0}
      (cpu-view)
      (mem-view)
      (clock-view)]])

(reg-view bar-view)
