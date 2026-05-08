#!/usr/bin/env shoal
# minimal.janet — Minimal example
#
# The simplest possible shoal config. Just a clock.
# Run with: shoal minimal.janet

(use /module/clock)

(defn minimal-view []
  [:row {:w :grow :h 40 :bg [40 42 54 255] :align-x :center :align-y :center}
    [:text {:color [248 248 242 255] :size 20}
      (sub :clock/time)]])

(reg-surface :default {} minimal-view)
